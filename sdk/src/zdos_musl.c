/* musl's ABI (as Rust's libc crate has it for x86_64, aarch64 and i686
 * musl) over the C library, for Rust's std: __zdos_musl_NAME is NAME with
 * musl's structures, flags and time types. zdos-cargo renames NAME to it in
 * Rust's objects; C code keeps ZDOS's ABI. */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <utime.h>
#include "zdos.h"
#include "zdos_internal.h"
#include "zdos_linux.h"

static int fail(int e) {
    errno = e;
    return -1;
}

#if defined(__i386__)
typedef int32_t mtime_t; /* the libc crate's i686 musl: 32-bit time_t */
#else
typedef int64_t mtime_t;
#endif
struct mtimespec {
    mtime_t tv_sec;
    long tv_nsec;
};
struct mtimeval {
    mtime_t tv_sec;
    long tv_usec;
};

static mtime_t to_mtime(time_t t) {
#if defined(__i386__)
    return t > INT32_MAX ? INT32_MAX : t < INT32_MIN ? INT32_MIN : (mtime_t)t;
#else
    return t;
#endif
}

/* STRUCT STAT */

struct mstat {
#if defined(__x86_64__)
    uint64_t st_dev, st_ino, st_nlink;
    uint32_t st_mode, st_uid, st_gid, pad0;
    uint64_t st_rdev;
    int64_t st_size, st_blksize, st_blocks;
    struct mtimespec st_atim, st_mtim, st_ctim;
    int64_t unused[3];
#elif defined(__aarch64__) || defined(__riscv)
    uint64_t st_dev, st_ino;
    uint32_t st_mode, st_nlink, st_uid, st_gid;
    uint64_t st_rdev, pad0;
    int64_t st_size;
    int32_t st_blksize, pad1;
    int64_t st_blocks;
    struct mtimespec st_atim, st_mtim, st_ctim;
    uint32_t unused[2];
#else
    uint64_t st_dev;
    int32_t pad0;
    int32_t st_ino_truncated;
    uint32_t st_mode, st_nlink, st_uid, st_gid;
    uint64_t st_rdev;
    int32_t pad1;
    int64_t st_size;
    int32_t st_blksize;
    int64_t st_blocks;
    struct mtimespec st_atim, st_mtim, st_ctim;
    uint64_t st_ino;
#endif
};
#if defined(__i386__)
_Static_assert(sizeof(struct mstat) == 96, "musl i686 stat");
#elif defined(__x86_64__)
_Static_assert(sizeof(struct mstat) == 144, "musl x86_64 stat");
#else
_Static_assert(sizeof(struct mstat) == 128, "musl aarch64 stat");
#endif

static int to_mstat(int r, const struct stat *z, struct mstat *m) {
    if (r != 0) return r;
    memset(m, 0, sizeof(*m));
    m->st_dev = z->st_dev;
    m->st_ino = z->st_ino;
#if defined(__i386__)
    m->st_ino_truncated = (int32_t)z->st_ino;
#endif
    m->st_nlink = z->st_nlink;
    m->st_mode = z->st_mode;
    m->st_uid = z->st_uid;
    m->st_gid = z->st_gid;
    m->st_rdev = z->st_rdev;
    m->st_size = z->st_size;
    m->st_blksize = z->st_blksize;
    m->st_blocks = z->st_blocks;
    m->st_atim.tv_sec = to_mtime(z->st_atim.tv_sec);
    m->st_atim.tv_nsec = z->st_atim.tv_nsec;
    m->st_mtim.tv_sec = to_mtime(z->st_mtim.tv_sec);
    m->st_mtim.tv_nsec = z->st_mtim.tv_nsec;
    m->st_ctim.tv_sec = to_mtime(z->st_ctim.tv_sec);
    m->st_ctim.tv_nsec = z->st_ctim.tv_nsec;
    return 0;
}

int __zdos_musl_stat(const char *path, struct mstat *m) {
    struct stat z;
    return to_mstat(stat(path, &z), &z, m);
}

int __zdos_musl_lstat(const char *path, struct mstat *m) {
    struct stat z;
    return to_mstat(lstat(path, &z), &z, m);
}

int __zdos_musl_fstat(int fd, struct mstat *m) {
    struct stat z;
    const char *dir = zdos_dirfd_path(fd);
    return to_mstat(dir != NULL ? stat(dir, &z) : fstat(fd, &z), &z, m);
}

