/* complex.h: computed in double from math.h (float and long
 * double through it). The usual infinities, zeros and NaNs come
 * out as C's Annex G says; not every corner of it. */
#include <complex.h>
#include <math.h>

#define MAKE(x, y) __builtin_complex((double)(x), (double)(y))
#define RE(z) __real__(z)
#define IM(z) __imag__(z)
#define PI_2 1.57079632679489661923

double creal(double complex z) { return RE(z); }
double cimag(double complex z) { return IM(z); }
double cabs(double complex z) { return hypot(RE(z), IM(z)); }
double carg(double complex z) { return atan2(IM(z), RE(z)); }
double complex conj(double complex z) { return MAKE(RE(z), -IM(z)); }

double complex cproj(double complex z) {
    if (isinf(RE(z)) || isinf(IM(z))) {
        return MAKE(INFINITY, copysign(0.0, IM(z)));
    }
    return z;
}

double complex cexp(double complex z) {
    double x = RE(z), y = IM(z);
    if (y == 0) {
        return MAKE(exp(x), y);
    }
    if (isinf(x) && !isfinite(y)) {
        return x > 0 ? MAKE(x, y - y) : MAKE(0.0, 0.0);
    }
    if (x > 709.0) { /* exp(x) overflows before exp(x) * cos(y) may */
        double half = exp(x / 2);
        return MAKE(half * cos(y) * half, half * sin(y) * half);
    }
    double e = exp(x);
    return MAKE(e * cos(y), e * sin(y));
}

double complex clog(double complex z) {
    double x = RE(z), y = IM(z);
    double r = hypot(x, y);
    double re;
    if (r > 0.7 && r < 1.5) { /* log near 1: through log1p, without cancelling */
        double big = fmax(fabs(x), fabs(y)), small = fmin(fabs(x), fabs(y));
        re = 0.5 * log1p((big - 1) * (big + 1) + small * small);
    } else {
        re = log(r);
    }
    return MAKE(re, atan2(y, x));
}

double complex csqrt(double complex z) {
    double x = RE(z), y = IM(z);
    if (x == 0 && y == 0) {
        return MAKE(0.0, y);
    }
    if (isinf(y)) {
        return MAKE(INFINITY, y);
    }
    if (isnan(x)) {
        return MAKE(x, x);
    }
    if (isinf(x)) {
        if (x > 0) {
            return MAKE(x, isnan(y) ? y : copysign(0.0, y));
        }
        return MAKE(isnan(y) ? y : 0.0, copysign(INFINITY, y));
    }
    double scale = 1;
    if (fabs(x) > 0x1p1020 || fabs(y) > 0x1p1020) { /* |x| + |z| would overflow */
        x *= 0.25;
        y *= 0.25;
        scale = 2;
    }
    double t = sqrt((fabs(x) + hypot(x, y)) * 0.5);
    if (x >= 0) {
        return MAKE(t * scale, y / (2 * t) * scale);
    }
    return MAKE(fabs(y) / (2 * t) * scale, copysign(t, y) * scale);
}

/* x^y = exp(y log x); 0^y is 0 for real y > 0 */
double complex cpow(double complex z, double complex w) {
    if (RE(w) == 0 && IM(w) == 0) {
        return MAKE(1.0, 0.0);
    }
    if (RE(z) == 0 && IM(z) == 0 && IM(w) == 0 && RE(w) > 0) {
        return MAKE(0.0, 0.0);
    }
    double complex l = clog(z);
    return cexp(MAKE(RE(w) * RE(l) - IM(w) * IM(l), RE(w) * IM(l) + IM(w) * RE(l)));
}

/* HYPERBOLIC; THE CIRCULAR ONES THROUGH THEM (SIN Z = -I sinh(iz) ...) */

/* cosh x and |sinh x| are e^|x| / 2 there; in halves, as cos y or sin y may
   bring the product back into range */
#define BIG_X(x) (fabs(x) > 709.0)
static double big_cosh_times(double x, double f) {
    double h = exp(fabs(x) / 2);
    return 0.5 * f * h * h;
}

double complex csinh(double complex z) {
    double x = RE(z), y = IM(z);
    if (y == 0) {
        return MAKE(sinh(x), y);
    }
    if ((x == 0 || isinf(x)) && !isfinite(y)) {
        return MAKE(x, y - y);
    }
    if (BIG_X(x)) {
        return MAKE(copysign(1.0, x) * big_cosh_times(x, cos(y)), big_cosh_times(x, sin(y)));
    }
    return MAKE(sinh(x) * cos(y), cosh(x) * sin(y));
}

double complex ccosh(double complex z) {
    double x = RE(z), y = IM(z);
    if (y == 0) {
        return MAKE(cosh(x), copysign(0.0, x) * y);
    }
    if (x == 0 && !isfinite(y)) {
        return MAKE(y - y, x);
    }
    if (isinf(x) && !isfinite(y)) {
        return MAKE(x * x, x * (y - y));
    }
    if (BIG_X(x)) {
        return MAKE(big_cosh_times(x, cos(y)), copysign(1.0, x) * big_cosh_times(x, sin(y)));
    }
    return MAKE(cosh(x) * cos(y), sinh(x) * sin(y));
}

