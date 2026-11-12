/* NetBSD's kqueue (sys/event.h) on ZDOS's event queues: one queue
 * watch per descriptor; its filters (EVFILT_READ, EVFILT_WRITE) are
 * kept here and reported as events of their own. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <time.h>
#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"

int32_t zdos_fd_poll_handle(int fd); /* zdos_fs.c */

typedef struct {
    bool on, enabled;
    uint32_t flags; /* EV_CLEAR, EV_ONESHOT, EV_DISPATCH as added */
    void *udata;
} filter;

typedef struct {
    int fd;
    int32_t handle;
    bool watched; /* the queue has a watch of handle */
    filter f[2]; /* EVFILT_READ, EVFILT_WRITE */
} reg;

typedef struct {
    int32_t handle;
    reg *regs;
    int count, cap;
    struct kevent left; /* made, but it didn't fit: the next call's */
    bool has_left;
} kq;

static kq *queues[ZDOS_MAX_FILES];
static uint32_t lock_word; /* all of the above */

static int fail(int e) {
    errno = e;
    return -1;
}

int kqueue1(int flags) {
    if (flags & ~(O_CLOEXEC | O_NONBLOCK)) return fail(EINVAL);
    kq *k = calloc(1, sizeof(kq));
    if (k == NULL) return fail(ENOMEM);
    int32_t h = zdos->files->queue_create(0);
    if (h < 0) {
        free(k);
        return fail(zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? ENOSYS : zdos_errno_from_last_error());
    }
    int fd = zdos_fd_for_handle(h);
    if (fd < 0 || fd >= ZDOS_MAX_FILES) {
        free(k);
        if (fd >= 0) zdos->files->close(h);
        return fd < 0 ? -1 : fail(EMFILE);
    }
    k->handle = h;
    zdos_word_lock(&lock_word);
    kq *old = queues[fd]; /* a closed kqueue's, its descriptor reused */
    queues[fd] = k;
    zdos_word_unlock(&lock_word);
    if (old != NULL) {
        free(old->regs);
        free(old);
    }
    return fd;
}

int kqueue(void) {
    return kqueue1(0);
}

/* The kqueue of fd, the lock held; NULL: none (the lock let go) */
static kq *take(int fd) {
    if (fd < 0 || fd >= ZDOS_MAX_FILES) return NULL;
    int32_t h = zdos_fd_poll_handle(fd);
    zdos_word_lock(&lock_word);
    kq *k = queues[fd];
    if (k != NULL && k->handle == h) return k;
    zdos_word_unlock(&lock_word);
    return NULL;
}

static reg *find(kq *k, int fd) {
    for (int i = 0; i < k->count; i++) {
        if (k->regs[i].fd == fd) return &k->regs[i];
    }
    return NULL;
}

static int queue_change(kq *k, reg *r, uint32_t op, uint32_t events) {
    zdos_queue_change c = {r->handle, op, events, 0, (uint64_t)(uint32_t)r->fd};
    return zdos->files->queue_events(k->handle, &c, 1, NULL, 0, 0) == 0 ? 0 : (int)zdos->programs->last_error();
}

/* r's watch as its filters want it: edge only if all of them clear */
static int sync_watch(kq *k, reg *r) {
    uint32_t bits = 0;
    bool clear = true;
    static const uint32_t want[2] = {ZDOS_QUEUE_IN | ZDOS_QUEUE_READ_HUP, ZDOS_QUEUE_OUT};
    for (int i = 0; i < 2; i++) {
        if (!r->f[i].on || !r->f[i].enabled) continue;
        bits |= want[i];
        clear = clear && (r->f[i].flags & EV_CLEAR);
    }
    if (bits == 0) {
        if (r->watched) queue_change(k, r, ZDOS_QUEUE_DELETE, 0);
        r->watched = false;
        return 0;
    }
    if (clear) bits |= ZDOS_QUEUE_EDGE;
    int code = queue_change(k, r, r->watched ? ZDOS_QUEUE_MODIFY : ZDOS_QUEUE_ADD, bits);
    if (code == ZDOS_ERROR_NOT_FOUND) code = queue_change(k, r, ZDOS_QUEUE_ADD, bits);
    if (code == ZDOS_ERROR_ALREADY_EXISTS) code = queue_change(k, r, ZDOS_QUEUE_MODIFY, bits);
    r->watched = code == 0;
    if (code == 0) return 0;
    if (code == ZDOS_ERROR_NOT_SUPPORTED) return ENOTSUP;
    if (code == ZDOS_ERROR_INVALID_HANDLE) return EBADF;
    if (code == ZDOS_ERROR_OUT_OF_MEMORY) return ENOMEM;
    return EINVAL;
}

