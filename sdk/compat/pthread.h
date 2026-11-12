#pragma once
#ifndef _ZDOS_PTHREAD_H_
#define _ZDOS_PTHREAD_H_

#include <stddef.h>
#include <stdint.h>
#include <sched.h>
#include <time.h>
#include <signal.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Threads are ZDOS tasks (metal editions; elsewhere pthread_create
   fails with ENOSYS). Mutexes, conditions, read-write locks, barriers
   and pthread_once are futex words (threads->futex_wait): as many as
   memory holds, all zeros a valid unlocked one. They don't inherit
   priority unless made with PTHREAD_PRIO_INHERIT (then a ZDOS mutex, 64
   in all of ZDOS). No cancellation (pthread_cancel: ENOSYS). */

typedef uint32_t pthread_t;
typedef unsigned pthread_key_t;
typedef int pthread_once_t;

#define PTHREAD_ONCE_INIT 0
#define PTHREAD_KEYS_MAX 32
#define PTHREAD_STACK_MIN 16384
#define PTHREAD_CREATE_JOINABLE 0
#define PTHREAD_CREATE_DETACHED 1
#define PTHREAD_INHERIT_SCHED 0
#define PTHREAD_EXPLICIT_SCHED 1
#define PTHREAD_MUTEX_NORMAL 0
#define PTHREAD_MUTEX_RECURSIVE 1
#define PTHREAD_MUTEX_ERRORCHECK 2
#define PTHREAD_MUTEX_DEFAULT PTHREAD_MUTEX_NORMAL
#define PTHREAD_PRIO_NONE 0
#define PTHREAD_PRIO_INHERIT 1
#define PTHREAD_PRIO_PROTECT 2
#define PTHREAD_PROCESS_PRIVATE 0
#define PTHREAD_PROCESS_SHARED 1
#define PTHREAD_BARRIER_SERIAL_THREAD (-1)

typedef struct {
    size_t stack_size; /* 0: 64 KiB */
    int priority;      /* -1: the creator's */
    int detached;
} pthread_attr_t;

typedef struct {
    int type; /* the type, + 0x100 for PTHREAD_PRIO_INHERIT */
} pthread_mutexattr_t;

/* A normal mutex deadlocks when its holder locks it again; error-checking
   and recursive ones keep their owner */
typedef struct {
    uint32_t lock;  /* 0 free, 1 locked, 2 locked with waiters (PRIO_INHERIT: ZDOS mutex + 1) */
    int type;
    int count;      /* recursive: how deep */
    uint32_t owner; /* error-checking, recursive: task number + 1, 0: none */
} pthread_mutex_t;
#define PTHREAD_MUTEX_INITIALIZER {0, PTHREAD_MUTEX_NORMAL, 0, 0}
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP {0, PTHREAD_MUTEX_RECURSIVE, 0, 0}
#define PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP {0, PTHREAD_MUTEX_ERRORCHECK, 0, 0}

typedef struct {
    clockid_t clock;
} pthread_condattr_t;

/* A broadcast wakes every waiter (no requeue onto the mutex) */
typedef struct {
    uint32_t seq;     /* a futex word: each signal and broadcast adds 1 */
    uint32_t waiters; /* threads waiting x 2, + 1 for CLOCK_MONOTONIC */
} pthread_cond_t;
#define PTHREAD_COND_INITIALIZER {0, 0}

/* Many readers or one writer; waiting writers go first (so a reader that
   locks again while a writer waits waits too) */
typedef struct {
    uint32_t state;   /* readers, or 0x80000000: a writer */
    uint32_t seq;     /* a futex word: changed when the lock is let go */
    uint32_t sleepers;
    uint32_t writers; /* waiting */
} pthread_rwlock_t;
#define PTHREAD_RWLOCK_INITIALIZER {0, 0, 0, 0}

typedef struct {
    unsigned count;
    uint32_t waiting; /* arrived this round */
    uint32_t round;   /* a futex word */
    uint32_t inside;  /* threads in pthread_barrier_wait */
} pthread_barrier_t;

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg);
int pthread_join(pthread_t thread, void **result);
int pthread_detach(pthread_t thread);
void pthread_exit(void *result) __attribute__((noreturn));
pthread_t pthread_self(void);
int pthread_equal(pthread_t a, pthread_t b);
int pthread_kill(pthread_t thread, int sig);
int pthread_cancel(pthread_t thread);
int pthread_once(pthread_once_t *once, void (*init)(void));
int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param *param);
int pthread_getschedparam(pthread_t thread, int *policy, struct sched_param *param);
int pthread_setaffinity_np(pthread_t thread, size_t size, const cpu_set_t *set);
int pthread_getaffinity_np(pthread_t thread, size_t size, cpu_set_t *set);

