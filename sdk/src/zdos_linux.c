/* Linux and glibc functions that code built for Linux expects (Rust's std,
 * ported programs), on the ZDOS ABI: syscall() with a futex, getauxval,
 * dl_iterate_phdr, sigaltstack, the *at() functions over directory
 * descriptors, pipe2, epoll and eventfd, environ ... zdos_musl.c adapts
 * musl's layouts to them. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"
#include "zdos_linux.h"

static int fail(int e) {
    errno = e;
    return -1;
}

/* THE FUTEX
   ZDOS's own (threads->futex_wait ...) where it has them. On an older ZDOS
   waiters wait on one ZDOS condition under one ZDOS mutex (both are few:
   64 of each in all of ZDOS); a wake marks the waiters it picks and wakes
   them all, the others wait again. No wake is lost: the value is checked
   and the waiter listed under the mutex the waker takes. */

static bool kfutex(void) {
    return zdos_futex_ok(); /* zdos_libc.c */
}

static long kfutex_wait(const volatile uint32_t *addr, uint32_t val, uint64_t deadline, uint32_t bits) {
    int32_t ms = -1;
    if (deadline != UINT64_MAX) {
        uint64_t now = zdos->time->millis();
        uint64_t left = deadline > now ? deadline - now : 0;
        ms = left > 0x7fffffff ? 0x7fffffff : (int32_t)left;
    }
    switch (zdos->threads->futex_wait((const uint32_t *)addr, val, ms, bits)) {
        case ZDOS_ERROR_NONE: return 0;
        case ZDOS_ERROR_WOULD_BLOCK: return -EAGAIN;
        case ZDOS_ERROR_TIMED_OUT: return -ETIMEDOUT;
        case ZDOS_ERROR_INTERRUPTED: return -EINTR;
        default: return -EINVAL;
    }
}

static long kfutex_wake(const volatile uint32_t *addr, int n, uint32_t bits, const volatile uint32_t *addr2, int n2,
                        const uint32_t *cmp) {
    uint32_t count = n < 0 ? 0 : (uint32_t)n;
    if (addr2 == NULL) {
        int32_t r = zdos->threads->futex_wake((const uint32_t *)addr, count, bits);
        return r < 0 ? -EINVAL : r;
    }
    if (addr2 == NULL || ((uintptr_t)addr2 & 3) != 0) return -EINVAL;
    for (;;) {
        // FUTEX_REQUEUE compares with what the word holds now
        uint32_t expected = cmp != NULL ? *cmp : __atomic_load_n(addr, __ATOMIC_SEQ_CST);
        int32_t r = zdos->threads->futex_requeue((const uint32_t *)addr, expected, count, (const uint32_t *)addr2,
                                                 n2 < 0 ? 0 : (uint32_t)n2);
        if (r >= 0) return r;
        if (cmp != NULL) return -EAGAIN; /* the word isn't *cmp (the address was checked) */
    }
}

struct futex_waiter {
    const volatile uint32_t *addr;
    uint32_t bits;
    bool woken;
    struct futex_waiter *next;
};
static int32_t futex_mutex = -1;
static int32_t futex_cond = -1;
static struct futex_waiter *futex_waiters;

static bool futex_ready(void) {
    if (__atomic_load_n(&futex_cond, __ATOMIC_ACQUIRE) >= 0) return true;
    zdos_init_lock_take();
    if (futex_cond < 0) {
        int32_t m = zdos->tasks->mutex_create();
        int32_t c = m >= 0 ? zdos->threads->cond_create() : -1;
        if (c >= 0) {
            futex_mutex = m;
            __atomic_store_n(&futex_cond, c, __ATOMIC_RELEASE);
        } else if (m >= 0) {
            zdos->tasks->mutex_destroy(m);
        }
    }
    zdos_init_lock_give();
    return futex_cond >= 0;
}

static void futex_lock(void) {
    while (!zdos->tasks->mutex_lock(futex_mutex)) {
        if (zdos->programs->last_error() != ZDOS_ERROR_INTERRUPTED) break;
    }
}

static void futex_unlink(struct futex_waiter *w) {
    for (struct futex_waiter **p = &futex_waiters; *p != NULL; p = &(*p)->next) {
        if (*p == w) {
            *p = w->next;
            return;
        }
    }
}

