#ifndef MONITORLIGHT_DDC_PROTOCOL_H
#define MONITORLIGHT_DDC_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>

typedef struct { uint16_t current; uint16_t maximum; } MLValue;
typedef enum { MLValid, MLMalformed, MLUnsupported, MLInvalidRange } MLReplyStatus;

// IOAVService supplies the source address separately. Its read request uses
// the 0x6e seed; write requests additionally include the 0x51 data address.
static inline void MLReadPacket(uint8_t code, uint8_t out[4]) {
    out[0] = 0x82; out[1] = 0x01; out[2] = code;
    out[3] = 0x6e ^ out[0] ^ out[1] ^ out[2];
}
static inline void MLWritePacket(uint8_t code, uint16_t value, uint8_t out[6]) {
    out[0] = 0x84; out[1] = 0x03; out[2] = code;
    out[3] = value >> 8; out[4] = value & 0xff;
    out[5] = 0x6e ^ 0x51 ^ out[0] ^ out[1] ^ out[2] ^ out[3] ^ out[4];
}
static inline MLReplyStatus MLParseReply(const uint8_t *reply, size_t length,
                                        uint8_t code, MLValue *value) {
    if (length < 11 || reply[0] != 0x6e || reply[1] != 0x88 ||
        reply[2] != 0x02 || reply[4] != code) return MLMalformed;
    uint8_t checksum = 0x50;
    for (size_t i = 0; i < 11; ++i) checksum ^= reply[i];
    if (checksum != 0) return MLMalformed;
    if (reply[3] != 0) return MLUnsupported;
    uint16_t maximum = ((uint16_t)reply[6] << 8) | reply[7];
    uint16_t current = ((uint16_t)reply[8] << 8) | reply[9];
    if (maximum == 0 || current > maximum) return MLInvalidRange;
    value->current = current;
    value->maximum = maximum;
    return MLValid;
}

#endif
