#pragma once
#ifndef _ZDOS_SYS_TIMES_H_
#define _ZDOS_SYS_TIMES_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CPU times in clock ticks (sysconf(_SC_CLK_TCK): 1000 a second); the
   task's own as user time, its ended children's not counted. Returns
   the milliseconds since startup. (zdos_unix.c) */
struct tms {
    clock_t tms_utime;
    clock_t tms_stime;
    clock_t tms_cutime;
    clock_t tms_cstime;
};

clock_t times(struct tms *t);

#ifdef __cplusplus
}
#endif
#endif