/* deadline: milliseconds of the monotonic clock, UINT64_MAX for none */
static long futex_wait(const volatile uint32_t *addr, uint32_t val, uint64_t deadline, uint32_t bits) {
    if (addr == NULL || ((uintptr_t)addr & 3) != 0) return -EINVAL;
    if (kfutex()) return kfutex_wait(addr, val, deadline, bits);
    if (!futex_ready()) {
        if (__atomic_load_n(addr, __ATOMIC_SEQ_CST) != val) return -EAGAIN;
        if (deadline == UINT64_MAX) return -ENOMEM;
        uint64_t now = zdos->time->millis();
        if (deadline > now) zdos->time->nap((uint32_t)(deadline - now > 0x7fffffff ? 0x7fffffff : deadline - now));
        return -ETIMEDOUT;
    }
    futex_lock();
    if (__atomic_load_n(addr, __ATOMIC_SEQ_CST) != val) {
        zdos->tasks->mutex_unlock(futex_mutex);
        return -EAGAIN;
    }
    struct futex_waiter w = {addr, bits, false, futex_waiters};
    futex_waiters = &w;
    long r = 0;
    while (!w.woken) {
        int32_t ms = -1;
        if (deadline != UINT64_MAX) {
            uint64_t now = zdos->time->millis();
            if (now >= deadline) {
                futex_unlink(&w);
                r = -ETIMEDOUT;
                break;
            }
            ms = deadline - now > 0x7fffffff ? 0x7fffffff : (int32_t)(deadline - now);
        }
        if (!zdos->threads->cond_wait(futex_cond, futex_mutex, ms)) {
            uint32_t err = zdos->programs->last_error();
            if (err == ZDOS_ERROR_INTERRUPTED && !w.woken) {
                futex_unlink(&w);
                r = -EINTR;
                break;
            }
            if (err == ZDOS_ERROR_INVALID_ARGUMENT) {
                // No task switching: nobody can wake it
                futex_unlink(&w);
                zdos->tasks->mutex_unlock(futex_mutex);
                if (ms > 0) zdos->time->nap((uint32_t)ms);
                return ms < 0 ? 0 : -ETIMEDOUT;
            }
        }
    }
    zdos->tasks->mutex_unlock(futex_mutex);
    return r;
}

/* Wakes up to n waiters on addr; with addr2, moves up to n2 more there */
static long futex_wake(const volatile uint32_t *addr, int n, uint32_t bits, const volatile uint32_t *addr2, int n2,
                       const uint32_t *cmp) {
    if (addr == NULL || ((uintptr_t)addr & 3) != 0) return -EINVAL;
    if (kfutex()) return kfutex_wake(addr, n, bits, addr2, n2, cmp);
    if (__atomic_load_n(&futex_cond, __ATOMIC_ACQUIRE) < 0) {
        return cmp != NULL && __atomic_load_n(addr, __ATOMIC_SEQ_CST) != *cmp ? -EAGAIN : 0;
    }
    futex_lock();
    if (cmp != NULL && __atomic_load_n(addr, __ATOMIC_SEQ_CST) != *cmp) {
        zdos->tasks->mutex_unlock(futex_mutex);
        return -EAGAIN;
    }
    long woken = 0, moved = 0;
    for (struct futex_waiter **p = &futex_waiters; *p != NULL;) {
        struct futex_waiter *w = *p;
        if (w->addr == addr && (w->bits & bits) != 0) {
            if (woken < n) {
                w->woken = true;
                *p = w->next;
                woken++;
                continue;
            }
            if (addr2 != NULL && moved < n2) {
                w->addr = addr2;
                moved++;
            }
        }
        p = &w->next;
    }
    if (woken > 0) zdos->threads->cond_broadcast(futex_cond);
    zdos->tasks->mutex_unlock(futex_mutex);
    return woken + (cmp != NULL ? moved : 0);
}

/* The kernel's timespec of this CPU's futex call */
struct ktimespec {
    long tv_sec;
    long tv_nsec;
};

static uint64_t ms_of(int64_t sec, long nsec) {
    if (sec < 0) return 0;
    return (uint64_t)sec * 1000 + ((uint64_t)nsec + 999999) / 1000000;
}

static uint64_t realtime_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

long zdos_futex(uint32_t *addr, int op, uint32_t val, int64_t sec, long nsec, bool has_time, uint32_t *addr2,
                uint32_t val3) {
    if (zdos == NULL) return -ENOSYS;
    bool realtime = (op & 256) != 0; /* FUTEX_CLOCK_REALTIME */
    uint64_t deadline = UINT64_MAX;
    switch (op & 127) {
        case 0: /* FUTEX_WAIT: relative time */
            if (has_time) deadline = zdos->time->millis() + ms_of(sec, nsec);
            return futex_wait(addr, val, deadline, 0xffffffffu);
        case 9: /* FUTEX_WAIT_BITSET: absolute time */
            if (val3 == 0) return -EINVAL;
            if (has_time) {
                uint64_t at = ms_of(sec, nsec), now = zdos->time->millis();
                if (realtime) {
                    uint64_t rt = realtime_ms();
                    deadline = at > rt ? now + (at - rt) : now;
                } else {
                    deadline = at;
                }
            }
            return futex_wait(addr, val, deadline, val3);
        case 1: /* FUTEX_WAKE */
            return futex_wake(addr, (int)val, 0xffffffffu, NULL, 0, NULL);
        case 10: /* FUTEX_WAKE_BITSET */
            return val3 == 0 ? -EINVAL : futex_wake(addr, (int)val, val3, NULL, 0, NULL);
        case 3: /* FUTEX_REQUEUE: the timeout argument is the count to move */
            return futex_wake(addr, (int)val, 0xffffffffu, addr2, (int)sec, NULL);
        case 4: /* FUTEX_CMP_REQUEUE */
            return futex_wake(addr, (int)val, 0xffffffffu, addr2, (int)sec, &val3);
        default: /* WAKE_OP and the PI ones */
            return -ENOSYS;
    }
}