int __zdos_musl_fstatat(int dirfd, const char *path, struct mstat *m, int flags) {
    struct stat z;
    return to_mstat(fstatat(dirfd, path, &z, flags), &z, m);
}

/* FILES AND DIRECTORIES */

/* musl's open flags to ZDOS's (aarch64 has its own O_DIRECTORY, O_NOFOLLOW) */
static int zflags(int f) {
#if defined(__aarch64__)
    int dir = 040000, nofollow = 0100000;
#else
    int dir = 0200000, nofollow = 0400000;
#endif
    int z = f & (O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC | O_APPEND | O_NONBLOCK | O_CLOEXEC);
    if (f & dir) z |= ZDOS_O_DIRECTORY;
    if (f & nofollow) z |= ZDOS_O_NOFOLLOW;
    return z;
}

int __zdos_musl_open(const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    mode_t mode = (flags & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
    va_end(ap);
    return zdos_open_at(ZDOS_AT_FDCWD, path, zflags(flags), mode);
}

int __zdos_musl_openat(int dirfd, const char *path, int flags, ...) {
    va_list ap;
    va_start(ap, flags);
    mode_t mode = (flags & O_CREAT) ? (mode_t)va_arg(ap, int) : 0;
    va_end(ap);
    return zdos_open_at(dirfd, path, zflags(flags), mode);
}

int __zdos_musl_close(int fd) {
    zdos_dirfd_forget(fd);
    return close(fd);
}

/* musl's struct dirent, with room for ZDOS's longer names (read to the 0) */
struct mdirent {
    uint64_t d_ino;
    int64_t d_off;
    uint16_t d_reclen;
    uint8_t d_type;
    char d_name[256];
};

struct mdir {
    DIR *dir;
    int fd; /* fdopendir's, closed by closedir; -1: none yet */
    char *path;
    long pos;
    union {
        struct mdirent e;
        char room[sizeof(struct mdirent) + 520];
    } ent;
};

static struct mdir *mdir_new(DIR *d, int fd, const char *path) {
    struct mdir *m = d != NULL ? calloc(1, sizeof(*m)) : NULL;
    if (m == NULL || (m->path = strdup(path)) == NULL) {
        if (d != NULL) closedir(d);
        free(m);
        if (d != NULL) errno = ENOMEM;
        return NULL;
    }
    m->dir = d;
    m->fd = fd;
    return m;
}

struct mdir *__zdos_musl_opendir(const char *path) {
    return mdir_new(opendir(path), -1, path);
}

struct mdir *__zdos_musl_fdopendir(int fd) {
    const char *path = zdos_dirfd_path(fd);
    if (path == NULL) {
        errno = fcntl(fd, F_GETFD) < 0 ? EBADF : ENOTDIR;
        return NULL;
    }
    return mdir_new(opendir(path), fd, path);
}

struct mdirent *__zdos_musl_readdir(struct mdir *m) {
    struct dirent *z = readdir(m->dir);
    if (z == NULL) return NULL;
    struct mdirent *e = &m->ent.e;
    e->d_ino = z->d_ino;
    e->d_off = ++m->pos;
    e->d_type = z->d_type;
    size_t n = strlen(z->d_name);
    if (n >= sizeof(m->ent.room) - offsetof(struct mdirent, d_name)) n = sizeof(m->ent.room) - offsetof(struct mdirent, d_name) - 1;
    memcpy(e->d_name, z->d_name, n);
    e->d_name[n] = '\0';
    e->d_reclen = (uint16_t)((offsetof(struct mdirent, d_name) + n + 8) & ~(size_t)7);
    return e;
}

void __zdos_musl_rewinddir(struct mdir *m) {
    rewinddir(m->dir);
    m->pos = 0;
}

int __zdos_musl_dirfd(struct mdir *m) {
    if (m->fd < 0) m->fd = zdos_dirfd_new(m->path);
    return m->fd;
}

int __zdos_musl_closedir(struct mdir *m) {
    if (m == NULL) return fail(EBADF);
    int r = closedir(m->dir);
    if (m->fd >= 0) __zdos_musl_close(m->fd);
    free(m->path);
    free(m);
    return r;
}

/* ZDOS paths in POSIX form, "C:\DOCS" as "/C:/DOCS", so Rust's Path sees
   them absolute */
static char *posix_form(const char *z, char *buf, size_t size) {
    size_t n = strlen(z);
    bool drive = n >= 2 && z[1] == ':';
    if (n + drive + 1 > size) {
        errno = ERANGE;
        return NULL;
    }
    char *o = buf;
    if (drive) *o++ = '/';
    for (size_t i = 0; i <= n; i++) {
        *o++ = z[i] == '\\' ? '/' : z[i];
    }
    if (drive && n == 3) buf[3] = '/'; /* "C:\" */
    return buf;
}

static char *posix_out(const char *z, char *buf, size_t size) {
    if (buf == NULL) {
        size = strlen(z) + 2;
        buf = malloc(size);
        if (buf == NULL) {
            errno = ENOMEM;
            return NULL;
        }
        return posix_form(z, buf, size);
    }
    return posix_form(z, buf, size);
}

char *__zdos_musl_getcwd(char *buf, size_t size) {
    char z[PATH_MAX];
    if (getcwd(z, sizeof(z)) == NULL) return NULL;
    if (buf == NULL && size != 0 && strlen(z) + 2 > size) {
        errno = ERANGE;
        return NULL;
    }
    return posix_out(z, buf, size);
}

char *__zdos_musl_realpath(const char *path, char *resolved) {
    char z[PATH_MAX];
    if (realpath(path, z) == NULL) return NULL;
    return posix_out(z, resolved, PATH_MAX);
}

/* /proc/self/exe: the program's file (Rust's current_exe) */
ssize_t __zdos_musl_readlink(const char *path, char *buf, size_t size) {
    if (strcmp(path, "/proc/self/exe") != 0) return readlink(path, buf, size);
    char z[PATH_MAX], p[PATH_MAX + 2];
    size_t n = zdos->programs->program_path(z, sizeof(z) - 1);
    z[n] = '\0';
    if (posix_form(z, p, sizeof(p)) == NULL) return -1;
    n = strlen(p);
    if (n > size) n = size;
    memcpy(buf, p, n);
    return (ssize_t)n;
}

/* FIONBIO and FIOCLEX, which Rust uses on Linux, besides ZDOS's own */
int __zdos_musl_ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (request == 0x5421) { /* FIONBIO */
        int fl = fcntl(fd, F_GETFL);
        if (fl < 0) return -1;
        return fcntl(fd, F_SETFL, *(const int *)arg ? fl | O_NONBLOCK : fl & ~O_NONBLOCK);
    }
    if (request == 0x5451 || request == 0x5450) { /* FIOCLEX, FIONCLEX */
        return fcntl(fd, F_GETFD) < 0 ? -1 : 0;
    }
    return ioctl(fd, request, arg);
}