static void forget(kq *k, reg *r) {
    *r = k->regs[--k->count];
}

/* One change; an errno, or 0 */
static int apply(kq *k, const struct kevent *ch) {
    if (ch->filter == EVFILT_AIO || ch->filter == EVFILT_VNODE || ch->filter == EVFILT_PROC ||
        ch->filter == EVFILT_SIGNAL || ch->filter == EVFILT_TIMER || ch->filter == EVFILT_FS ||
        ch->filter == EVFILT_USER || ch->filter == EVFILT_EMPTY)
        return ENOTSUP;
    if (ch->filter != EVFILT_READ && ch->filter != EVFILT_WRITE) return EINVAL;
    if (ch->ident >= ZDOS_MAX_FILES) return EBADF;
    int fd = (int)ch->ident;
    int32_t h = zdos_fd_poll_handle(fd);
    if (h == -100) return EBADF;
    if (h < 0) return ENOTSUP; /* the screen, the keyboard, memory streams */
    int which = (int)ch->filter;
    reg *r = find(k, fd);
    if (r != NULL && r->handle != h) {
        /* Closed and opened again: the queue dropped its watch */
        forget(k, r);
        r = NULL;
    }
    if (r == NULL || !r->f[which].on) {
        if (!(ch->flags & EV_ADD)) return ENOENT;
        if (r == NULL) {
            if (k->count == k->cap) {
                int cap = k->cap ? k->cap * 2 : 8;
                reg *more = realloc(k->regs, (size_t)cap * sizeof(reg));
                if (more == NULL) return ENOMEM;
                k->regs = more;
                k->cap = cap;
            }
            r = &k->regs[k->count++];
            memset(r, 0, sizeof(*r));
            r->fd = fd;
            r->handle = h;
        }
    }
    filter *f = &r->f[which];
    filter was = *f;
    if (ch->flags & EV_DELETE) {
        f->on = false;
    } else {
        if (ch->flags & EV_ADD) {
            f->on = true;
            f->enabled = true;
            f->flags = ch->flags & (EV_CLEAR | EV_ONESHOT | EV_DISPATCH);
            f->udata = ch->udata;
        }
        if (ch->flags & EV_ENABLE) f->enabled = true;
        if (ch->flags & EV_DISABLE) f->enabled = false;
    }
    int e = sync_watch(k, r);
    if (e != 0) {
        *f = was;
        if (!r->f[0].on && !r->f[1].on && !r->watched) forget(k, r);
        return e;
    }
    if (!r->f[0].on && !r->f[1].on) forget(k, r);
    return 0;
}

/* The event for filter which of fd from a queue event's bits, if it
   still wants one; EV_ONESHOT and EV_DISPATCH take effect here */
static bool deliver(kq *k, int fd, int which, uint32_t bits, struct kevent *out) {
    reg *r = find(k, fd);
    if (r == NULL || !r->watched) return false;
    filter *f = &r->f[which];
    if (!f->on || !f->enabled) return false;
    uint32_t eof;
    if (which == EVFILT_READ) {
        if (!(bits & (ZDOS_QUEUE_IN | ZDOS_QUEUE_READ_HUP | ZDOS_QUEUE_HUP | ZDOS_QUEUE_ERR))) return false;
        eof = bits & (ZDOS_QUEUE_READ_HUP | ZDOS_QUEUE_HUP | ZDOS_QUEUE_ERR);
    } else {
        if (!(bits & (ZDOS_QUEUE_OUT | ZDOS_QUEUE_HUP | ZDOS_QUEUE_ERR))) return false;
        eof = bits & (ZDOS_QUEUE_HUP | ZDOS_QUEUE_ERR);
    }
    out->ident = (uintptr_t)fd;
    out->filter = (uint32_t)which;
    out->flags = EV_ADD | f->flags | (eof ? EV_EOF : 0);
    out->fflags = 0;
    out->data = 0;
    out->udata = f->udata;
    if (f->flags & (EV_ONESHOT | EV_DISPATCH)) {
        if (f->flags & EV_ONESHOT) f->on = false;
        f->enabled = false;
        sync_watch(k, r);
        if (!r->f[0].on && !r->f[1].on) forget(k, r);
    }
    return true;
}