/* SYSCALL
   Linux's numbers for each CPU (sys/syscall.h); others fail with ENOSYS, so
   callers (Rust's std: statx, copy_file_range, pidfd_open ...) fall back. */
#ifndef SYS_futex_time64
#define SYS_futex_time64 (-1)
#endif

/* getentropy in steps of its 256-byte limit */
static long random_fill(void *buf, size_t len) {
    unsigned char *p = buf;
    for (size_t done = 0; done < len; done += 256) {
        if (getentropy(p + done, len - done < 256 ? len - done : 256) != 0) return -errno;
    }
    return (long)len;
}

long syscall(long number, ...) {
    va_list ap;
    va_start(ap, number);
    long a[6];
    for (int i = 0; i < 6; i++) {
        a[i] = va_arg(ap, long);
    }
    va_end(ap);
    long r;
    if (number == SYS_futex || number == SYS_futex_time64) {
        int op = (int)a[1];
        int cmd = op & 127;
        bool timed = cmd == 0 || cmd == 9;
        int64_t sec = 0;
        long nsec = 0;
        bool has_time = false;
        if (timed && a[3] != 0) {
            if (number == SYS_futex) {
                const struct ktimespec *ts = (const struct ktimespec *)a[3];
                sec = ts->tv_sec;
                nsec = ts->tv_nsec;
            } else {
                const int64_t *ts = (const int64_t *)a[3]; /* {int64 sec, int64 nsec} */
                sec = ts[0];
                nsec = (long)ts[1];
            }
            has_time = true;
        } else if (!timed) {
            sec = a[3]; /* the requeue count */
        }
        r = zdos_futex((uint32_t *)a[0], op, (uint32_t)a[2], sec, nsec, has_time, (uint32_t *)a[4], (uint32_t)a[5]);
    } else if (number == SYS_getrandom) {
        r = random_fill((void *)a[0], (size_t)a[1]);
    } else if (number == SYS_gettid || number == SYS_getpid) {
        r = getpid();
    } else if (number == SYS_sched_yield) {
        if (zdos != NULL) zdos->tasks->yield();
        r = 0;
    } else {
        r = -ENOSYS;
    }
    if (r < 0 && r > -4096) {
        errno = (int)-r;
        return -1;
    }
    return r;
}

/* Which cores the process may run on isn't something ZDOS tells:
   callers ask sysconf(_SC_NPROCESSORS_ONLN) instead */
pid_t gettid(void) {
    return getpid();
}

/* THE PROCESS */

/* AT_PAGESZ; the rest (AT_HWCAP ...) isn't known: 0 with ENOENT */
unsigned long getauxval(unsigned long type) {
    if (type == 6) return 4096;
    errno = ENOENT;
    return 0;
}

extern char __eh_frame_hdr_start[], __eh_frame_hdr_end[];

/* One object: the program, a segment over all memory (programs are flat
   images, loaded anywhere) and its unwinding table. Enough for libunwind. */
struct zdos_phdr {
#if UINTPTR_MAX > 0xffffffffu
    uint32_t p_type, p_flags;
    uint64_t p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align;
#else
    uint32_t p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align;
#endif
};
struct zdos_phdr_info {
    uintptr_t dlpi_addr;
    const char *dlpi_name;
    const struct zdos_phdr *dlpi_phdr;
    uint16_t dlpi_phnum;
    unsigned long long dlpi_adds, dlpi_subs;
    size_t dlpi_tls_modid;
    void *dlpi_tls_data;
};