/* SIGNALS
   musl's struct sigaction (a 128-byte sigset_t; the first 8 bytes are
   ZDOS's, as sigemptyset and sigaddset made them) and siginfo_t */

struct msigaction {
    void *handler;
    uint64_t mask[16];
    int flags;
    void (*restorer)(void);
};

struct msiginfo {
    int si_signo, si_errno, si_code;
#if UINTPTR_MAX > 0xffffffffu
    int pad;
#endif
    union {
        void *si_addr;
        struct {
            pid_t si_pid;
            uid_t si_uid;
            int si_status;
        } child;
        char room[128 - 4 * sizeof(int)];
    } u;
};

#define MSA_ONSTACK 0x08000000
#define ZDOS_NSIG_MUSL 65
static void *user_handlers[ZDOS_NSIG_MUSL];
static int user_flags[ZDOS_NSIG_MUSL];

static void tramp(int sig, siginfo_t *zi, void *ctx) {
    void *h = sig > 0 && sig < ZDOS_NSIG_MUSL ? user_handlers[sig] : NULL;
    if (h == NULL) return;
    if (user_flags[sig] & SA_SIGINFO) {
        struct msiginfo mi;
        memset(&mi, 0, sizeof(mi));
        mi.si_signo = sig;
        if (zi != NULL) {
            mi.si_errno = zi->si_errno;
            mi.si_code = zi->si_code;
            if (sig == SIGCHLD) {
                mi.u.child.si_pid = zi->si_pid;
                mi.u.child.si_status = zi->si_status;
            } else {
                mi.u.si_addr = zi->si_addr;
            }
        }
        zdos_call_aligned3(h, (uintptr_t)sig, (uintptr_t)&mi, (uintptr_t)ctx);
    } else {
        zdos_call_aligned3(h, (uintptr_t)sig, 0, 0);
    }
}

