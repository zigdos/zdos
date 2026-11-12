/* A few GNU and BSD additions to NetBSD's libm (src/libm); the long double
 * functions are musl's and FreeBSD's (src/libml). */
#include <math.h>

/* GNU */
double exp10(double x) { return pow(10.0, x); }
float exp10f(float x) { return powf(10.0f, x); }
double pow10(double x) { return pow(10.0, x); }

/* BSD */
int isnanf(float x) { return __builtin_isnan(x); }
int isinff(float x) { return __builtin_isinf(x); }
