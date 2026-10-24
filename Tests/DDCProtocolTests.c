#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "DDCProtocol.h"
static void checksum(uint8_t reply[11]) {
    reply[10] = 0x50;
    for (int i = 0; i < 10; ++i) reply[10] ^= reply[i];
}
int main(void) {
    // Captured from the physical BenQ EW3270U, brightness 100/100.
    uint8_t reply[11] = {0x6e,0x88,0x02,0x00,0x10,0x00,0x00,0x64,0x00,0x64,0xa4};
    MLValue value = {};
    assert(MLParseReply(reply,11,0x10,&value)==MLValid && value.current==100 && value.maximum==100);
    assert(MLParseReply(reply,10,0x10,&value)==MLMalformed);
    assert(MLParseReply(reply,11,0x12,&value)==MLMalformed);
    reply[10]^=1; assert(MLParseReply(reply,11,0x10,&value)==MLMalformed); checksum(reply);
    reply[3]=1; checksum(reply); assert(MLParseReply(reply,11,0x10,&value)==MLUnsupported);
    reply[3]=0; reply[8]=0; reply[9]=0; checksum(reply);
    assert(MLParseReply(reply,11,0x10,&value)==MLValid && value.current==0);
    reply[7]=0; checksum(reply); assert(MLParseReply(reply,11,0x10,&value)==MLInvalidRange);
    reply[7]=100; reply[9]=101; checksum(reply); assert(MLParseReply(reply,11,0x10,&value)==MLInvalidRange);
    reply[6]=1; reply[7]=0; reply[8]=1; reply[9]=0; checksum(reply);
    assert(MLParseReply(reply,11,0x10,&value)==MLValid && value.current==256 && value.maximum==256);
    uint8_t empty[12]={0}; assert(MLParseReply(empty,12,0x10,&value)==MLMalformed);
    // EW3270U can echo a locked brightness command with controller-ID bytes.
    // The checksum is valid, but this must never become a brightness value.
    uint8_t stale[11]={0x6e,0x88,0x02,0x00,0x10,0x00,0x00,0x27,0x96,0x09,0x1c};
    assert(MLParseReply(stale,11,0x10,&value)==MLInvalidRange);
    uint8_t mode[11]={0x6e,0x88,0x02,0x00,0xdc,0x00,0x04,0x13,0x02,0x13,0x6e};
    assert(MLParseReply(mode,11,0xdc,&value)==MLValid && value.current==531 && value.maximum==1043);
    uint8_t srgb[12]={0x6e,0x88,0x02,0x00,0x14,0x00,0x00,0x0b,0x00,0x0c,0xa7,0};
    assert(MLParseReply(srgb,12,0x14,&value)==MLInvalidRange);
    // This is not a discrete-value exception: subsequent reads proved 0x14
    // echoes the last discrete read (aspect ratio or mode), not a color preset.
    uint8_t read[4],write[6]; MLReadPacket(0x10,read); MLWritePacket(0x10,100,write);
    assert(read[3]==0xfd && write[5]==0xcc);
    // A checksum of zero remains part of the six-byte write packet.
    MLWritePacket(0x10,168,write); assert(write[5]==0);
    puts("DDC protocol tests passed");
}