int __zdos_musl_sigaction(int sig, const struct msigaction *act, struct msigaction *old) {
    struct sigaction za, zo;
    struct sigaction *ap = NULL;
    if (sig <= 0 || sig >= ZDOS_NSIG_MUSL) return fail(EINVAL);
    if (act != NULL) {
        memset(&za, 0, sizeof(za));
        za.sa_mask = act->mask[0];
        za.sa_flags = act->flags & ~MSA_ONSTACK;
        if (act->handler == (void *)SIG_DFL || act->handler == (void *)SIG_IGN) {
            za.sa_handler = (void (*)(int))act->handler;
        } else {
            za.sa_sigaction = tramp;
            za.sa_flags |= SA_SIGINFO;
        }
        ap = &za;
    }
    void *prev_handler = user_handlers[sig];
    int prev_flags = user_flags[sig];
    if (act != NULL && ap->sa_sigaction == tramp) {
        user_handlers[sig] = act->handler;
        user_flags[sig] = act->flags;
    }
    if (sigaction(sig, ap, &zo) != 0) {
        user_handlers[sig] = prev_handler;
        user_flags[sig] = prev_flags;
        return -1;
    }
    if (old != NULL) {
        memset(old, 0, sizeof(*old));
        old->mask[0] = zo.sa_mask;
        if (zo.sa_sigaction == tramp) {
            old->handler = prev_handler;
            old->flags = prev_flags;
        } else {
            old->handler = (void *)zo.sa_handler;
            old->flags = zo.sa_flags;
        }
    }
    return 0;
}

void *__zdos_musl_signal(int sig, void *handler) {
    struct msigaction a, o;
    memset(&a, 0, sizeof(a));
    a.handler = handler;
    a.flags = SA_RESTART;
    if (__zdos_musl_sigaction(sig, &a, &o) != 0) return (void *)SIG_ERR;
    return o.handler;
}

/* PROCESSES */

/* musl's posix_spawn_file_actions_t is larger than ZDOS's: room for a
   directory to start the program in */
struct mfile_actions {
    posix_spawn_file_actions_t z;
    char *chdir;
};

int __zdos_musl_posix_spawn_file_actions_init(struct mfile_actions *a) {
    a->chdir = NULL;
    return posix_spawn_file_actions_init(&a->z);
}

int __zdos_musl_posix_spawn_file_actions_destroy(struct mfile_actions *a) {
    free(a->chdir);
    a->chdir = NULL;
    return posix_spawn_file_actions_destroy(&a->z);
}

int __zdos_musl_posix_spawn_file_actions_adddup2(struct mfile_actions *a, int fd, int new_fd) {
    return posix_spawn_file_actions_adddup2(&a->z, fd, new_fd);
}

int __zdos_musl_posix_spawn_file_actions_addclose(struct mfile_actions *a, int fd) {
    return posix_spawn_file_actions_addclose(&a->z, fd);
}

int __zdos_musl_posix_spawn_file_actions_addopen(struct mfile_actions *a, int fd, const char *path, int flags,
                                                mode_t mode) {
    return posix_spawn_file_actions_addopen(&a->z, fd, path, zflags(flags) & ~(ZDOS_O_DIRECTORY | ZDOS_O_NOFOLLOW),
                                            mode);
}

int __zdos_musl_posix_spawn_file_actions_addchdir_np(struct mfile_actions *a, const char *path) {
    char *copy = strdup(path);
    if (copy == NULL) return ENOMEM;
    free(a->chdir);
    a->chdir = copy;
    return 0;
}

extern char **environ;

/* On a ZDOS without tasks->spawn_env: the variables NAME=VALUE in env that
   differ from environ, set for the start of a program, then put back */
struct env_change {
    char *name;
    char *old; /* NULL: wasn't set */
};

static size_t name_len(const char *s) {
    const char *e = strchr(s, '=');
    return e != NULL ? (size_t)(e - s) : strlen(s);
}

static bool in_env(char *const *env, const char *entry, bool whole) {
    size_t n = name_len(entry);
    for (; *env != NULL; env++) {
        if (whole ? strcmp(*env, entry) == 0 : (strncasecmp(*env, entry, n) == 0 && (*env)[n] == '=')) return true;
    }
    return false;
}

