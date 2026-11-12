#pragma once
#ifndef _ZDOS_UNISTD_H_
#define _ZDOS_UNISTD_H_

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
#include <setjmp.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 0: standard input (the redirected input, else the keyboard, a line at a time;
   Ctrl+Z at the start of a line is the end), 1: the output, 2: the error output
   (the screen unless redirected, also while 1 is) */
#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4

int close(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
/* At an offset; the file position stays (zdos_unix.c) */
ssize_t pread(int fd, void *buf, size_t count, off_t offset);
ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset);
off_t lseek(int fd, off_t offset, int whence);
int isatty(int fd);
/* "/dev/tty" for the console (the screen and keyboard); ENOTTY for others */
char *ttyname(int fd);
int ttyname_r(int fd, char *buf, size_t len);
int ftruncate(int fd, off_t length);
int getentropy(void *buf, size_t len); /* sys/random.h */
/* stdin, stdout and stderr need nothing; fflush first for a FILE. */
int fsync(int fd);
int truncate(const char *path, off_t length);

char *getcwd(char *buf, size_t size); /* "C:\DOCS" */
int chdir(const char *path); /* "E:" or "E:\DIR" also changes the current drive */
int rmdir(const char *path); /* an empty directory */
int unlink(const char *path);
int access(const char *path, int mode); /* W_OK fails for read-only files */

/* A signal (metal) ends them early: sleep returns the seconds left, usleep
   -1 with EINTR */
unsigned int sleep(unsigned int seconds);
int usleep(useconds_t usec); /* to the timer's precision, as nanosleep */

/* ---- Processes (zdos_posix.c) ----
   A process is a ZDOS task. Outside the metal editions starting one fails
   with ENOSYS, except exec, which runs the program and waits for it. */
pid_t getpid(void);
pid_t getppid(void);
/* SIGALRM in that many seconds (0: none); the seconds
   the previous one had left */
unsigned int alarm(unsigned int seconds);
int pause(void); /* until a signal is handled: always -1, EINTR */
/* exec runs the program in place of this one: as a nested program, after which
   this one ends with its exit code (descriptors and memory are not handed over;
   the environment is). -1 if it couldn't start. */
int execv(const char *path, char *const argv[]);
int execve(const char *path, char *const argv[], char *const envp[]);
int execvp(const char *file, char *const argv[]);
int execl(const char *path, const char *arg, ...);
int execlp(const char *file, const char *arg, ...);
int execle(const char *path, const char *arg, ...);
/* No fork: one address space. vfork's child part runs on the parent's stack
   until exec or _exit; it may only dup2 / close descriptors and must not
   return from the function that called vfork. */
#define vfork() zdos_vfork_return(setjmp(*zdos_vfork_jmp()))
pid_t zdos_vfork_return(int jumped);
jmp_buf *zdos_vfork_jmp(void);
/* fork is vfork here: enough for fork + dup2 / close + exec or _exit, not
   for a child that keeps running. Calling fork through a pointer: ENOSYS. */
#define fork() vfork()
pid_t(fork)(void);
pid_t(vfork)(void); /* through a pointer: ENOSYS too */

int pipe(int fds[2]);
int dup(int fd);
int dup2(int fd, int new_fd);
long sysconf(int name);
#define _SC_CLK_TCK 2
#define _SC_OPEN_MAX 4
int getpagesize(void);
#define _SC_PAGESIZE 30
#define _SC_PAGE_SIZE _SC_PAGESIZE
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84
#define _SC_PHYS_PAGES 85
#define _SC_AVPHYS_PAGES 86
/* Limits of a file or folder: the same for all (limits.h) */
long pathconf(const char *path, int name);
long fpathconf(int fd, int name);
#define _PC_LINK_MAX 0
#define _PC_MAX_CANON 1
#define _PC_MAX_INPUT 2
#define _PC_NAME_MAX 3
#define _PC_PATH_MAX 4
#define _PC_PIPE_BUF 5

/* The user the program runs as (ZDOS's users: \CONF\USERS.CFG, see pwd.h):
   real, effective and saved, as on Unix; root (0) may change them, others
   only switch among the three. The host name is HOSTNAME, default "zdos". */
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);
int getgroups(int size, gid_t list[]);
int setgroups(size_t size, const gid_t *list);
int setuid(uid_t uid);
int seteuid(uid_t uid);
int setreuid(uid_t real, uid_t effective);
int setresuid(uid_t real, uid_t effective, uid_t saved);
int getresuid(uid_t *real, uid_t *effective, uid_t *saved);
int setgid(gid_t gid);
int setegid(gid_t gid);
char *getlogin(void);
/* ext2 keeps owners: (uid_t)-1 / (gid_t)-1 leave one as it is; FAT has none */
int chown(const char *path, uid_t owner, gid_t group);
int gethostname(char *name, size_t len);

/* FAT has no links: readlink finds none (EINVAL; ENOENT if the path isn't
   there), symlink and link fail with EPERM */
ssize_t readlink(const char *path, char *buf, size_t size);
int symlink(const char *target, const char *path);
int link(const char *existing, const char *path);

/* The variables as NAME=value strings, NULL-terminated; setenv, putenv and
   unsetenv keep it up to date */
extern char **environ;

/* Linux's numbers for what sys/syscall.h names (futex, getrandom,
   gettid, getpid, sched_yield); any other fails with ENOSYS */
long syscall(long number, ...);
pid_t gettid(void); /* the task's id */
/* No sessions or process groups: each process is its own (setsid gives its
   id, setpgid does nothing) */
pid_t setsid(void);
int setpgid(pid_t pid, pid_t pgid);
int chroot(const char *path); /* EPERM */
int fchown(int fd, uid_t owner, gid_t group); /* a directory descriptor's only */
int lchown(const char *path, uid_t owner, gid_t group);
int fdatasync(int fd);
int pipe2(int fds[2], int flags); /* O_NONBLOCK, O_CLOEXEC */
int getdtablesize(void); /* sysconf(_SC_OPEN_MAX) */

/* The *at functions: path relative to a directory descriptor (openat with
   O_DIRECTORY, or dirfd) or AT_FDCWD; flags other than AT_REMOVEDIR and
   AT_EMPTY_PATH are ignored */
int faccessat(int dirfd, const char *path, int mode, int flags);
int unlinkat(int dirfd, const char *path, int flags);
ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t size);
int linkat(int olddirfd, const char *old, int newdirfd, const char *new_, int flags); /* EPERM */

/* getopt and its variables (getopt.h has getopt_long too) */
extern char *optarg;
extern int optind, opterr, optopt;
int getopt(int argc, char *const argv[], const char *optstring);
void _exit(int status) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif
