#pragma once
#ifndef _ZDOS_SIGNAL_H_
#define _ZDOS_SIGNAL_H_

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Linux numbers. kill between tasks only on the metal editions;
   signals end waits with EINTR. Unhandled ones end the program
   with exit code 128 + the signal (raise(): 3). SIGINT is Ctrl+C
   (exit code 255); ignored or handled, Ctrl+C becomes a key, and
   calls the handler while stdin reads a line. */
typedef int sig_atomic_t;
typedef uint64_t sigset_t; /* bit n: signal n */

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
#define SIG_ERR ((void (*)(int))-1)

#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGTRAP 5
#define SIGABRT 6
#define SIGBUS 7
#define SIGFPE 8
#define SIGKILL 9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGCHLD 17
#define SIGCONT 18
#define SIGSTOP 19
#define SIGTSTP 20
#define SIGTTIN 21
#define SIGTTOU 22
#define SIGURG 23
#define SIGXCPU 24
#define SIGXFSZ 25
#define SIGVTALRM 26
#define SIGPROF 27
#define SIGWINCH 28
#define SIGIO 29
#define SIGPWR 30
#define SIGSYS 31
#define NSIG 64

/* sigaction's flags: SA_RESETHAND, SA_SIGINFO and SA_NOCLDWAIT (for SIGCHLD:
   children leave no status for wait, as with SIGCHLD ignored) act;
   SA_RESTART, SA_NOCLDSTOP, SA_NODEFER are accepted (calls a signal
   interrupted fail with EINTR) */
#define SA_NOCLDSTOP 0x00000001
#define SA_NOCLDWAIT 0x00000002
#define SA_SIGINFO 0x00000004
#define SA_RESTART 0x10000000
#define SA_NODEFER 0x40000000
#define SA_RESETHAND 0x80000000

#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

typedef struct {
    int si_signo;
    int si_code;
    int si_errno;
    pid_t si_pid; /* 0: unknown */
    int si_status;
    void *si_addr;
} siginfo_t;

/* For timer_create: SIGEV_SIGNAL (sigev_signo) or SIGEV_NONE */
union sigval {
    int sival_int;
    void *sival_ptr;
};
#define SIGEV_SIGNAL 0
#define SIGEV_NONE 1
#define SIGEV_THREAD 2 /* not supported (EINVAL) */
struct sigevent {
    int sigev_notify;
    int sigev_signo;
    union sigval sigev_value;
    void (*sigev_notify_function)(union sigval);
    void *sigev_notify_attributes;
};

struct sigaction {
    union {
        void (*sa_handler)(int);
        void (*sa_sigaction)(int, siginfo_t *, void *);
    };
    sigset_t sa_mask;
    int sa_flags;
};

void (*signal(int sig, void (*handler)(int)))(int);
int raise(int sig);
int kill(pid_t pid, int sig); /* pid: a task (getpid); 0 and -1 not supported */
int killpg(pid_t pgrp, int sig); /* no process groups: kill(pgrp, sig) */
int sigaction(int sig, const struct sigaction *act, struct sigaction *old);
int sigprocmask(int how, const sigset_t *set, sigset_t *old);
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old);
int sigpending(sigset_t *set);
int sigsuspend(const sigset_t *mask);
int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);
int sigdelset(sigset_t *set, int sig);
int sigismember(const sigset_t *set, int sig);

#ifdef __cplusplus
}
#endif

#endif
