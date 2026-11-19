#ifndef ZDOS_INTERNAL_H
#define ZDOS_INTERNAL_H

/* Shared between the SDK's own source files; not for programs. */
#include <dirent.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <sys/types.h>
#include <time.h>
#include "zdos.h"

/* Seconds since 1970-01-01 for a ZDOS date and time, which is local time
   (with TZ set, the UTC seconds of it) */
int64_t zdos_epoch_from_time(const zdos_time *t);

/* Ctrl+C typed while stdin reads the keyboard (SIGINT handled or ignored) */
void zdos_ctrl_c_typed(void);

/* Writes what the FILE streams still hold (exit does it) */
void zdos_flush_streams(void);

/* Set by zdos_crt0.c: runs the program's destructors when exit() ends it */
extern void (*zdos_crt0_fini)(void);
/* Set by zdos_cxa_thread.c: runs the calling thread's thread_local
   destructors (exit, a thread's end) */
extern void (*zdos_thread_dtors_hook)(void);

/* FOR zdos_posix.c (processes, THREADS, SIGNALS, terminals) */

#define ZDOS_MAX_FILES 128

/* Set once a thread exists: errno is then each thread's own, the first int
   of what threads->local() points to (NULL: the program's own errno) */
extern bool zdos_threads_started;

/* A program's C runtime for the C libraries (.ZDL) it loads, which have a C
   library of their own: their threads and pthread keys are then the program's
   (its thread_local data, one key numbering), and so are errno and the
   signal handlers (ZDOS has one signal entry per program). Offered
   through .zdos_imports (an entry with an empty name, from zdl-stubs) and
   threads->local() while the libraries load; set as host in each library. */
#define ZDOS_RUNTIME_MAGIC 0x314d5452534f445aull /* "ZDOSRTM1" */
typedef struct zdos_runtime {
    uint64_t magic;
    int (*thread_create)(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg);
    void (*thread_exit)(void *result);
    int (*key_create)(pthread_key_t *key, void (*destructor)(void *));
    int (*key_delete)(pthread_key_t key);
    void *(*get_specific)(pthread_key_t key);
    int (*set_specific)(pthread_key_t key, const void *value);
    int *(*errno_location)(void);
    int (*sig_action)(int sig, const struct sigaction *act, struct sigaction *old);
    int (*sig_raise)(int sig);
} zdos_runtime;
extern const zdos_runtime zdos_runtime_offer; /* zdos_posix.c */
extern const zdos_runtime *zdos_runtime_host; /* zdos_libc.c; NULL in programs */
/* A shared library (zdos_library_shared), one copy for every program: it
   has no host, and keeps nothing in a program's memory (zdos_libc.c) */
extern bool zdos_library_one_copy;

/* thread_local blocks (zdos_tls.c): a thread's own, made and set */
void *zdos_tls_start(void);
/* x86 (x87): rounding to double, as on the other CPUs (zdos_tls.c);
   nothing elsewhere. zdos_tls_start calls it: start-up and new threads. */
void zdos_fpu_double(void);
void zdos_tls_free(void *tp);

/* Futexes (zdos_libc.c): ZDOS's threads->futex_wait / futex_wake; on an
   older ZDOS without them a wait is a yield and a 1 ms nap (ZDOS_ERROR_NONE),
   so callers look at their word again */
bool zdos_futex_ok(void);
uint32_t zdos_futex_wait(const uint32_t *word, uint32_t expected, int32_t timeout_ms);
void zdos_futex_wake(const uint32_t *word, uint32_t count);
/* Milliseconds until at on clock, rounded up (0: passed; at most INT32_MAX) */
int32_t zdos_ms_until(int clock, const struct timespec *at);

/* A lock word: 0 free, 1 taken, 2 taken with waiters (Drepper's "Futexes
   Are Tricky", mutex 3) */