int dl_iterate_phdr(int (*callback)(struct zdos_phdr_info *, size_t, void *), void *data) {
    struct zdos_phdr ph[2];
    memset(ph, 0, sizeof(ph));
    ph[0].p_type = 1; /* PT_LOAD */
    ph[0].p_flags = 5;
    ph[0].p_memsz = ph[0].p_filesz = UINTPTR_MAX;
    ph[1].p_type = 0x6474e550; /* PT_GNU_EH_FRAME */
    ph[1].p_flags = 4;
    ph[1].p_vaddr = ph[1].p_paddr = (uintptr_t)__eh_frame_hdr_start;
    ph[1].p_memsz = ph[1].p_filesz = (uintptr_t)(__eh_frame_hdr_end - __eh_frame_hdr_start);
    struct zdos_phdr_info info;
    memset(&info, 0, sizeof(info));
    info.dlpi_name = "";
    info.dlpi_phdr = ph;
    info.dlpi_phnum = ph[1].p_memsz != 0 ? 2 : 1;
    return zdos_call_aligned3((void *)callback, (uintptr_t)&info, sizeof(info), (uintptr_t)data);
}

int dladdr(const void *addr, void *info) {
    (void)addr;
    (void)info;
    return 0; /* no symbol tables */
}

/* The variables as NAME=VALUE, made at start-up (setenv and unsetenv keep
   it up to date through zdos_environ_hook) */
char **environ;
static size_t environ_count, environ_cap;

static bool environ_grow(void) {
    if (environ_count + 1 < environ_cap) return true;
    size_t cap = environ_cap ? environ_cap * 2 : 32;
    char **n = realloc(environ, cap * sizeof(char *));
    if (n == NULL) return false;
    environ = n;
    environ_cap = cap;
    return true;
}

__attribute__((constructor)) static void environ_init(void) {
    if (zdos == NULL || !environ_grow()) return;
    char buf[1024];
    for (uint32_t i = 0;; i++) {
        int64_t n = zdos->programs->var_at(i, buf, sizeof(buf));
        if (n < 0) break;
        char *s = malloc((size_t)n + 1);
        if (s == NULL || !environ_grow()) break;
        if ((size_t)n < sizeof(buf)) {
            memcpy(s, buf, (size_t)n);
        } else {
            zdos->programs->var_at(i, s, (size_t)n);
        }
        s[n] = '\0';
        environ[environ_count++] = s;
    }
    environ[environ_count] = NULL;
    zdos_environ_hook = zdos_environ_set;
}

static size_t environ_find(const char *name, size_t len) {
    for (size_t i = 0; i < environ_count; i++) {
        if (strncasecmp(environ[i], name, len) == 0 && environ[i][len] == '=') return i;
    }
    return SIZE_MAX;
}

void zdos_environ_set(const char *name, const char *value) {
    size_t len = strlen(name), vlen = value != NULL ? strlen(value) : 0;
    size_t i = environ_find(name, len);
    if (value == NULL || vlen == 0) { /* ZDOS has no empty variables */
        if (i != SIZE_MAX) {
            free(environ[i]);
            environ[i] = environ[--environ_count];
            environ[environ_count] = NULL;
        }
        return;
    }
    char *s = malloc(len + vlen + 2);
    if (s == NULL) return;
    memcpy(s, name, len);
    s[len] = '=';
    memcpy(s + len + 1, value, vlen + 1);
    if (i != SIZE_MAX) {
        free(environ[i]);
        environ[i] = s;
    } else if (environ_grow()) {
        environ[environ_count++] = s;
        environ[environ_count] = NULL;
    } else {
        free(s);
    }
}

/* SIGNALS AND THREADS */

/* Kept per thread; ZDOS runs handlers on the thread's own stack */
static _Thread_local struct zdos_stack alt_stack = {NULL, 2 /* SS_DISABLE */, 0};

int sigaltstack(const struct zdos_stack *ss, struct zdos_stack *old) {
    if (old != NULL) *old = alt_stack;
    if (ss != NULL) {
        if ((ss->ss_flags & ~2) != 0) return fail(EINVAL);
        alt_stack = *ss;
    }
    return 0;
}

/* Where a thread's stack is isn't known to the C library */
int pthread_getattr_np(pthread_t thread, pthread_attr_t *attr) {
    (void)thread;
    (void)attr;
    return ENOSYS;
}

int pthread_attr_getstack(const pthread_attr_t *attr, void **addr, size_t *size) {
    *addr = NULL;
    *size = attr->stack_size;
    return 0;
}

int pthread_attr_getguardsize(const pthread_attr_t *attr, size_t *size) {
    (void)attr;
    *size = 0;
    return 0;
}

int pthread_attr_setguardsize(pthread_attr_t *attr, size_t size) {
    (void)attr;
    (void)size;
    return 0;
}

int pthread_setname_np(pthread_t thread, const char *name) {
    (void)thread;
    (void)name;
    return 0;
}

int pthread_getname_np(pthread_t thread, char *name, size_t len) {
    (void)thread;
    if (len > 0) name[0] = '\0';
    return 0;
}

/* SMALL ONES */

/* Code built with a stack protector (Rust's i686 libunwind): the guard is
   read from the thread's block (%gs:0x14), which stays the same per thread */
