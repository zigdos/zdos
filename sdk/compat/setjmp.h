#pragma once
#ifndef _ZDOS_SETJMP_H_
#define _ZDOS_SETJMP_H_

#ifdef __cplusplus
extern "C" {
#endif

/* Implemented in zdos_setjmp.c (register layout there). 21 words: enough
   for the largest CPU (ARM64). Floating point control state (x87 control
   word, MXCSR, FPCR, FPSR) is not saved. */
typedef struct {
    unsigned long regs[21];
} jmp_buf[1];

/* returns_twice: the compiler must not keep values in registers across the
   call, as it does for the real setjmp */
int setjmp(jmp_buf env) __attribute__((returns_twice));
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

/* sigsetjmp(env, 1) also keeps the signal mask, and
   siglongjmp restores it: the way out of a signal handler
   (SIGSEGV ...), which runs with its signal blocked.
   In zdos_posix.c. */
typedef struct {
    jmp_buf buf;
    int saved;
    unsigned long long mask;
} sigjmp_buf[1];

void zdos_sigsetjmp_save(sigjmp_buf env, int save);
#define sigsetjmp(env, save) (zdos_sigsetjmp_save((env), (save)), setjmp((env)->buf))
void siglongjmp(sigjmp_buf env, int val) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif
