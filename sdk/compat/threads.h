#pragma once
#ifndef _ZDOS_THREADS_H_
#define _ZDOS_THREADS_H_

#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* C11 threads, over the pthreads of zdos_posix.c (tasks need
   the metal editions; elsewhere thrd_create fails with thrd_error) */
enum { thrd_success = 0, thrd_busy = 1, thrd_error = 2, thrd_nomem = 3, thrd_timedout = 4 };
enum { mtx_plain = 0, mtx_recursive = 1, mtx_timed = 2 };

typedef pthread_t thrd_t;
typedef pthread_mutex_t mtx_t;
typedef pthread_cond_t cnd_t;
typedef pthread_key_t tss_t;
typedef pthread_once_t once_flag;
typedef int (*thrd_start_t)(void *);
typedef void (*tss_dtor_t)(void *);
#define ONCE_FLAG_INIT PTHREAD_ONCE_INIT
#define TSS_DTOR_ITERATIONS 4
#ifndef __cplusplus
#define thread_local _Thread_local
#endif

static inline int zdos_thrd_result(int r) {
    return r == 0 ? thrd_success : r == ENOMEM ? thrd_nomem : r == EBUSY ? thrd_busy : r == ETIMEDOUT ? thrd_timedout : thrd_error;
}

struct zdos_thrd_start {
    thrd_start_t func;
    void *arg;
};

static inline void *zdos_thrd_trampoline(void *p) {
    struct zdos_thrd_start s = *(struct zdos_thrd_start *)p;
    free(p);
    return (void *)(intptr_t)s.func(s.arg);
}

static inline int thrd_create(thrd_t *t, thrd_start_t func, void *arg) {
    struct zdos_thrd_start *s = (struct zdos_thrd_start *)malloc(sizeof(*s));
    if (s == NULL) {
        return thrd_nomem;
    }
    s->func = func;
    s->arg = arg;
    int r = pthread_create(t, NULL, zdos_thrd_trampoline, s);
    if (r != 0) {
        free(s);
    }
    return zdos_thrd_result(r);
}

static inline int thrd_join(thrd_t t, int *res) {
    void *v;
    int r = pthread_join(t, &v);
    if (r == 0 && res != NULL) {
        *res = (int)(intptr_t)v;
    }
    return zdos_thrd_result(r);
}

static inline int thrd_detach(thrd_t t) { return zdos_thrd_result(pthread_detach(t)); }
static inline thrd_t thrd_current(void) { return pthread_self(); }
static inline int thrd_equal(thrd_t a, thrd_t b) { return pthread_equal(a, b); }
static inline void thrd_yield(void) { sched_yield(); }
__attribute__((noreturn)) static inline void thrd_exit(int res) { pthread_exit((void *)(intptr_t)res); }
static inline int thrd_sleep(const struct timespec *d, struct timespec *rem) {
    return nanosleep(d, rem) == 0 ? 0 : (errno == EINTR ? -1 : -2);
}

static inline int mtx_init(mtx_t *m, int type) {
    pthread_mutexattr_t a;
    pthread_mutexattr_init(&a);
    if (type & mtx_recursive) {
        pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE);
    }
    int r = pthread_mutex_init(m, &a);
    pthread_mutexattr_destroy(&a);
    return zdos_thrd_result(r);
}
static inline int mtx_lock(mtx_t *m) { return zdos_thrd_result(pthread_mutex_lock(m)); }
static inline int mtx_trylock(mtx_t *m) { return zdos_thrd_result(pthread_mutex_trylock(m)); }
static inline int mtx_timedlock(mtx_t *m, const struct timespec *at) { return zdos_thrd_result(pthread_mutex_timedlock(m, at)); }
static inline int mtx_unlock(mtx_t *m) { return zdos_thrd_result(pthread_mutex_unlock(m)); }
static inline void mtx_destroy(mtx_t *m) { pthread_mutex_destroy(m); }

static inline int cnd_init(cnd_t *c) { return zdos_thrd_result(pthread_cond_init(c, NULL)); }
static inline int cnd_signal(cnd_t *c) { return zdos_thrd_result(pthread_cond_signal(c)); }
static inline int cnd_broadcast(cnd_t *c) { return zdos_thrd_result(pthread_cond_broadcast(c)); }
static inline int cnd_wait(cnd_t *c, mtx_t *m) { return zdos_thrd_result(pthread_cond_wait(c, m)); }
static inline int cnd_timedwait(cnd_t *c, mtx_t *m, const struct timespec *at) { return zdos_thrd_result(pthread_cond_timedwait(c, m, at)); }
static inline void cnd_destroy(cnd_t *c) { pthread_cond_destroy(c); }

static inline int tss_create(tss_t *k, tss_dtor_t dtor) { return zdos_thrd_result(pthread_key_create(k, dtor)); }
static inline void *tss_get(tss_t k) { return pthread_getspecific(k); }
static inline int tss_set(tss_t k, void *v) { return zdos_thrd_result(pthread_setspecific(k, v)); }
static inline void tss_delete(tss_t k) { pthread_key_delete(k); }

static inline void call_once(once_flag *flag, void (*func)(void)) { pthread_once(flag, func); }

#ifdef __cplusplus
}
#endif
#endif