__attribute__((noreturn)) void __stack_chk_fail(void) {
    fputs("stack smashing detected\n", stderr);
    abort();
}

__attribute__((visibility("hidden"), noreturn)) void __stack_chk_fail_local(void) {
    __stack_chk_fail();
}

int bcmp(const void *a, const void *b, size_t n) {
    return memcmp(a, b, n);
}

int __xpg_strerror_r(int errnum, char *buf, size_t size) {
    return strerror_r(errnum, buf, size);
}

int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t size, struct passwd **result) {
    *result = NULL;
    struct passwd *p = getpwuid(uid);
    if (p == NULL) return errno == ENOENT || errno == 0 ? 0 : errno;
    const char *s[5] = {p->pw_name, p->pw_passwd, p->pw_gecos, p->pw_dir, p->pw_shell};
    char **d[5] = {&pw->pw_name, &pw->pw_passwd, &pw->pw_gecos, &pw->pw_dir, &pw->pw_shell};
    size_t used = 0;
    for (int i = 0; i < 5; i++) {
        const char *v = s[i] != NULL ? s[i] : "";
        size_t n = strlen(v) + 1;
        if (used + n > size) return ERANGE;
        memcpy(buf + used, v, n);
        *d[i] = buf + used;
        used += n;
    }
    pw->pw_uid = p->pw_uid;
    pw->pw_gid = p->pw_gid;
    *result = pw;
    return 0;
}

/* No sessions or process groups: each process is its own */
pid_t setsid(void) {
    return getpid();
}

int setpgid(pid_t pid, pid_t pgid) {
    (void)pid;
    (void)pgid;
    return 0;
}

int killpg(pid_t pgrp, int sig) {
    return kill(pgrp, sig);
}

int chroot(const char *path) {
    (void)path;
    return fail(EPERM);
}

int fchown(int fd, uid_t owner, gid_t group) {
    const char *path = zdos_dirfd_path(fd);
    return path != NULL ? chown(path, owner, group) : fail(EOPNOTSUPP);
}

int lchown(const char *path, uid_t owner, gid_t group) {
    return chown(path, owner, group);
}

int mkfifo(const char *path, mode_t mode) {
    (void)path;
    (void)mode;
    return fail(EPERM);
}

int fdatasync(int fd) {
    return fsync(fd);
}

/* Linux's fast copies aren't there: callers fall back to read and write */
ssize_t sendfile(int out, int in, off_t *offset, size_t count) {
    (void)out, (void)in, (void)offset, (void)count;
    return fail(ENOSYS);
}

ssize_t splice(int in, off_t *in_off, int out, off_t *out_off, size_t len, unsigned flags) {
    (void)in, (void)in_off, (void)out, (void)out_off, (void)len, (void)flags;
    return fail(ENOSYS);
}

int pipe2(int fds[2], int flags) {
    if (flags & ~(O_NONBLOCK | O_CLOEXEC)) return fail(EINVAL);
    if (pipe(fds) != 0) return -1;
    if (flags & O_NONBLOCK) {
        fcntl(fds[0], F_SETFL, O_NONBLOCK);
        fcntl(fds[1], F_SETFL, O_NONBLOCK);
    }
    return 0;
}

/* EPOLL AND EVENTFD: ZDOS'S EVENT QUEUES AND COUNTERS */

int32_t zdos_fd_poll_handle(int fd); /* zdos_fs.c */

static uint32_t last_code(void) {
    return zdos->programs->last_error();
}

// The errno of a failed queue call: EPERM for what can't be watched, as Linux
static int queue_fail(void) {
    uint32_t code = last_code();
    if (code == ZDOS_ERROR_NOT_SUPPORTED) return fail(EPERM);
    if (code == ZDOS_ERROR_INVALID_HANDLE) return fail(EBADF);
    return fail(zdos_errno_from_last_error());
}

int epoll_create1(int flags) {
    if (flags & ~EPOLL_CLOEXEC) return fail(EINVAL);
    int32_t h = zdos->files->queue_create(0);
    if (h <= 0 && last_code() == ZDOS_ERROR_NOT_SUPPORTED) return fail(ENOSYS); /* an older ZDOS */
    if (h < 0) return fail(zdos_errno_from_last_error());
    return zdos_fd_for_handle(h);
}

