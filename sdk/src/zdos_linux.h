#ifndef ZDOS_LINUX_H
#define ZDOS_LINUX_H

/* Between zdos_linux.c and zdos_musl.c; not for programs. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

/* Linux's values (x86's, where the CPUs differ) for what ZDOS's headers lack */
#define ZDOS_O_DIRECTORY 0200000
#define ZDOS_O_NOFOLLOW 0400000
#define ZDOS_AT_FDCWD (-100)
#define ZDOS_AT_REMOVEDIR 0x200
#define ZDOS_AT_EMPTY_PATH 0x1000
#define ZDOS_UTIME_NOW 0x3fffffff
#define ZDOS_UTIME_OMIT 0x3ffffffe

/* Linux's stack_t, the same on every CPU */
struct zdos_stack {
    void *ss_sp;
    int ss_flags;
    size_t ss_size;
};

/* Directory descriptors: a new one for an existing directory (-1 with
   errno), its full path (NULL: not a directory's), forgetting it on close */
int zdos_dirfd_new(const char *path);
const char *zdos_dirfd_path(int fd);
bool zdos_dirfd_forget(int fd);
/* path relative to dirfd (AT_FDCWD: the current directory), in buf */
const char *zdos_at_path(int dirfd, const char *path, char *buf, size_t size);
int zdos_open_at(int dirfd, const char *path, int flags, mode_t mode);

/* Declared here, as ZDOS's headers lack them */
int fstatat(int dirfd, const char *path, struct stat *st, int flags);
int clock_nanosleep(clockid_t clock, int flags, const struct timespec *req, struct timespec *rem);

/* The variables of environ after setenv / unsetenv (value NULL) */
void zdos_environ_set(const char *name, const char *value);

/* f(a, b, c) on a 16-byte aligned stack (i686; a plain call elsewhere) */
uintptr_t zdos_call_aligned3(void *f, uintptr_t a, uintptr_t b, uintptr_t c);

/* The futex call: -errno on failure */
long zdos_futex(uint32_t *addr, int op, uint32_t val, int64_t sec, long nsec, bool has_time, uint32_t *addr2,
                uint32_t val3);

#endif
