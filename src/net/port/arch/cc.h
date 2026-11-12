/* lwIP's compiler and platform settings
   for the ZDOS kernel (freestanding) */
#ifndef ZDOS_LWIP_CC_H
#define ZDOS_LWIP_CC_H

#define BYTE_ORDER LITTLE_ENDIAN
#define LWIP_NO_INTTYPES_H 1
#define X8_F "02x"
#define U16_F "u"
#define S16_F "d"
#define X16_F "x"
#define U32_F "u"
#define S32_F "d"
#define X32_F "x"
#define SZT_F "zu"

/* From src/net/net.zig */
unsigned int zdos_net_random(void);
void zdos_net_assert(const char *what, int line, const char *file);

#define LWIP_RAND() ((u32_t)zdos_net_random())
#define LWIP_PLATFORM_DIAG(x) do { } while (0)
#define LWIP_PLATFORM_ASSERT(x) zdos_net_assert(x, __LINE__, __FILE__)

#endif