bool zdos_word_trylock(uint32_t *word);
/* at NULL: no limit; false once at (on clock) has passed */
bool zdos_word_lock_until(uint32_t *word, const struct timespec *at, int clock);
void zdos_word_lock(uint32_t *word);
void zdos_word_unlock(uint32_t *word);

/* The calling thread's task id (before threads exist without asking ZDOS) */
uint32_t zdos_self_id(void);

/* For first uses (the library's static locals, atexit): a lock word */
void zdos_init_lock_take(void);
void zdos_init_lock_give(void);

/* A recursive lock (streams, C++ static-local guards) on a lock word */
typedef struct {
    uint32_t word;
    uint32_t owner; /* task id */
    int count;
} zdos_rlock;
/* false only for try_only when another thread holds it */
bool zdos_rlock_take(zdos_rlock *l, bool try_only);
void zdos_rlock_give(zdos_rlock *l);

/* Whether tasks->spawn_env works here (posix_spawn with envp; zdos_posix.c) */
bool zdos_spawn_env_works(void);

/* Directory descriptors (zdos_linux.c) are told of close and closedir
   through these, set once the first is made; a DIR's path, for dirfd */
extern void (*zdos_close_hook)(int fd);
extern void (*zdos_closedir_hook)(DIR *dir);
const char *zdos_dir_path(DIR *dir);

/* setenv and unsetenv (value NULL) tell environ (zdos_linux.c) through this;
   set by environ's constructor, NULL without it */
extern void (*zdos_environ_hook)(const char *name, const char *value);

/* The modification time of open descriptor fd (futimens, futimes): 0, or -1
   with errno (ENOSYS from a ZDOS without files->fset_time) */
int zdos_fd_set_modified(int fd, time_t t);

/* The handle of descriptor fd for a task started now (spawn_ex): a ZDOS
   handle, ZDOS_SAME_STREAM (0, 1, 2 as they are), or -100 for a bad one */
int32_t zdos_fd_spawn_handle(int fd);

/* Sockets (zdos_net.c): a descriptor for a socket handle (closed again if
   none is free), and the handle of a socket descriptor (-1 with errno:
   EBADF, ENOTSOCK) */
int zdos_fd_for_socket(int32_t handle);
int32_t zdos_fd_socket(int fd);
/* A descriptor for another handle read and written as it
   is (event queues, counters: zdos_linux.c);
   closed again if none is free */
int zdos_fd_for_handle(int32_t handle);

/* While a vfork child runs (until its exec or _exit): what it does to its
   descriptors is kept apart from the parent's. std: the child's standard
   streams for spawn_ex; closed: descriptors it closed (the parent's stay open);
   opened: descriptors it opened (the parent closes them after). */
typedef struct {
    int32_t std[3];
    bool closed[ZDOS_MAX_FILES];
    bool opened[ZDOS_MAX_FILES];
} zdos_vfork_fds;
extern zdos_vfork_fds *zdos_vfork_child;
/* _exit in a vfork child (zdos_posix.c): the parent goes on, the child's
   status kept for waitpid. Hooks rather than weak symbols: programs built
   without zdos_posix.c must have only relative relocations. */
extern void (*zdos_vfork_exit_hook)(int status);

/* Terminal settings (termios, zdos_posix.c): reading the keyboard without
   the line editor. Returns -2 when the line editor is wanted.
   NULL without zdos_posix.c. */
extern ssize_t (*zdos_tty_read_hook)(void *buf, size_t count);

/* Signal handlers (zdos_libc.c): what sigaction set; zdos_signals_sync()
   tells ZDOS which are caught and ignored */
#define ZDOS_NSIG 65
extern void (*zdos_signal_handlers[ZDOS_NSIG])(int);
extern uint64_t zdos_signal_masks[ZDOS_NSIG];
extern int zdos_signal_flags[ZDOS_NSIG];
void zdos_signals_sync(void);

/* The running task's CPU milliseconds (clock_gettime, getrusage) */
uint64_t zdos_own_cpu_ms(void);

#endif
