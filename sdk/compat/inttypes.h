#pragma once
#ifndef _ZDOS_INTTYPES_H_
#define _ZDOS_INTTYPES_H_

/* Format macros (Clang's own inttypes.h needs a hosted C library) */
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __SIZEOF_LONG__ == 8
#define __ZDOS_PRI64 "l"
#else
#define __ZDOS_PRI64 "ll"
#endif
#if __SIZEOF_POINTER__ == 8
#define __ZDOS_PRIPTR "l"
#else
#define __ZDOS_PRIPTR ""
#endif

#define PRId8 "d"
#define PRId16 "d"
#define PRId32 "d"
#define PRId64 __ZDOS_PRI64 "d"
#define PRIi8 "i"
#define PRIi16 "i"
#define PRIi32 "i"
#define PRIi64 __ZDOS_PRI64 "i"
#define PRIu8 "u"
#define PRIu16 "u"
#define PRIu32 "u"
#define PRIu64 __ZDOS_PRI64 "u"
#define PRIo8 "o"
#define PRIo16 "o"
#define PRIo32 "o"
#define PRIo64 __ZDOS_PRI64 "o"
#define PRIx8 "x"
#define PRIx16 "x"
#define PRIx32 "x"
#define PRIx64 __ZDOS_PRI64 "x"
#define PRIX8 "X"
#define PRIX16 "X"
#define PRIX32 "X"
#define PRIX64 __ZDOS_PRI64 "X"
#define PRIdPTR __ZDOS_PRIPTR "d"
#define PRIiPTR __ZDOS_PRIPTR "i"
#define PRIuPTR __ZDOS_PRIPTR "u"
#define PRIxPTR __ZDOS_PRIPTR "x"
#define PRIXPTR __ZDOS_PRIPTR "X"
#define PRIdMAX "jd"
#define PRIiMAX "ji"
#define PRIuMAX "ju"
#define PRIxMAX "jx"
#define PRIXMAX "jX"

#define SCNd8 "hhd"
#define SCNd16 "hd"
#define SCNd32 "d"
#define SCNd64 __ZDOS_PRI64 "d"
#define SCNi8 "hhi"
#define SCNi16 "hi"
#define SCNi32 "i"
#define SCNi64 __ZDOS_PRI64 "i"
#define SCNo8 "hho"
#define SCNo16 "ho"
#define SCNo32 "o"
#define SCNo64 __ZDOS_PRI64 "o"
#define SCNu8 "hhu"
#define SCNu16 "hu"
#define SCNu32 "u"
#define SCNu64 __ZDOS_PRI64 "u"
#define SCNx8 "hhx"
#define SCNx16 "hx"
#define SCNx32 "x"
#define SCNx64 __ZDOS_PRI64 "x"
#define SCNdPTR __ZDOS_PRIPTR "d"
#define SCNiPTR __ZDOS_PRIPTR "i"
#define SCNoPTR __ZDOS_PRIPTR "o"
#define SCNuPTR __ZDOS_PRIPTR "u"
#define SCNxPTR __ZDOS_PRIPTR "x"
#define SCNdMAX "jd"
#define SCNiMAX "ji"
#define SCNoMAX "jo"
#define SCNuMAX "ju"
#define SCNxMAX "jx"

intmax_t strtoimax(const char *nptr, char **endptr, int base);
uintmax_t strtoumax(const char *nptr, char **endptr, int base);

#ifdef __cplusplus
}
#endif

#endif
