#pragma once
#ifndef _ZDOS_SCHED_H_
#define _ZDOS_SCHED_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ZDOS schedules by fixed priority, 0-31 (higher first; 16 is a new task's
   unless it gets its starter's): SCHED_RR takes turns within a priority
   every 10 ms (the default; SCHED_OTHER is the same), SCHED_FIFO keeps the
   CPU until it waits or a higher priority comes */
#define SCHED_OTHER 0
#define SCHED_FIFO 1
#define SCHED_RR 2
/* Earliest deadline first, above every priority: sched_setattr with
   sched_runtime <= sched_deadline <= sched_period (nanoseconds); EBUSY if
   the deadline tasks would need over 95% of the cores. Not inherited. */
#define SCHED_DEADLINE 6

/* Linux's sched_setattr / sched_getattr (pid 0: the caller) */
struct sched_attr {
    unsigned int size;
    unsigned int sched_policy;
    unsigned long long sched_flags;
    int sched_nice;
    unsigned int sched_priority;
    unsigned long long sched_runtime;
    unsigned long long sched_deadline;
    unsigned long long sched_period;
};
int sched_setattr(pid_t pid, struct sched_attr *attr, unsigned int flags);
int sched_getattr(pid_t pid, struct sched_attr *attr, unsigned int size, unsigned int flags);

struct sched_param {
    int sched_priority;
};

int sched_yield(void);
int sched_get_priority_min(int policy);
int sched_get_priority_max(int policy);
int sched_setparam(pid_t pid, const struct sched_param *param);
int sched_getparam(pid_t pid, struct sched_param *param);
int sched_setscheduler(pid_t pid, int policy, const struct sched_param *param);
int sched_getscheduler(pid_t pid);

/* The cores a task may run on, as Linux's (bit n: core n) */
#define CPU_SETSIZE 1024
typedef struct {
    unsigned long __bits[CPU_SETSIZE / (8 * sizeof(unsigned long))];
} cpu_set_t;
#define __ZDOS_CPU_W(c) ((c) / (8 * sizeof(unsigned long)))
#define __ZDOS_CPU_B(c) (1UL << ((c) % (8 * sizeof(unsigned long))))
#define CPU_ZERO(s) __builtin_memset((s), 0, sizeof(cpu_set_t))
#define CPU_SET(c, s) ((void)((c) < CPU_SETSIZE && ((s)->__bits[__ZDOS_CPU_W(c)] |= __ZDOS_CPU_B(c))))
#define CPU_CLR(c, s) ((void)((c) < CPU_SETSIZE && ((s)->__bits[__ZDOS_CPU_W(c)] &= ~__ZDOS_CPU_B(c))))
#define CPU_ISSET(c, s) ((c) < CPU_SETSIZE && ((s)->__bits[__ZDOS_CPU_W(c)] & __ZDOS_CPU_B(c)) != 0)
int __zdos_cpu_count(size_t size, const cpu_set_t *set);
#define CPU_COUNT(s) __zdos_cpu_count(sizeof(cpu_set_t), (s))
int sched_setaffinity(pid_t pid, size_t size, const cpu_set_t *set);
int sched_getaffinity(pid_t pid, size_t size, cpu_set_t *set);

#ifdef __cplusplus
}
#endif

#endif
