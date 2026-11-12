#pragma once
#ifndef _ZDOS_SYS_RANDOM_H_
#define _ZDOS_SYS_RANDOM_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* From the CPU's generator (x86 RDRAND, ARM64 RNDR), else from the clocks
   mixed (not for keys). getentropy: at most 256 bytes. (zdos_unix.c) */
#define GRND_NONBLOCK 1
#define GRND_RANDOM 2
int getentropy(void *buf, size_t len);
ssize_t getrandom(void *buf, size_t len, unsigned flags);

#ifdef __cplusplus
}
#endif

#endif
