@import Foundation;
@import IOKit;
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "ioregistry.h"
#include "DDCProtocol.h"

extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t, uint32_t, void *, uint32_t);
static BOOL benqReadGuard = NO;

static void output(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    puts("");
}
static int fail(NSString *message) { output(@{@"error":message}); return 1; }

static BOOL readValue(DDCTransport transport, uint8_t code, MLValue *value, NSString **error) {
    // Some BenQ firmware echoes the requested VCP code with the PREVIOUS
    // feature's payload when a picture control is locked. A valid checksum and
    // echoed code alone are insufficient. Prime with the read-only controller
    // identity (0xc8), whose payload is invalid as a continuous value on EW3270U.
    BOOL guardPayload = benqReadGuard;
    uint8_t sentinelReply[12] = {0};
    if (guardPayload) {
        uint8_t sentinel[4];
        MLReadPacket(0xc8, sentinel);
        usleep(20000);
        IOReturn sent = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, sentinel, sizeof(sentinel));
        usleep(60000);
        IOReturn received = IOAVServiceReadI2C(transport.service, transport.chipAddress, 0x51, sentinelReply, sizeof(sentinelReply));
        MLValue ignored = {};
        MLReplyStatus status = MLParseReply(sentinelReply, sizeof(sentinelReply), 0xc8, &ignored);
        if (sent || received || (status != MLValid && status != MLInvalidRange)) {
            *error = @"无法验证显示器返回的数据，请在显示器唤醒后重新检测。";
            return NO;
        }
    }
    for (int attempt = 0; attempt < 4; ++attempt) {
        uint8_t request[4], reply[12] = {0};
        MLReadPacket(code, request);
        usleep(20000);
        IOReturn sent = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, request, sizeof(request));
        // EW3270U returns empty replies with the common 10ms delay.
        usleep(60000 + attempt * 20000);
        IOReturn received = IOAVServiceReadI2C(transport.service, transport.chipAddress, 0x51, reply, sizeof(reply));
        MLReplyStatus status = MLParseReply(reply, sizeof(reply), code, value);
        if (guardPayload && (status == MLValid || status == MLInvalidRange) &&
            (status == MLInvalidRange || memcmp(reply + 6, sentinelReply + 6, 4) == 0)) {
            *error = @"显示器未返回此项的有效数值。请先确认能否在显示器菜单中调节此项；B.I.+、HDR 或图像模式可能会锁定它。";
            return NO;
        }
        if (!sent && !received && status == MLValid) return YES;
        if (!sent && !received && status == MLUnsupported) {
            *error = @"显示器不支持此项控制。";
            return NO;
        }
        *error = @"显示器没有返回有效数据。请检查显示器菜单中的 DDC/CI、HDR 或自动亮度设置，以及连接线。";
        usleep(40000);
    }
    return NO;
}
static NSDictionary *valueJSON(MLValue value) {
    return @{@"current":@(value.current), @"maximum":@(value.maximum)};
}
static uint8_t featureCode(NSString *feature) {
    if ([feature isEqual:@"brightness"]) return 0x10;
    if ([feature isEqual:@"contrast"]) return 0x12;
    if ([feature isEqual:@"volume"]) return 0x62;
    if ([feature isEqual:@"picture-mode"]) return 0xdc;
    if ([feature isEqual:@"sharpness"]) return 0x87;
    if ([feature isEqual:@"gamma"]) return 0x72;
    if ([feature isEqual:@"response-time"]) return 0xf0;
    if ([feature isEqual:@"aspect-ratio"]) return 0x86;
    return 0;
}
static BOOL allowedValue(uint8_t code, long value) {
    switch (code) {
        case 0xdc: return value == 0 || value == 5 || value == 11 || value == 12 || value == 14 ||
            value == 15 || value == 18 ||
            value == 0x113 || value == 0x213 || value == 0x313 || value == 0x413;
        case 0x87: return value >= 1 && value <= 10;
        case 0x72: return value == 80 || value == 100 || value == 120 || value == 140 || value == 160;
        case 0xf0: return value >= 0 && value <= 2;
        case 0x86: return value == 1 || value == 2 || value == 5;
        default: return YES;
    }
}
static int run(int argc, char **argv) {
    if (argc < 2) return fail(@"Usage: monitor-ddc list | probe UUID | get UUID brightness|contrast|volume | set UUID feature integer");
    // Serialize app and diagnostic CLI requests across processes. Opening with
    // O_NOFOLLOW and mode 0600 prevents accepting another user's lock file.
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/MonitorLight"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *lockPath = [cache stringByAppendingPathComponent:@"ddc.lock"];
    int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (lock < 0) return fail(@"无法创建显示器通信锁。请检查用户缓存目录权限。");
    BOOL locked = NO;
    for (int i = 0; i < 100; ++i) {
        if (flock(lock, LOCK_EX | LOCK_NB) == 0) { locked = YES; break; }
        usleep(20000);
    }
    if (!locked) { close(lock); return fail(@"显示器正忙，请稍后重试。"); }

    NSString *command = @(argv[1]);
    DisplayInfos displays[MAX_DISPLAYS] = {};
    int count = getOnlineDisplayInfos(displays);
    if ([command isEqual:@"list"] && argc == 2) {
        NSMutableArray *result = [NSMutableArray array];
        for (int i = 0; i < count; ++i) {
            if (CGDisplayIsBuiltin(displays[i].id)) continue;
            DDCTransport t = getDisplayDDCTransport(displays + i);
            [result addObject:@{@"id":@(displays[i].id), @"uuid":displays[i].uuid ?: @"",
                                @"name":displays[i].productName ?: @"外接显示器", @"ddc":@((BOOL)(t.service != NULL))}];
            if (t.service) CFRelease(t.service);
        }
        output(result);
        close(lock);
        return 0;
    }
    BOOL probe = [command isEqual:@"probe"] && argc == 3;
    BOOL settings = [command isEqual:@"settings"] && argc == 3;
    BOOL get = [command isEqual:@"get"] && argc == 4;
    BOOL set = [command isEqual:@"set"] && argc == 5;
    if (!probe && !settings && !get && !set) return fail(@"参数不正确。");
    DisplayInfos *selected = NULL;
    for (int i = 0; i < count; ++i) {
        if (!CGDisplayIsBuiltin(displays[i].id) && [displays[i].uuid isEqual:@(argv[2])]) selected = displays + i;
    }
    if (!selected) return fail(@"显示器已断开，请重新检测。");
    benqReadGuard = selected->vendor == 0x09d1 && selected->model == 0x7950;
    DDCTransport transport = getDisplayDDCTransport(selected);
    if (!transport.service) return fail(@"此连接不支持 DDC/CI。请改用 USB-C 或 DisplayPort 直连显示器。");
    NSString *error = nil;
    if (probe || settings) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        if (settings && !benqReadGuard) return fail(@"此显示器暂不支持画面设置。");
        NSArray *features = settings ? @[@"picture-mode", @"sharpness", @"response-time", @"aspect-ratio"]
                                    : @[@"brightness", @"volume"];
        for (NSString *feature in features) {
            MLValue value = {};
            result[feature] = readValue(transport, featureCode(feature), &value, &error)
                ? valueJSON(value) : @{@"error":error};
        }
        output(result);
        CFRelease(transport.service);
        close(lock);
        return 0;
    }
    uint8_t code = featureCode(@(argv[3]));
    if (!code) return fail(@"未知设置项。");
    if (code != 0x10 && code != 0x12 && code != 0x62 && !benqReadGuard) return fail(@"此显示器暂不支持画面设置。");
    MLValue value = {};
    if (!readValue(transport, code, &value, &error)) return fail(error);
    if (get) { output(valueJSON(value)); CFRelease(transport.service); close(lock); return 0; }
    char *end = NULL;
    errno = 0;
    long requested = strtol(argv[4], &end, 10);
    if (errno || end == argv[4] || *end || requested < 0 || requested > value.maximum || !allowedValue(code, requested))
        return fail(@"该数值超出了显示器支持的范围。");
    uint8_t packet[6];
    MLWritePacket(code, (uint16_t)requested, packet);
    // Image controls can settle more slowly than volume. Send once and poll;
    // repeating the write can restart the monitor's transition indefinitely.
    usleep(20000);
    IOReturn status = IOAVServiceWriteI2C(transport.service, transport.chipAddress, 0x51, packet, sizeof(packet));
    if (status) return fail(@"无法与显示器通信，请稍后重试。");
    for (int attempt = 0; attempt < 6; ++attempt) {
        usleep(attempt < 2 ? 120000 : 200000);
        // Aspect/picture changes can replace the DCP service. Re-discover the
        // same UUID instead of reading through a stale IOAVService reference.
        DisplayInfos refreshed[MAX_DISPLAYS] = {};
        int refreshedCount = getOnlineDisplayInfos(refreshed);
        for (int i = 0; i < refreshedCount; ++i) {
            if (![refreshed[i].uuid isEqual:@(argv[2])]) continue;
            DDCTransport next = getDisplayDDCTransport(refreshed + i);
            if (next.service) { CFRelease(transport.service); transport = next; }
            break;
        }
        MLValue confirmed = {};
        if (readValue(transport, code, &confirmed, &error) && confirmed.current == requested) {
            NSMutableDictionary *result = [valueJSON(confirmed) mutableCopy];
            result[@"verified"] = @YES;
            output(result);
            CFRelease(transport.service);
            close(lock);
            return 0;
        }
    }
    output(@{@"error":@"设置已发送，但尚未确认生效，请稍后再查看。",
             @"writeSent":@YES, @"requested":@(requested)});
    return 1;
}
int main(int argc, char **argv) { @autoreleasepool { return run(argc, argv); } }