int epoll_create(int size) {
    return size <= 0 ? fail(EINVAL) : epoll_create1(0);
}

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event) {
    int32_t q = zdos_fd_poll_handle(epfd);
    int32_t h = zdos_fd_poll_handle(fd);
    if (q < 0 || h == -100) return fail(EBADF);
    if (h < 0) return fail(EPERM); /* the screen, memory streams, the keyboard */
    if (q == h) return fail(EINVAL);
    zdos_queue_change c = {h, 0, 0, 0, 0};
    switch (op) {
        case EPOLL_CTL_ADD: c.op = ZDOS_QUEUE_ADD; break;
        case EPOLL_CTL_MOD: c.op = ZDOS_QUEUE_MODIFY; break;
        case EPOLL_CTL_DEL: c.op = ZDOS_QUEUE_DELETE; break;
        default: return fail(EINVAL);
    }
    if (op != EPOLL_CTL_DEL) {
        if (event == NULL) return fail(EFAULT);
        uint32_t e = event->events;
        if (e & EPOLLRDNORM) e |= EPOLLIN;
        if (e & EPOLLWRNORM) e |= EPOLLOUT;
        c.events = e & (EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP | EPOLLONESHOT | EPOLLET);
        c.data = event->data.u64;
    }
    return zdos->files->queue_events(q, &c, 1, NULL, 0, 0) == 0 ? 0 : queue_fail();
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    if (maxevents <= 0) return fail(EINVAL);
    int32_t q = zdos_fd_poll_handle(epfd);
    if (q < 0) return fail(EBADF);
    zdos_queue_event got[64];
    int n = 0;
    while (n < maxevents) {
        uint32_t want = (uint32_t)(maxevents - n) < 64 ? (uint32_t)(maxevents - n) : 64;
        int32_t r = zdos->files->queue_events(q, NULL, 0, got, want, n > 0 ? 0 : timeout);
        if (r < 0) return n > 0 ? n : queue_fail();
        for (int32_t i = 0; i < r; i++) {
            events[n].events = got[i].events;
            events[n].data.u64 = got[i].data;
            n++;
        }
        if ((uint32_t)r < want) break;
    }
    return n;
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents, int timeout, const sigset_t *mask) {
    sigset_t old;
    if (mask != NULL) pthread_sigmask(SIG_SETMASK, mask, &old);
    int r = epoll_wait(epfd, events, maxevents, timeout);
    int e = errno;
    if (mask != NULL) pthread_sigmask(SIG_SETMASK, &old, NULL);
    errno = e;
    return r;
}

int eventfd(unsigned int initval, int flags) {
    if (flags & ~(EFD_SEMAPHORE | EFD_CLOEXEC | EFD_NONBLOCK)) return fail(EINVAL);
    uint32_t f = (flags & EFD_SEMAPHORE ? ZDOS_COUNTER_SEMAPHORE : 0) | (flags & EFD_NONBLOCK ? ZDOS_COUNTER_NONBLOCKING : 0);
    int32_t h = zdos->threads->counter_create(initval, f);
    if (h <= 0 && last_code() == ZDOS_ERROR_NOT_SUPPORTED) return fail(ENOSYS);
    if (h < 0) return fail(zdos_errno_from_last_error());
    return zdos_fd_for_handle(h);
}

int eventfd_read(int fd, eventfd_t *value) {
    return read(fd, value, sizeof(*value)) == sizeof(*value) ? 0 : -1;
}

int eventfd_write(int fd, eventfd_t value) {
    return write(fd, &value, sizeof(value)) == sizeof(value) ? 0 : -1;
}

int clock_nanosleep(clockid_t clock, int flags, const struct timespec *req, struct timespec *rem) {
    if (clock != CLOCK_MONOTONIC && clock != CLOCK_REALTIME) return EINVAL;
    if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000L) return EINVAL;
    if ((flags & 1) && clock == CLOCK_MONOTONIC && zdos != NULL && zdos->time->nap_until != NULL) {
        /* CLOCK_MONOTONIC is time->nanos: its deadline as it is */
        uint64_t at = (uint64_t)req->tv_sec * 1000000000ULL + (uint64_t)req->tv_nsec;
        return zdos->time->nap_until(at) == 0 ? 0 : EINTR;
    }
    struct timespec d = *req;
    if (flags & 1) { /* TIMER_ABSTIME */
        struct timespec now;
        clock_gettime(clock, &now);
        d.tv_sec = req->tv_sec - now.tv_sec;
        d.tv_nsec = req->tv_nsec - now.tv_nsec;
        if (d.tv_nsec < 0) {
            d.tv_nsec += 1000000000L;
            d.tv_sec--;
        }
        if (d.tv_sec < 0) return 0;
        rem = NULL;
    }
    return nanosleep(&d, rem) == 0 ? 0 : errno;
}

/* DIRECTORY DESCRIPTORS AND THE *at() FUNCTIONS
   A directory's descriptor holds a descriptor number (of NUL) and its path */

#define DIRFDS 32
static struct {
    int fd;
    char *path;
} dirfds[DIRFDS];

static void dirfd_closed(int fd) {
    zdos_dirfd_forget(fd);
}