static int env_apply(char *const *env, struct env_change **out) {
    size_t count = 0, cap = 0;
    struct env_change *ch = NULL;
    *out = NULL;
    char **now = environ != NULL ? environ : (char *[]){NULL};
    for (int pass = 0; pass < 2; pass++) {
        char *const *list = pass == 0 ? now : env;
        for (char *const *e = list; *e != NULL; e++) {
            // pass 0: variables env lacks; pass 1: those env sets otherwise
            if (pass == 0 ? in_env(env, *e, false) : in_env(now, *e, true)) continue;
            if (count == cap) {
                cap = cap ? cap * 2 : 16;
                struct env_change *n = realloc(ch, cap * sizeof(*ch));
                if (n == NULL) break;
                ch = n;
            }
            size_t n = name_len(*e);
            char *name = strndup(*e, n);
            if (name == NULL) break;
            const char *old = getenv(name);
            ch[count].name = name;
            ch[count].old = old != NULL ? strdup(old) : NULL;
            count++;
            if (pass == 0) {
                unsetenv(name);
            } else {
                setenv(name, *e + n + 1, 1);
            }
        }
    }
    *out = ch;
    return (int)count;
}

static void env_restore(struct env_change *ch, int count) {
    for (int i = count - 1; i >= 0; i--) {
        if (ch[i].old != NULL) {
            setenv(ch[i].name, ch[i].old, 1);
        } else {
            unsetenv(ch[i].name);
        }
        free(ch[i].name);
        free(ch[i].old);
    }
    free(ch);
}

static int spawn(pid_t *pid, const char *path, const struct mfile_actions *fa, const posix_spawnattr_t *attr,
                 char *const argv[], char *const envp[], bool search) {
    char cwd[PATH_MAX];
    if (fa != NULL && fa->chdir != NULL) {
        if (getcwd(cwd, sizeof(cwd)) == NULL) return errno;
        if (chdir(fa->chdir) != 0) return errno;
    }
    struct env_change *ch = NULL;
    int changes = envp != NULL && envp != environ && !zdos_spawn_env_works() ? env_apply(envp, &ch) : 0;
    const posix_spawn_file_actions_t *z = fa != NULL ? &fa->z : NULL;
    int r = search ? posix_spawnp(pid, path, z, attr, argv, envp) : posix_spawn(pid, path, z, attr, argv, envp);
    if (changes > 0 || ch != NULL) env_restore(ch, changes);
    if (fa != NULL && fa->chdir != NULL) chdir(cwd);
    return r;
}

int __zdos_musl_posix_spawn(pid_t *pid, const char *path, const struct mfile_actions *fa,
                            const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn(pid, path, fa, attr, argv, envp, false);
}

int __zdos_musl_posix_spawnp(pid_t *pid, const char *file, const struct mfile_actions *fa,
                             const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn(pid, file, fa, attr, argv, envp, true);
}

/* waitid for P_ALL and P_PID with WEXITED (and WNOHANG) */
int __zdos_musl_waitid(int idtype, id_t id, struct msiginfo *info, int options) {
    if ((idtype != 0 && idtype != 1) || !(options & 4 /* WEXITED */)) return fail(EINVAL);
    int status;
    pid_t p = waitpid(idtype == 1 ? (pid_t)id : -1, &status, (options & WNOHANG) ? WNOHANG : 0);
    if (p < 0) return -1;
    memset(info, 0, sizeof(*info));
    if (p == 0) return 0;
    info->si_signo = SIGCHLD;
    info->si_code = WIFEXITED(status) ? 1 /* CLD_EXITED */ : 2 /* CLD_KILLED */;
    info->u.child.si_pid = p;
    info->u.child.si_status = WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status);
    return 0;
}

/* SOCKETS */

#if UINTPTR_MAX > 0xffffffffu
/* musl's 64-bit struct msghdr pads msg_iovlen and msg_controllen */
struct mmsghdr {
    void *msg_name;
    socklen_t msg_namelen;
    struct iovec *msg_iov;
    int msg_iovlen, pad1;
    void *msg_control;
    socklen_t msg_controllen;
    int pad2;
    int msg_flags;
};

static void to_zmsg(const struct mmsghdr *m, struct msghdr *z) {
    z->msg_name = m->msg_name;
    z->msg_namelen = m->msg_namelen;
    z->msg_iov = m->msg_iov;
    z->msg_iovlen = m->msg_iovlen;
    z->msg_control = m->msg_control;
    z->msg_controllen = m->msg_controllen;
    z->msg_flags = m->msg_flags;
}

