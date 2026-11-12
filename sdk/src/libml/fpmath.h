/* ZDOS: FreeBSD's fpmath.h for its 128-bit long double files (ARM64's
 * IEEE quad, little-endian; FreeBSD's arm64 _fpmath.h). */
#ifndef _FPMATH_H_
#define _FPMATH_H_

#include <stdint.h>

union IEEEl2bits {
	long double e;
	struct {
		uint64_t manl :64;
		uint64_t manh :48;
		unsigned int exp :15;
		unsigned int sign :1;
	} bits;
	struct {
		uint64_t manl :64;
		uint64_t manh :48;
		unsigned int expsign :16;
	} xbits;
};

#endif
