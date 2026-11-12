/* x86 (32-bit, x87): rint, lrint, floor, ceil, trunc and round with the
 * FPU's own rounding. NetBSD's C versions (left out on x86) and Zig's
 * compiler-rt (floor, ceil, round) round by adding 2^52, which the x87's
 * 80-bit registers don't round; NetBSD uses assembly on i386 too. */
#include <math.h>

#if defined(__i386__)

double rint(double x) {
    double r;
    __asm__("frndint" : "=t"(r) : "0"(x));
    return r;
}

float rintf(float x) {
    float r;
    __asm__("frndint" : "=t"(r) : "0"(x));
    return r;
}

long lrint(double x) {
    long r;
    __asm__("fistpl %0" : "=m"(r) : "t"(x) : "st");
    return r;
}

long lrintf(float x) {
    long r;
    __asm__("fistpl %0" : "=m"(r) : "t"(x) : "st");
    return r;
}

long long llrint(double x) {
    long long r;
    __asm__("fistpll %0" : "=m"(r) : "t"(x) : "st");
    return r;
}

long long llrintf(float x) {
    long long r;
    __asm__("fistpll %0" : "=m"(r) : "t"(x) : "st");
    return r;
}

/* frndint with the control word's rounding (bits 10-11) set to rc */
static long double rounded(long double x, unsigned short rc) {
    unsigned short cw, with;
    long double r;
    __asm__ volatile("fnstcw %0" : "=m"(cw));
    with = (unsigned short)((cw & ~0x0c00u) | rc);
    __asm__ volatile("fldcw %0" : : "m"(with));
    __asm__ volatile("frndint" : "=t"(r) : "0"(x));
    __asm__ volatile("fldcw %0" : : "m"(cw));
    return r;
}

#define DOWN 0x0400u
#define UP 0x0800u
#define TOWARD_ZERO 0x0c00u

double floor(double x) { return (double)rounded(x, DOWN); }
float floorf(float x) { return (float)rounded(x, DOWN); }
double ceil(double x) { return (double)rounded(x, UP); }
float ceilf(float x) { return (float)rounded(x, UP); }
double trunc(double x) { return (double)rounded(x, TOWARD_ZERO); }
float truncf(float x) { return (float)rounded(x, TOWARD_ZERO); }

/* Halfway away from zero (x - t is exact) */
double round(double x) {
    long double t = rounded(x, TOWARD_ZERO);
    long double d = (long double)x - t;
    if (d >= 0.5L) t += 1;
    else if (d <= -0.5L) t -= 1;
    return (double)t;
}

float roundf(float x) { return (float)round(x); }

#endif