ssize_t __zdos_musl_sendmsg(int fd, const struct mmsghdr *m, int flags) {
    struct msghdr z;
    to_zmsg(m, &z);
    return sendmsg(fd, &z, flags);
}

ssize_t __zdos_musl_recvmsg(int fd, struct mmsghdr *m, int flags) {
    struct msghdr z;
    to_zmsg(m, &z);
    ssize_t n = recvmsg(fd, &z, flags);
    m->msg_namelen = z.msg_namelen;
    m->msg_controllen = z.msg_controllen;
    m->msg_flags = z.msg_flags;
    return n;
}
#endif

/* VARIABLES */

/* std's threads take RUST_MIN_STACK's size (2 MiB if unset): unset, it
   is ZDOS's thread stack, as other programs get */
char *__zdos_musl_getenv(const char *name) {
    char *v = getenv(name);
    if (v != NULL || name == NULL || strcmp(name, "RUST_MIN_STACK") != 0) return v;
    static char size[24];
    if (size[0] == '\0') {
        size_t def = zdos->threads->default_stack_size();
        snprintf(size, sizeof(size), "%zu", def != 0 ? def : (size_t)256 * 1024);
    }
    return size;
}

/* I686: musl's 32-bit time_t, and Linux's 16-byte stack alignment at
   the calls from C into Rust (main, threads, thread_local destructors) */
#if defined(__i386__)

static void to_ts(const struct mtimespec *m, struct timespec *z) {
    z->tv_sec = m->tv_sec;
    z->tv_nsec = m->tv_nsec;
}

static void from_ts(const struct timespec *z, struct mtimespec *m) {
    m->tv_sec = to_mtime(z->tv_sec);
    m->tv_nsec = z->tv_nsec;
}

int __zdos_musl_clock_gettime(clockid_t clock, struct mtimespec *m) {
    struct timespec z;
    if (clock_gettime(clock, &z) != 0) return -1;
    from_ts(&z, m);
    return 0;
}

int __zdos_musl_clock_getres(clockid_t clock, struct mtimespec *m) {
    struct timespec z;
    if (clock_getres(clock, &z) != 0) return -1;
    if (m != NULL) from_ts(&z, m);
    return 0;
}

int __zdos_musl_nanosleep(const struct mtimespec *req, struct mtimespec *rem) {
    struct timespec zr, zl = {0, 0};
    to_ts(req, &zr);
    int r = nanosleep(&zr, &zl);
    if (rem != NULL) from_ts(&zl, rem);
    return r;
}

int __zdos_musl_clock_nanosleep(clockid_t clock, int flags, const struct mtimespec *req, struct mtimespec *rem) {
    struct timespec zr, zl = {0, 0};
    to_ts(req, &zr);
    int r = clock_nanosleep(clock, flags, &zr, &zl);
    if (rem != NULL && !(flags & 1)) from_ts(&zl, rem);
    return r;
}

int __zdos_musl_gettimeofday(struct mtimeval *m, void *tz) {
    struct timeval z;
    if (gettimeofday(&z, tz) != 0) return -1;
    if (m != NULL) {
        m->tv_sec = to_mtime(z.tv_sec);
        m->tv_usec = z.tv_usec;
    }
    return 0;
}

mtime_t __zdos_musl_time(mtime_t *t) {
    mtime_t now = to_mtime(time(NULL));
    if (t != NULL) *t = now;
    return now;
}

double __zdos_musl_difftime(mtime_t end, mtime_t start) {
    return (double)end - (double)start;
}

struct tm *__zdos_musl_localtime_r(const mtime_t *t, struct tm *out) {
    time_t z = *t;
    return localtime_r(&z, out);
}

struct tm *__zdos_musl_gmtime_r(const mtime_t *t, struct tm *out) {
    time_t z = *t;
    return gmtime_r(&z, out);
}

struct tm *__zdos_musl_localtime(const mtime_t *t) {
    time_t z = *t;
    return localtime(&z);
}

struct tm *__zdos_musl_gmtime(const mtime_t *t) {
    time_t z = *t;
    return gmtime(&z);
}

mtime_t __zdos_musl_mktime(struct tm *tm) {
    return to_mtime(mktime(tm));
}

mtime_t __zdos_musl_timegm(struct tm *tm) {
    return to_mtime(timegm(tm));
}

int __zdos_musl_utimensat(int dirfd, const char *path, const struct mtimespec m[2], int flags) {
    struct timespec z[2];
    if (m != NULL) {
        to_ts(&m[0], &z[0]);
        to_ts(&m[1], &z[1]);
    }
    return utimensat(dirfd, path, m != NULL ? z : NULL, flags);
}

