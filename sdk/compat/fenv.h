#pragma once
#ifndef _ZDOS_FENV_H_
#define _ZDOS_FENV_H_

#ifdef __cplusplus
extern "C" {
#endif

/* The floating-point environment (zdos_fenv.c): x86-64 sets SSE (float and
   double) and the x87 (long double) together; x86 has the x87 only; ARM64
   FPCR and FPSR. The values are glibc's. */
#if defined(__aarch64__)
typedef unsigned int fexcept_t;
typedef struct {
    unsigned int fpcr;
    unsigned int fpsr;
} fenv_t;

#define FE_INVALID 1
#define FE_DIVBYZERO 2
#define FE_OVERFLOW 4
#define FE_UNDERFLOW 8
#define FE_INEXACT 16
#define FE_ALL_EXCEPT 31
#define FE_TONEAREST 0
#define FE_UPWARD 0x400000
#define FE_DOWNWARD 0x800000
#define FE_TOWARDZERO 0xc00000
#else
typedef unsigned short fexcept_t;
typedef struct {
    unsigned short control; /* x87 control word */
    unsigned short status;  /* x87 exception flags */
    unsigned int mxcsr;     /* x86-64 */
} fenv_t;

#define FE_INVALID 1
#define FE_DIVBYZERO 4
#define FE_OVERFLOW 8
#define FE_UNDERFLOW 16
#define FE_INEXACT 32
#define FE_ALL_EXCEPT 61
#define FE_TONEAREST 0
#define FE_DOWNWARD 0x400
#define FE_UPWARD 0x800
#define FE_TOWARDZERO 0xc00
#endif

/* Round to nearest, no flags, no exception traps */
#define FE_DFL_ENV ((const fenv_t *)-1)

int feclearexcept(int excepts);
int fetestexcept(int excepts);
int feraiseexcept(int excepts); /* sets the flags */
int fegetexceptflag(fexcept_t *flags, int excepts);
int fesetexceptflag(const fexcept_t *flags, int excepts);
int fegetround(void);
int fesetround(int mode);
int fegetenv(fenv_t *env);
int fesetenv(const fenv_t *env);
int feholdexcept(fenv_t *env);
int feupdateenv(const fenv_t *env);

#ifdef __cplusplus
}
#endif
#endif