/* Kahan's form: no overflow of sinh and cosh for large x */
double complex ctanh(double complex z) {
    double x = RE(z), y = IM(z);
    if (y == 0) {
        return MAKE(tanh(x), y);
    }
    if (isinf(x)) {
        return MAKE(copysign(1.0, x), copysign(0.0, isfinite(y) ? sin(2 * y) : y));
    }
    if (x == 0 && !isfinite(y)) {
        return MAKE(x, y - y);
    }
    if (fabs(x) > 22) { /* tanh(x) is +-1 in double */
        double e = exp(-2 * fabs(x));
        return MAKE(copysign(1.0, x), 4 * sin(y) * cos(y) * e);
    }
    double t = tan(y);
    double beta = 1 + t * t;
    double s = sinh(x);
    double rho = sqrt(1 + s * s);
    double d = 1 + beta * s * s;
    return MAKE(beta * rho * s / d, t / d);
}

double complex csin(double complex z) {
    double complex h = csinh(MAKE(-IM(z), RE(z)));
    return MAKE(IM(h), -RE(h));
}

double complex ccos(double complex z) {
    return ccosh(MAKE(-IM(z), RE(z)));
}

double complex ctan(double complex z) {
    double complex h = ctanh(MAKE(-IM(z), RE(z)));
    return MAKE(IM(h), -RE(h));
}

/* Kahan, "Branch cuts for complex elementary functions": from the square roots
   of 1 - z and 1 + z; the signs of zeros keep the cuts' sides. */

double complex casin(double complex z) {
    double x = RE(z), y = IM(z);
    if (isnan(x) || isnan(y)) {
        if (isinf(x)) {
            return MAKE(y, x);
        }
        return isinf(y) || x == 0 ? z : MAKE(NAN, NAN);
    }
    if (isinf(x) || isinf(y)) {
        return MAKE(atan2(x, fabs(y)), copysign(INFINITY, y));
    }
    double complex s1 = csqrt(MAKE(1 - x, -y));
    double complex s2 = csqrt(MAKE(1 + x, y));
    return MAKE(atan2(x, RE(s1) * RE(s2) - IM(s1) * IM(s2)),
                asinh(RE(s1) * IM(s2) - IM(s1) * RE(s2)));
}

double complex cacos(double complex z) {
    double x = RE(z), y = IM(z);
    if (isnan(x) || isnan(y)) {
        if (isinf(x) || isinf(y)) {
            return MAKE(NAN, isinf(x) ? -INFINITY : -y);
        }
        return MAKE(x == 0 ? PI_2 : NAN, NAN);
    }
    if (isinf(x) || isinf(y)) {
        return MAKE(PI_2 - atan2(x, fabs(y)), -copysign(INFINITY, y));
    }
    double complex s1 = csqrt(MAKE(1 - x, -y));
    double complex s2 = csqrt(MAKE(1 + x, y));
    return MAKE(2 * atan2(RE(s1), RE(s2)), asinh(RE(s2) * IM(s1) - IM(s2) * RE(s1)));
}

/* atanh z = (log(1 + z) - log(1 - z)) / 2, its real part through log1p */
double complex catanh(double complex z) {
    double x = RE(z), y = IM(z);
    if (isinf(x) || isinf(y)) {
        return MAKE(copysign(0.0, x), isnan(y) ? y : copysign(PI_2, y));
    }
    if (x == 0 && isnan(y)) {
        return z;
    }
    double ax = fabs(x);
    double d = (1 - ax) * (1 - ax) + y * y;
    double re = 0.25 * log1p(4 * ax / d);
    return MAKE(copysign(re, x), 0.5 * atan2(2 * y, (1 - x) * (1 + x) - y * y));
}

double complex casinh(double complex z) {
    double complex s = casin(MAKE(-IM(z), RE(z)));
    return MAKE(IM(s), -RE(s));
}

/* acosh z = +-i acos z, the sign giving a real part >= 0 */
double complex cacosh(double complex z) {
    double complex c = cacos(z);
    return signbit(IM(c)) ? MAKE(-IM(c), RE(c)) : MAKE(IM(c), -RE(c));
}

double complex catan(double complex z) {
    double complex h = catanh(MAKE(-IM(z), RE(z)));
    return MAKE(IM(h), -RE(h));
}

#define FLOAT_AND_LONG(name)                                                                       \
    float complex name##f(float complex z) { return (float complex)name((double complex)z); }      \
    long double complex name##l(long double complex z) {                                           \
        return (long double complex)name((double complex)z);                                       \
    }
#define REAL_FLOAT_AND_LONG(name)                                                                  \
    float name##f(float complex z) { return (float)name((double complex)z); }                      \
    long double name##l(long double complex z) { return name((double complex)z); }

REAL_FLOAT_AND_LONG(creal)
REAL_FLOAT_AND_LONG(cimag)
REAL_FLOAT_AND_LONG(cabs)
REAL_FLOAT_AND_LONG(carg)
FLOAT_AND_LONG(conj)
FLOAT_AND_LONG(cproj)
FLOAT_AND_LONG(cexp)
FLOAT_AND_LONG(clog)
FLOAT_AND_LONG(csqrt)
FLOAT_AND_LONG(csin)
FLOAT_AND_LONG(ccos)
FLOAT_AND_LONG(ctan)
FLOAT_AND_LONG(casin)
FLOAT_AND_LONG(cacos)
FLOAT_AND_LONG(catan)
FLOAT_AND_LONG(csinh)
FLOAT_AND_LONG(ccosh)
FLOAT_AND_LONG(ctanh)
FLOAT_AND_LONG(casinh)
FLOAT_AND_LONG(cacosh)
FLOAT_AND_LONG(catanh)

float complex cpowf(float complex z, float complex w) {
    return (float complex)cpow((double complex)z, (double complex)w);
}

long double complex cpowl(long double complex z, long double complex w) {
    return (long double complex)cpow((double complex)z, (double complex)w);
}
