#pragma once
#ifndef _ZDOS_SEMAPHORE_H_
#define _ZDOS_SEMAPHORE_H_

#include <stdint.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Unnamed counting semaphores on a futex word (as many as memory holds;
   all zeros: one at 0); named ones (sem_open) don't exist. sem_wait ends
   with EINTR for a signal. */
typedef struct {
    uint32_t value; /* the count, + 0x80000000 while someone waits */
} sem_t;

#ifndef SEM_VALUE_MAX
#define SEM_VALUE_MAX 0x7fffffff
#endif

int sem_init(sem_t *sem, int shared, unsigned value);
int sem_destroy(sem_t *sem);
int sem_wait(sem_t *sem);
int sem_trywait(sem_t *sem);
int sem_timedwait(sem_t *sem, const struct timespec *abstime);
int sem_post(sem_t *sem);
int sem_getvalue(sem_t *sem, int *value);

#ifdef __cplusplus
}
#endif

#endif
