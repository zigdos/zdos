#pragma once
#ifndef _ZDOS_TIME_H_
#define _ZDOS_TIME_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef _TIME_T_DEFINED
#define _TIME_T_DEFINED
typedef int64_t time_t;
#endif
#ifndef _CLOCK_T_DEFINED
#define _CLOCK_T_DEFINED
typedef long clock_t;
#endif

#ifndef NULL
#define NULL ((void *)0)
#endif

#define CLOCKS_PER_SEC 1000L /* clock() counts milliseconds */

struct tm {
    int tm_sec;
    int tm_min;
    int tm_hour;
    int tm_mday;
    int tm_mon;
    int tm_year;
    int tm_wday;
    int tm_yday;
    int tm_isdst;
    long tm_gmtoff;      /* seconds east of UTC (BSD, glibc) */
    const char *tm_zone; /* the zone's name */
};

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

/* ZDOS's clock is local time. Without TZ, time() counts it from 1970 as if
   it were UTC, and gmtime and localtime give the same. With TZ (POSIX form
   only, as "CET-1CEST,M3.5.0,M10.5.0/3"; no tz database) the clock is local
   time of that zone: time() is UTC, localtime adds the zone back. */
time_t time(time_t *t);
clock_t clock(void); /* milliseconds since ZDOS started */
double difftime(time_t end, time_t start);
time_t mktime(struct tm *tm); /* also fills tm_wday and tm_yday */
struct tm *gmtime(const time_t *t);
struct tm *localtime(const time_t *t);
struct tm *gmtime_r(const time_t *t, struct tm *out);
struct tm *localtime_r(const time_t *t, struct tm *out);
/* "Sun Sep 16 01:03:52 1973\n"; the _r forms into 26 bytes */
char *asctime(const struct tm *tm);
char *asctime_r(const struct tm *tm, char *buf);
char *ctime(const time_t *t); /* asctime(localtime(t)) */
char *ctime_r(const time_t *t, char *buf);
time_t timegm(struct tm *tm); /* mktime for UTC */
void tzset(void); /* reads TZ; localtime, mktime and strftime do it */
extern char *tzname[2]; /* standard and summer time names */
extern long timezone;   /* standard time, seconds west of UTC */
extern int daylight;    /* the zone has summer time */
/* To the timer's precision (microseconds on metal and BIOS); a signal may
   end it early: -1 with EINTR and the time left in rem */
int nanosleep(const struct timespec *req, struct timespec *rem);

typedef int clockid_t;
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1 /* since ZDOS started, from the CPU's counter (clock_getres: its step) */
#define CLOCK_PROCESS_CPUTIME_ID 2 /* the running task's CPU time (ms steps) */
#define CLOCK_THREAD_CPUTIME_ID 3  /* the same: a thread is a task of its own */
#define CLOCK_MONOTONIC_RAW 4
#define CLOCK_BOOTTIME 7
int clock_gettime(clockid_t id, struct timespec *ts);
int clock_getres(clockid_t id, struct timespec *res);
#define TIMER_ABSTIME 1
/* CLOCK_MONOTONIC with TIMER_ABSTIME: until that time exactly (no drift,
   as cyclictest uses it). Returns the error (EINTR, EINVAL), not -1. */
int clock_nanosleep(clockid_t clock, int flags, const struct timespec *req, struct timespec *rem);

/* POSIX timers: one per task (it shares the task's alarm and setitimer),
   SIGEV_SIGNAL or SIGEV_NONE, CLOCK_MONOTONIC or CLOCK_REALTIME */
struct sigevent;
typedef int timer_t;
struct itimerspec {
    struct timespec it_interval;
    struct timespec it_value;
};
int timer_create(clockid_t clock, struct sigevent *ev, timer_t *id);
int timer_delete(timer_t id);
int timer_settime(timer_t id, int flags, const struct itimerspec *value, struct itimerspec *old);
int timer_gettime(timer_t id, struct itimerspec *value);
int timer_getoverrun(timer_t id); /* always 0 */
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm); /* C locale */
#ifndef _LOCALE_T_DEFINED
#define _LOCALE_T_DEFINED
typedef struct zdos_locale *locale_t;
#endif
size_t strftime_l(char *s, size_t max, const char *format, const struct tm *tm, locale_t loc);
/* C locale */
char *strptime(const char *s, const char *format, struct tm *tm);

#ifdef __cplusplus
}
#endif

#endif