int zdos_dirfd_new(const char *path) {
    zdos_close_hook = dirfd_closed;
    char *full = realpath(path[0] != '\0' ? path : ".", NULL);
    if (full == NULL) return -1;
    int fd = open("/dev/null", O_RDONLY);
    if (fd < 0) {
        free(full);
        return -1;
    }
    zdos_init_lock_take();
    for (int i = 0; i < DIRFDS; i++) {
        if (dirfds[i].path == NULL) {
            dirfds[i].fd = fd;
            dirfds[i].path = full;
            zdos_init_lock_give();
            return fd;
        }
    }
    zdos_init_lock_give();
    close(fd);
    free(full);
    return fail(EMFILE);
}

const char *zdos_dirfd_path(int fd) {
    for (int i = 0; i < DIRFDS; i++) {
        if (dirfds[i].path != NULL && dirfds[i].fd == fd) return dirfds[i].path;
    }
    return NULL;
}

/* Forgets fd if it is a directory's; true if it was */
bool zdos_dirfd_forget(int fd) {
    zdos_init_lock_take();
    for (int i = 0; i < DIRFDS; i++) {
        if (dirfds[i].path != NULL && dirfds[i].fd == fd) {
            free(dirfds[i].path);
            dirfds[i].path = NULL;
            zdos_init_lock_give();
            return true;
        }
    }
    zdos_init_lock_give();
    return false;
}

static bool absolute(const char *p) {
    return p[0] == '/' || p[0] == '\\' || (p[0] != '\0' && p[1] == ':');
}

/* path relative to dirfd, in buf; NULL with errno for a bad dirfd */
const char *zdos_at_path(int dirfd, const char *path, char *buf, size_t size) {
    if (dirfd == ZDOS_AT_FDCWD || absolute(path)) return path;
    const char *dir = zdos_dirfd_path(dirfd);
    if (dir == NULL) {
        struct stat st;
        errno = fstat(dirfd, &st) == 0 ? ENOTDIR : EBADF;
        return NULL;
    }
    size_t a = strlen(dir), b = strlen(path);
    if (a + b + 2 > size) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    memcpy(buf, dir, a);
    if (a > 0 && dir[a - 1] != '\\' && dir[a - 1] != '/') buf[a++] = '/';
    memcpy(buf + a, path, b + 1);
    return buf;
}

#define AT_PATH(dirfd, path)                                        \
    char at_buf_[PATH_MAX];                                         \
    const char *p_ = zdos_at_path(dirfd, path, at_buf_, PATH_MAX); \
    if (p_ == NULL) return -1

/* flags: ZDOS's O_*, with ZDOS_O_DIRECTORY; a directory gets a directory
   descriptor (opened for reading) */
int zdos_open_at(int dirfd, const char *path, int flags, mode_t mode) {
    AT_PATH(dirfd, path);
    if (!(flags & ZDOS_O_DIRECTORY)) {
        int fd = open(p_, flags & ~ZDOS_O_NOFOLLOW, mode);
        if (fd >= 0 || errno != EISDIR) return fd;
    } else {
        struct stat st;
        if (stat(p_, &st) != 0) return -1;
        if (!S_ISDIR(st.st_mode)) return fail(ENOTDIR);
    }
    if ((flags & O_ACCMODE) != O_RDONLY) return fail(EISDIR);
    return zdos_dirfd_new(p_);
}

int openat(int dirfd, const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    mode_t mode = (flags & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
    va_end(ap);
    return zdos_open_at(dirfd, path, flags, mode);
}

int unlinkat(int dirfd, const char *path, int flags) {
    AT_PATH(dirfd, path);
    return (flags & ZDOS_AT_REMOVEDIR) ? rmdir(p_) : unlink(p_);
}

int renameat(int olddirfd, const char *old, int newdirfd, const char *new_) {
    char buf[PATH_MAX];
    const char *o = zdos_at_path(olddirfd, old, buf, sizeof(buf));
    if (o == NULL) return -1;
    AT_PATH(newdirfd, new_);
    return rename(o, p_);
}

int linkat(int olddirfd, const char *old, int newdirfd, const char *new_, int flags) {
    (void)olddirfd, (void)old, (void)newdirfd, (void)new_, (void)flags;
    return fail(EPERM); /* no links */
}

int mkdirat(int dirfd, const char *path, mode_t mode) {
    AT_PATH(dirfd, path);
    return mkdir(p_, mode);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
    (void)flags;
    AT_PATH(dirfd, path);
    return chmod(p_, mode);
}

int faccessat(int dirfd, const char *path, int mode, int flags) {
    (void)flags;
    AT_PATH(dirfd, path);
    return access(p_, mode);
}

int fstatat(int dirfd, const char *path, struct stat *st, int flags) {
    if ((flags & ZDOS_AT_EMPTY_PATH) && path[0] == '\0') return fstat(dirfd, st);
    AT_PATH(dirfd, path);
    return stat(p_, st);
}

ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t size) {
    AT_PATH(dirfd, path);
    return readlink(p_, buf, size);
}

