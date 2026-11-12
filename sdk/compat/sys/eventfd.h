#pragma once
#ifndef _ZDOS_SYS_EVENTFD_H_
#define _ZDOS_SYS_EVENTFD_H_

#include <stdint.h>
#include <fcntl.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Linux's eventfd on ZDOS's counters (threads->counter_create, zdos_linux.c) */
typedef uint64_t eventfd_t;

#define EFD_SEMAPHORE 1
#define EFD_CLOEXEC O_CLOEXEC
#define EFD_NONBLOCK O_NONBLOCK

int eventfd(unsigned int initval, int flags);
int eventfd_read(int fd, eventfd_t *value);
int eventfd_write(int fd, eventfd_t value);

#ifdef __cplusplus
}
#endif

#endif