int pthread_attr_init(pthread_attr_t *attr);
int pthread_attr_destroy(pthread_attr_t *attr);
int pthread_attr_setdetachstate(pthread_attr_t *attr, int state);
int pthread_attr_getdetachstate(const pthread_attr_t *attr, int *state);
int pthread_attr_setstacksize(pthread_attr_t *attr, size_t size);
int pthread_attr_getstacksize(const pthread_attr_t *attr, size_t *size);
/* The stack's size only (its address: NULL); no guard size to set */
int pthread_attr_getstack(const pthread_attr_t *attr, void **addr, size_t *size);
int pthread_attr_getguardsize(const pthread_attr_t *attr, size_t *size);
int pthread_attr_setguardsize(pthread_attr_t *attr, size_t size);
int pthread_getattr_np(pthread_t thread, pthread_attr_t *attr); /* ENOSYS */
/* Threads have no names: accepted, and read back empty */
int pthread_setname_np(pthread_t thread, const char *name);
int pthread_getname_np(pthread_t thread, char *name, size_t len);
int pthread_attr_setschedparam(pthread_attr_t *attr, const struct sched_param *param);
int pthread_attr_getschedparam(const pthread_attr_t *attr, struct sched_param *param);
int pthread_attr_setschedpolicy(pthread_attr_t *attr, int policy);
int pthread_attr_getschedpolicy(const pthread_attr_t *attr, int *policy);
int pthread_attr_setinheritsched(pthread_attr_t *attr, int inherit);

int pthread_key_create(pthread_key_t *key, void (*destructor)(void *));
int pthread_key_delete(pthread_key_t key);
void *pthread_getspecific(pthread_key_t key);
int pthread_setspecific(pthread_key_t key, const void *value);

int pthread_mutexattr_init(pthread_mutexattr_t *attr);
int pthread_mutexattr_destroy(pthread_mutexattr_t *attr);
int pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type);
int pthread_mutexattr_gettype(const pthread_mutexattr_t *attr, int *type);
int pthread_mutexattr_setprotocol(pthread_mutexattr_t *attr, int protocol);
int pthread_mutexattr_getprotocol(const pthread_mutexattr_t *attr, int *protocol);
int pthread_mutexattr_setpshared(pthread_mutexattr_t *attr, int shared);
int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *attr);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_trylock(pthread_mutex_t *m);
int pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *abstime);
int pthread_mutex_unlock(pthread_mutex_t *m);
int pthread_mutex_destroy(pthread_mutex_t *m);

int pthread_condattr_init(pthread_condattr_t *attr);
int pthread_condattr_destroy(pthread_condattr_t *attr);
int pthread_condattr_setclock(pthread_condattr_t *attr, clockid_t clock);
int pthread_condattr_getclock(const pthread_condattr_t *attr, clockid_t *clock);
int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *attr);
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m);
int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abstime);
int pthread_cond_signal(pthread_cond_t *c);
int pthread_cond_broadcast(pthread_cond_t *c);
int pthread_cond_destroy(pthread_cond_t *c);

int pthread_rwlock_init(pthread_rwlock_t *l, const void *attr);
int pthread_rwlock_rdlock(pthread_rwlock_t *l);
int pthread_rwlock_wrlock(pthread_rwlock_t *l);
int pthread_rwlock_tryrdlock(pthread_rwlock_t *l);
int pthread_rwlock_trywrlock(pthread_rwlock_t *l);
int pthread_rwlock_timedrdlock(pthread_rwlock_t *l, const struct timespec *abstime);
int pthread_rwlock_timedwrlock(pthread_rwlock_t *l, const struct timespec *abstime);
int pthread_rwlock_unlock(pthread_rwlock_t *l);
int pthread_rwlock_destroy(pthread_rwlock_t *l);

int pthread_barrier_init(pthread_barrier_t *b, const void *attr, unsigned count);
int pthread_barrier_wait(pthread_barrier_t *b);
int pthread_barrier_destroy(pthread_barrier_t *b);

#ifdef __cplusplus
}
#endif

#endif
