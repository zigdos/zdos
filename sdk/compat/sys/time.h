#pragma once
#ifndef _ZDOS_SYS_TIME_H_
#define _ZDOS_SYS_TIME_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

struct timeval {
    time_t tv_sec;
    suseconds_t tv_usec;
};

/* Seconds since 1970 from the local clock (ZDOS has no time zone); the
   microseconds come from the millisecond counter. tz is ignored. */
int gettimeofday(struct timeval *tv, void *tz);
/* Sets the modification time to times[1] (NULL: now); times[0], the access
   time, is not kept */
int utimes(const char *path, const struct timeval times[2]);
/* utimes of an open file (ENOSYS on a ZDOS without files->fset_time) */
int futimes(int fd, const struct timeval times[2]);

/* ITIMER_REAL (SIGALRM) only, the task's one timer (alarm's too) */
#define ITIMER_REAL 0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF 2
struct itimerval {
    struct timeval it_interval;
    struct timeval it_value;
};
int setitimer(int which, const struct itimerval *value, struct itimerval *old);
int getitimer(int which, struct itimerval *value);

#ifdef __cplusplus
}
#endif

#endif
