/* ZDOS: what FreeBSD's 128-bit long double files take from its
 * math_private.h, on top of musl's libm.h. */
#ifndef _MATH_PRIVATE_H_
#define _MATH_PRIVATE_H_

#include "libm.h"
#include "fpmath.h"
#include <sys/types.h>

#define __predict_false(x) __builtin_expect(!!(x), 0)
#define __always_inline inline __attribute__((__always_inline__))
#define __weak_reference(sym, alias)

/* No x87 precision switching; long double is computed as it is */
#define ENTERI()
#define RETURNI(x) RETURNF(x)
#define RETURNF(v) return (v)
#define STRICT_ASSIGN(type, lval, rval) ((lval) = (rval))

/* musl's kernels have FreeBSD's arguments */
#define __kernel_sinl __sinl
#define __kernel_cosl __cosl

#define EXTRACT_LDBL128_WORDS(ix0, ix1, ix2, d) do { \
	union IEEEl2bits ew_u; \
	ew_u.e = (d); \
	(ix0) = ew_u.xbits.expsign; \
	(ix1) = ew_u.xbits.manh; \
	(ix2) = ew_u.xbits.manl; \
} while (0)

#define INSERT_LDBL128_WORDS(d, ix0, ix1, ix2) do { \
	union IEEEl2bits iw_u; \
	iw_u.xbits.expsign = (ix0); \
	iw_u.xbits.manh = (ix1); \
	iw_u.xbits.manl = (ix2); \
	(d) = iw_u.e; \
} while (0)

#define GET_LDBL_EXPSIGN(i, d) do { \
	union IEEEl2bits ge_u; \
	ge_u.e = (d); \
	(i) = ge_u.xbits.expsign; \
} while (0)

#define SET_LDBL_EXPSIGN(d, v) do { \
	union IEEEl2bits se_u; \
	se_u.e = (d); \
	se_u.xbits.expsign = (v); \
	(d) = se_u.e; \
} while (0)

/* a + b exactly as a (rounded) + b (the error); |a| >= |b| or a == 0 */
#define _2sumF(a, b) do { \
	__typeof(a) __w; \
	__w = (a) + (b); \
	(b) = ((a) - __w) + (b); \
	(a) = __w; \
} while (0)

/* (a + b) += c, |a| >= |c| */
#define _3sumF(a, b, c) do { \
	__typeof(a) __tmp; \
	__tmp = (c); \
	_2sumF(__tmp, (a)); \
	(b) += (a); \
	(a) = __tmp; \
} while (0)

#define SUM2P(x, y) ({ \
	const __typeof (x) __x = (x); \
	const __typeof (y) __y = (y); \
	__x + __y; \
})

/* Nearest integer for |x| < 2^52, in round-to-nearest (only ARM64 uses
   these files: no extra precision) */
static inline double rnint(double x)
{
	return (double)(x + 0x1.8p52) - 0x1.8p52;
}
#define irint(x) ((int)(x))

typedef union {
	long double value;
	struct {
		uint32_t lswlo;
		uint32_t lswhi;
		uint32_t mswlo;
		uint32_t mswhi;
	} parts32;
	struct {
		uint64_t lsw;
		uint64_t msw;
	} parts64;
} ieee_quad_shape_type;

long double lgammal_r(long double, int *);

/* A NaN from NaN arguments, quieted */
#define nan_mix(x, y) (((x) + 0.0L) + ((y) + 0))

#ifdef STRUCT_RETURN
#define RETURNSPI(rp) do { \
	if (!(rp)->lo_set) \
		RETURNI((rp)->hi); \
	RETURNI((rp)->hi + (rp)->lo); \
} while (0)
#endif

#endif