int __zdos_musl_futimens(int fd, const struct mtimespec m[2]) {
    struct timespec z[2];
    if (m != NULL) {
        to_ts(&m[0], &z[0]);
        to_ts(&m[1], &z[1]);
    }
    return futimens(fd, m != NULL ? z : NULL);
}

int __zdos_musl_utime(const char *path, const mtime_t *times) { /* struct utimbuf: actime, modtime */
    struct utimbuf z;
    if (times != NULL) {
        z.actime = times[0];
        z.modtime = times[1];
    }
    return utime(path, times != NULL ? &z : NULL);
}

int __zdos_musl_utimes(const char *path, const struct mtimeval m[2]) {
    struct timeval z[2];
    if (m != NULL) {
        for (int i = 0; i < 2; i++) {
            z[i].tv_sec = m[i].tv_sec;
            z[i].tv_usec = m[i].tv_usec;
        }
    }
    return utimes(path, m != NULL ? z : NULL);
}

static bool is_timeval_option(int level, int name) {
    return level == SOL_SOCKET && (name == SO_RCVTIMEO || name == SO_SNDTIMEO);
}

int __zdos_musl_setsockopt(int fd, int level, int name, const void *value, socklen_t len) {
    if (is_timeval_option(level, name) && len >= sizeof(struct mtimeval)) {
        const struct mtimeval *m = value;
        struct timeval z = {m->tv_sec, m->tv_usec};
        return setsockopt(fd, level, name, &z, sizeof(z));
    }
    return setsockopt(fd, level, name, value, len);
}

int __zdos_musl_getsockopt(int fd, int level, int name, void *value, socklen_t *len) {
    if (is_timeval_option(level, name) && *len >= sizeof(struct mtimeval)) {
        struct timeval z;
        socklen_t zl = sizeof(z);
        if (getsockopt(fd, level, name, &z, &zl) != 0) return -1;
        struct mtimeval *m = value;
        m->tv_sec = to_mtime(z.tv_sec);
        m->tv_usec = z.tv_usec;
        *len = sizeof(*m);
        return 0;
    }
    return getsockopt(fd, level, name, value, len);
}

int __zdos_musl_pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct mtimespec *at) {
    struct timespec z;
    to_ts(at, &z);
    return pthread_cond_timedwait(c, m, &z);
}

int __zdos_musl_sem_timedwait(sem_t *s, const struct mtimespec *at) {
    struct timespec z;
    to_ts(at, &z);
    return sem_timedwait(s, &z);
}

struct start {
    void *(*fn)(void *);
    void *arg;
};

static void *thread_tramp(void *p) {
    struct start s = *(struct start *)p;
    free(p);
    return (void *)zdos_call_aligned3((void *)s.fn, (uintptr_t)s.arg, 0, 0);
}

int __zdos_musl_pthread_create(pthread_t *t, const pthread_attr_t *attr, void *(*fn)(void *), void *arg) {
    struct start *s = malloc(sizeof(*s));
    if (s == NULL) return EAGAIN;
    s->fn = fn;
    s->arg = arg;
    int r = pthread_create(t, attr, thread_tramp, s);
    if (r != 0) free(s);
    return r;
}

int __cxa_thread_atexit_impl(void (*fn)(void *), void *obj, void *dso);

static void dtor_tramp(void *p) {
    struct start s = *(struct start *)p;
    free(p);
    zdos_call_aligned3((void *)s.fn, (uintptr_t)s.arg, 0, 0);
}

int __zdos_musl___cxa_thread_atexit_impl(void (*fn)(void *), void *obj, void *dso) {
    struct start *s = malloc(sizeof(*s));
    if (s == NULL) return -1;
    s->fn = (void *(*)(void *))(void *)fn;
    s->arg = obj;
    int r = __cxa_thread_atexit_impl(dtor_tramp, s, dso);
    if (r != 0) free(s);
    return r;
}

/* Rust's main, renamed by zdos-cargo, which links main as this (a main
   in the library would clash with C programs') */
extern int __zdos_rust_main(int argc, char **argv);

int zdos_musl_main(int argc, char **argv) {
    return (int)zdos_call_aligned3((void *)__zdos_rust_main, (uintptr_t)argc, (uintptr_t)argv, 0);
}

#endif
