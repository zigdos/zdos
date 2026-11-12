#pragma once
#ifndef _ZDOS_SYS_EVENT_H_
#define _ZDOS_SYS_EVENT_H_

#include <stddef.h>
#include <stdint.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* NetBSD's kqueue on ZDOS's event queues (zdos_kqueue.c): EVFILT_READ and
   EVFILT_WRITE on sockets, pipes and eventfd descriptors; other filters
   fail with ENOTSUP. */
struct kevent {
    uintptr_t ident;
    uint32_t filter;
    uint32_t flags;
    uint32_t fflags;
    int64_t data;
    void *udata;
};

#define EV_SET(kevp, a, b, c, d, e, f)                                         \
    do {                                                                       \
        struct kevent *__kevp = (kevp);                                        \
        __kevp->ident = (a);                                                   \
        __kevp->filter = (b);                                                  \
        __kevp->flags = (c);                                                   \
        __kevp->fflags = (d);                                                  \
        __kevp->data = (e);                                                    \
        __kevp->udata = (void *)(f);                                           \
    } while (0)

#define EVFILT_READ 0U
#define EVFILT_WRITE 1U
#define EVFILT_AIO 2U
#define EVFILT_VNODE 3U
#define EVFILT_PROC 4U
#define EVFILT_SIGNAL 5U
#define EVFILT_TIMER 6U
#define EVFILT_FS 7U
#define EVFILT_USER 8U
#define EVFILT_EMPTY 9U
#define EVFILT_SYSCOUNT 10U

#define EV_ADD 0x0001U
#define EV_DELETE 0x0002U
#define EV_ENABLE 0x0004U
#define EV_DISABLE 0x0008U
#define EV_ONESHOT 0x0010U
#define EV_CLEAR 0x0020U
#define EV_RECEIPT 0x0040U
#define EV_DISPATCH 0x0080U
#define EV_SYSFLAGS 0xF000U
#define EV_FLAG1 0x2000U
#define EV_ERROR 0x4000U
#define EV_EOF 0x8000U

int kqueue(void);
int kqueue1(int flags);
int kevent(int kq, const struct kevent *changelist, size_t nchanges, struct kevent *eventlist, size_t nevents,
           const struct timespec *timeout);

#ifdef __cplusplus
}
#endif

#endif