/* Milliseconds for queue_events: rounded up; -1: no limit */
static int32_t timeout_ms(const struct timespec *t) {
    if (t == NULL) return -1;
    int64_t ms = (int64_t)t->tv_sec * 1000 + (t->tv_nsec + 999999) / 1000000;
    return ms > INT32_MAX ? INT32_MAX : (int32_t)ms;
}

static int64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int kevent(int kqfd, const struct kevent *changelist, size_t nchanges, struct kevent *eventlist, size_t nevents,
           const struct timespec *timeout) {
    if (timeout != NULL && (timeout->tv_sec < 0 || timeout->tv_nsec < 0 || timeout->tv_nsec >= 1000000000L))
        return fail(EINVAL);
    if ((nchanges > 0 && changelist == NULL) || (nevents > 0 && eventlist == NULL)) return fail(EFAULT);
    if (nevents > INT_MAX) nevents = INT_MAX;
    kq *k = take(kqfd);
    if (k == NULL) return fail(EBADF);
    size_t n = 0;
    bool errors = false;
    for (size_t i = 0; i < nchanges; i++) {
        const struct kevent *ch = &changelist[i];
        int e = apply(k, ch);
        if (e == 0 && !(ch->flags & EV_RECEIPT)) continue;
        if (n == nevents) {
            if (e == 0) continue;
            zdos_word_unlock(&lock_word);
            return fail(e);
        }
        eventlist[n] = *ch;
        eventlist[n].flags = EV_ERROR;
        eventlist[n].data = e;
        n++;
        errors = true;
    }
    int32_t handle = k->handle;
    if (errors || nevents == 0) {
        zdos_word_unlock(&lock_word);
        return (int)n;
    }
    if (k->has_left) {
        k->has_left = false;
        eventlist[n++] = k->left;
    }
    zdos_word_unlock(&lock_word);
    int32_t ms = timeout_ms(timeout);
    int64_t until = ms > 0 ? now_ms() + ms : 0;
    zdos_queue_event got[32];
    while (n < nevents) {
        /* A queue event may make two (READ and WRITE): one may be left: */
        size_t room = nevents - n;
        uint32_t want = (uint32_t)(room < 64 ? (room + 1) / 2 : 32);
        int32_t wait = n > 0 ? 0 : ms;
        if (wait > 0) {
            int64_t rest = until - now_ms();
            wait = rest > 0 ? (int32_t)rest : 0;
        }
        int32_t r = zdos->files->queue_events(handle, NULL, 0, got, want, wait);
        if (r < 0) {
            if (n > 0) break;
            uint32_t code = zdos->programs->last_error();
            return fail(code == ZDOS_ERROR_INVALID_HANDLE ? EBADF : zdos_errno_from_last_error());
        }
        kq *again = take(kqfd);
        if (again != k) {
            if (again != NULL) zdos_word_unlock(&lock_word);
            break;
        }
        for (int32_t i = 0; i < r; i++) {
            int fd = (int)got[i].data;
            for (int which = 0; which < 2; which++) {
                if (n < nevents) {
                    if (deliver(k, fd, which, got[i].events, &eventlist[n])) n++;
                } else if (!k->has_left && deliver(k, fd, which, got[i].events, &k->left)) {
                    k->has_left = true;
                }
            }
        }
        zdos_word_unlock(&lock_word);
        if ((uint32_t)r < want && (n > 0 || wait == 0)) break;
    }
    return (int)n;
}
