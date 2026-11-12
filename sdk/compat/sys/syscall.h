#pragma once
#ifndef _ZDOS_SYS_SYSCALL_H_
#define _ZDOS_SYS_SYSCALL_H_

/* Linux's numbers for the calls syscall() (unistd.h) carries out on ZDOS:
   futex, getrandom, gettid, getpid, sched_yield; others fail with ENOSYS */
#if defined(__x86_64__)
#define SYS_futex 202
#define SYS_getrandom 318
#define SYS_gettid 186
#define SYS_getpid 39
#define SYS_sched_yield 24
#elif defined(__i386__)
#define SYS_futex 240
#define SYS_getrandom 355
#define SYS_gettid 224
#define SYS_getpid 20
#define SYS_sched_yield 158
#define SYS_futex_time64 422
#elif defined(__aarch64__)
#define SYS_futex 98
#define SYS_getrandom 278
#define SYS_gettid 178
#define SYS_getpid 172
#define SYS_sched_yield 124
#endif

#define __NR_futex SYS_futex
#define __NR_getrandom SYS_getrandom
#define __NR_gettid SYS_gettid
#define __NR_getpid SYS_getpid
#define __NR_sched_yield SYS_sched_yield
#ifdef SYS_futex_time64
#define __NR_futex_time64 SYS_futex_time64
#endif

#ifdef __cplusplus
extern "C" {
#endif
long syscall(long number, ...); /* unistd.h's */
#ifdef __cplusplus
}
#endif

#endif