/* Only the modification time is kept (to FAT's 2 seconds) */
int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags) {
    (void)flags;
    AT_PATH(dirfd, path);
    if (times == NULL || times[1].tv_nsec == ZDOS_UTIME_NOW) return utimes(p_, NULL);
    if (times[1].tv_nsec == ZDOS_UTIME_OMIT) return 0;
    struct timeval tv[2] = {{times[1].tv_sec, times[1].tv_nsec / 1000}, {times[1].tv_sec, times[1].tv_nsec / 1000}};
    return utimes(p_, tv);
}

int futimens(int fd, const struct timespec times[2]) {
    const char *path = zdos_dirfd_path(fd);
    if (path != NULL) return utimensat(ZDOS_AT_FDCWD, path, times, 0);
    if (times == NULL || times[1].tv_nsec == ZDOS_UTIME_NOW) return zdos_fd_set_modified(fd, time(NULL));
    if (times[1].tv_nsec == ZDOS_UTIME_OMIT) return 0;
    return zdos_fd_set_modified(fd, times[1].tv_sec);
}

static struct {
    DIR *dir;
    int fd;
    bool own; /* made by dirfd: closed with the directory */
} fddirs[DIRFDS];

/* closedir: the stream's descriptor forgotten, dirfd's own closed (one
   fdopendir got stays open) */
static void dir_closed(DIR *d) {
    int fd = -1;
    zdos_init_lock_take();
    for (int i = 0; i < DIRFDS; i++) {
        if (fddirs[i].dir == d) {
            if (fddirs[i].own) fd = fddirs[i].fd;
            fddirs[i].dir = NULL;
            break;
        }
    }
    zdos_init_lock_give();
    if (fd >= 0) close(fd);
}

static bool remember_dir(DIR *d, int fd, bool own) {
    zdos_closedir_hook = dir_closed;
    zdos_init_lock_take();
    for (int i = 0; i < DIRFDS; i++) {
        if (fddirs[i].dir == NULL) {
            fddirs[i].dir = d;
            fddirs[i].fd = fd;
            fddirs[i].own = own;
            zdos_init_lock_give();
            return true;
        }
    }
    zdos_init_lock_give();
    return false;
}

DIR *fdopendir(int fd) {
    const char *path = zdos_dirfd_path(fd);
    if (path == NULL) {
        errno = ENOTDIR;
        return NULL;
    }
    DIR *d = opendir(path);
    if (d == NULL) return NULL;
    remember_dir(d, fd, false);
    return d;
}

/* The descriptor fdopendir got, else one of the directory's own, made now */
int dirfd(DIR *d) {
    zdos_init_lock_take();
    for (int i = 0; i < DIRFDS; i++) {
        if (fddirs[i].dir == d) {
            int fd = fddirs[i].fd;
            zdos_init_lock_give();
            return fd;
        }
    }
    zdos_init_lock_give();
    int fd = zdos_dirfd_new(zdos_dir_path(d));
    if (fd < 0) return -1;
    if (!remember_dir(d, fd, true)) {
        close(fd);
        return fail(EMFILE);
    }
    return fd;
}

/* A callback for C (the audio thread's fill ...) that calls pair[0](pair[1],
   a, b) on an aligned stack: how Rust code (the zdos crate) is called back */
void zdos_aligned_callback(void *pair, uintptr_t a, uintptr_t b) {
    void **p = pair;
    zdos_call_aligned3(p[0], (uintptr_t)p[1], a, b);
}

/* i686: ZDOS's C code keeps the stack 4-byte aligned, code built for
   Linux (Rust's std) expects 16 at each call: f(a, b, c) called so */
#if defined(__i386__)
__asm__(".text\n"
        ".globl zdos_call_aligned3\n"
        ".type zdos_call_aligned3,@function\n"
        "zdos_call_aligned3:\n"
        "  push %ebp\n"
        "  mov %esp, %ebp\n"
        "  and $-16, %esp\n"
        "  sub $16, %esp\n"
        "  mov 12(%ebp), %eax\n"
        "  mov %eax, 0(%esp)\n"
        "  mov 16(%ebp), %eax\n"
        "  mov %eax, 4(%esp)\n"
        "  mov 20(%ebp), %eax\n"
        "  mov %eax, 8(%esp)\n"
        "  call *8(%ebp)\n"
        "  leave\n"
        "  ret\n");
#else
uintptr_t zdos_call_aligned3(void *f, uintptr_t a, uintptr_t b, uintptr_t c) {
    return ((uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t))f)(a, b, c);
}
#endif
