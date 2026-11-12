/* What NetBSD's <sys/ieee754.h> gives the math sources: the sizes of the
   IEEE 754 formats (ZDOS's CPUs are little endian) */
#ifndef _ZDOS_LIBM_IEEE754_H_
#define _ZDOS_LIBM_IEEE754_H_
#define SNG_EXPBITS 8
#define SNG_FRACBITS 23
#define SNG_EXP_BIAS 127
#define SNG_EXP_INFNAN 255
#define DBL_EXPBITS 11
#define DBL_FRACHBITS 20
#define DBL_FRACLBITS 32
#define DBL_FRACBITS 52
#define DBL_EXP_BIAS 1023
#define DBL_EXP_INFNAN 2047
#endif
