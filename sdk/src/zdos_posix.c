/* POSIX processes, threads, signals, polling and terminals on ZDOS's tasks.
 * A process is a task (its ID the task's number); outside the metal
 * editions starting one fails with ENOSYS (exec works everywhere).
 *
 *   processes   posix_spawn(p), waitpid / wait, exec*, vfork (no fork),
 *               kill, alarm, pause, sysconf
 *   signals     sigaction, sigprocmask and the sigset functions, sigsuspend
 *               (the handlers themselves are in zdos_libc.c)
 *   threads     pthread_*: threads, mutexes (priority inheritance),
 *               conditions, read-write locks, barriers, keys, once;
 *               semaphores (sem_*), sched_*
 *   polling     poll, select
 *   terminals   termios (raw keyboard input), ioctl TIOCGWINSZ
 */

#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <setjmp.h>
#include <signal.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int fail(int e) {
    errno = e;
    return -1;
}

static int fail_last(void) {
    errno = zdos_errno_from_last_error();
    return -1;
}

/* STARTING PROGRAMS */

// The command line for argv[1..]: words with a space, a tab or a quote (or
// empty) in double quotes, a quote inside as \" (zdos_crt0.c splits it back)
static char *join_args(char *const argv[], size_t *len_out) {
    size_t cap = 1;
    for (size_t i = 1; argv != NULL && argv[0] != NULL && argv[i] != NULL; i++) {
        cap += strlen(argv[i]) * 2 + 3;
    }
    char *s = malloc(cap);
    if (s == NULL) {
        return NULL;
    }
    size_t n = 0;
    for (size_t i = 1; argv != NULL && argv[0] != NULL && argv[i] != NULL; i++) {
        const char *a = argv[i];
        if (n > 0) {
            s[n++] = ' ';
        }
        bool quote = a[0] == '\0' || strpbrk(a, " \t\"") != NULL;
        if (quote) {
            s[n++] = '"';
        }
        for (; *a; a++) {
            if (*a == '"') {
                s[n++] = '\\';
            }
            s[n++] = *a;
        }
        if (quote) {
            s[n++] = '"';
        }
    }
    s[n] = '\0';
    *len_out = n;
    return s;
}

// Whether name is a bare name, looked for in PATH
static bool bare_name(const char *name) {
    return strpbrk(name, "\\/:") == NULL;
}

// try(path) for name, then for each folder of PATH (;-separated) with name
// if name is bare and search is set: the first result other than NOT_FOUND
static int with_path(const char *name, bool search, int (*try)(const char *path, void *ctx), void *ctx) {
    int r = try(name, ctx);
    if (r != -2 || !search || !bare_name(name)) {
        return r;
    }
    const char *path = getenv("PATH");
    char buf[PATH_MAX];
    while (path != NULL && *path) {
        const char *end = strchr(path, ';');
        size_t len = end ? (size_t)(end - path) : strlen(path);
        if (len > 0 && len + strlen(name) + 2 < sizeof(buf)) {
            memcpy(buf, path, len);
            size_t n = len;
            if (buf[n - 1] != '\\' && buf[n - 1] != '/') {
                buf[n++] = '\\';
            }
            strcpy(buf + n, name);
            r = try(buf, ctx);
            if (r != -2) {
                return r;
            }
        }
        path = end ? end + 1 : NULL;
    }
    return -2;
}

struct start_ctx {
    const char *args;
    size_t args_len;
    zdos_spawn_options options;
    const char *env; /* a block for tasks->spawn_env; NULL: the global variables */
    size_t env_len;
};

// 1: tasks->spawn_env works, -1: this ZDOS lacks it, 0: not tried yet
static int spawn_env_state;

bool zdos_spawn_env_works(void) {
    if (spawn_env_state == 0 && zdos != NULL) {
        // An empty path: INVALID_ARGUMENT or NOT_FOUND where it exists
        zdos->tasks->spawn_env("", 0, "", 0, NULL, "", 0);
        spawn_env_state = zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? -1 : 1;
    }
    return spawn_env_state > 0;
}

// envp's "NAME=value" entries, each ended by a 0 byte,
// for spawn_env (malloc'ed); NULL with errno
static char *env_block(char *const envp[], size_t *len) {
    size_t n = 0;
    for (char *const *e = envp; *e != NULL; e++) {
        n += strlen(*e) + 1;
    }
    char *b = malloc(n + 1);
    if (b == NULL) {
        errno = ENOMEM;
        return NULL;
    }
    size_t at = 0;
    for (char *const *e = envp; *e != NULL; e++) {
        size_t k = strlen(*e) + 1;
        memcpy(b + at, *e, k);
        at += k;
    }
    *len = at;
    return b;
}

// -2: not found (look further), -1: failed (errno), else the task's id
static int try_spawn(const char *path, void *p) {
    struct start_ctx *c = p;
    int32_t id = c->env != NULL ? zdos->tasks->spawn_env(path, strlen(path), c->args, c->args_len, &c->options, c->env, c->env_len)
                                : zdos->tasks->spawn_ex(path, strlen(path), c->args, c->args_len, &c->options);
    if (id >= 0) {
        return id;
    }
    uint32_t code = zdos->programs->last_error();
    if (code == ZDOS_ERROR_NOT_FOUND || code == ZDOS_ERROR_PATH_NOT_FOUND) {
        return -2;
    }
    errno = zdos_errno_from_code(code);
    return -1;
}

// The program as a new task with these standard streams and envp's
// variables (NULL, or a ZDOS without spawn_env: the global ones): its
// process ID
static pid_t start_task(const char *path, char *const argv[], const int32_t std[3], char *const envp[], bool search) {
    if (zdos == NULL) {
        return fail(ENOSYS);
    }
    struct start_ctx c = {.options = {sizeof(zdos_spawn_options), -1, std[0], std[1], std[2], -1}};
    char *block = NULL;
    if (envp != NULL && zdos_spawn_env_works()) {
        block = env_block(envp, &c.env_len);
        if (block == NULL) {
            return -1;
        }
        c.env = block;
    }
    char *args = join_args(argv, &c.args_len);
    if (args == NULL) {
        free(block);
        return fail(ENOMEM);
    }
    c.args = args;
    int r = with_path(path, search, try_spawn, &c);
    free(args);
    free(block);
    if (r == -2) {
        return fail(ENOENT);
    }
    return r < 0 ? -1 : (pid_t)r;
}

/* posix_spawn */

enum { ACT_CLOSE, ACT_DUP2, ACT_OPEN };

struct zdos_spawn_action {
    int kind;
    int fd;
    int new_fd;
    int flags;
    char *path;
};

int posix_spawn_file_actions_init(posix_spawn_file_actions_t *fa) {
    fa->count = 0;
    fa->actions = NULL;
    return 0;
}

int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *fa) {
    for (int i = 0; i < fa->count; i++) {
        free(fa->actions[i].path);
    }
    free(fa->actions);
    fa->actions = NULL;
    fa->count = 0;
    return 0;
}

static int add_action(posix_spawn_file_actions_t *fa, struct zdos_spawn_action a) {
    struct zdos_spawn_action *n = realloc(fa->actions, sizeof(*n) * (size_t)(fa->count + 1));
    if (n == NULL) {
        return ENOMEM;
    }
    fa->actions = n;
    fa->actions[fa->count++] = a;
    return 0;
}

int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *fa, int fd) {
    return add_action(fa, (struct zdos_spawn_action){ACT_CLOSE, fd, 0, 0, NULL});
}

int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *fa, int fd, int new_fd) {
    return add_action(fa, (struct zdos_spawn_action){ACT_DUP2, fd, new_fd, 0, NULL});
}

int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *fa, int fd, const char *path, int flags, mode_t mode) {
    (void)mode;
    char *copy = strdup(path);
    if (copy == NULL) {
        return ENOMEM;
    }
    int r = add_action(fa, (struct zdos_spawn_action){ACT_OPEN, fd, 0, flags, copy});
    if (r != 0) {
        free(copy);
    }
    return r;
}

int posix_spawnattr_init(posix_spawnattr_t *a) {
    memset(a, 0, sizeof(*a));
    a->priority = -1;
    return 0;
}

int posix_spawnattr_destroy(posix_spawnattr_t *a) {
    (void)a;
    return 0;
}

int posix_spawnattr_setflags(posix_spawnattr_t *a, short flags) {
    a->flags = flags;
    return 0;
}

int posix_spawnattr_getflags(const posix_spawnattr_t *a, short *flags) {
    *flags = a->flags;
    return 0;
}

int posix_spawnattr_setsigmask(posix_spawnattr_t *a, const sigset_t *mask) {
    a->sigmask = *mask;
    return 0;
}

int posix_spawnattr_getsigmask(const posix_spawnattr_t *a, sigset_t *mask) {
    *mask = a->sigmask;
    return 0;
}

int posix_spawnattr_setsigdefault(posix_spawnattr_t *a, const sigset_t *set) {
    a->sigdefault = *set;
    return 0;
}

int posix_spawnattr_getsigdefault(const posix_spawnattr_t *a, sigset_t *set) {
    *set = a->sigdefault;
    return 0;
}

int posix_spawnattr_setschedparam(posix_spawnattr_t *a, const struct sched_param *p) {
    a->priority = p->sched_priority;
    return 0;
}

int posix_spawnattr_getschedparam(const posix_spawnattr_t *a, struct sched_param *p) {
    p->sched_priority = a->priority < 0 ? 16 : a->priority;
    return 0;
}

int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t group) {
    (void)a;
    (void)group;
    return 0; /* no process groups: accepted */
}

static int spawn_common(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                        const posix_spawnattr_t *attr, char *const argv[], char *const envp[], bool search) {
    if (zdos == NULL) {
        return ENOSYS;
    }
    // The child's standard streams after the actions; files opened for it
    // are closed here once it has them
    int32_t std[3] = {ZDOS_SAME_STREAM, ZDOS_CALLER_OUTPUT, ZDOS_CALLER_ERROR};
    int opened[16];
    int n_opened = 0;
    int err = 0;
    for (int i = 0; fa != NULL && i < fa->count && err == 0; i++) {
        const struct zdos_spawn_action *a = &fa->actions[i];
        if (a->kind == ACT_CLOSE) {
            if (a->fd >= 0 && a->fd < 3) {
                std[a->fd] = ZDOS_NUL_STREAM;
            }
        } else if (a->kind == ACT_DUP2) {
            int32_t h = a->fd >= 0 && a->fd < 3 ? std[a->fd] : zdos_fd_spawn_handle(a->fd);
            if (h == -100) {
                err = EBADF;
            } else if (a->new_fd >= 0 && a->new_fd < 3) {
                std[a->new_fd] = h;
            }
        } else {
            int fd = open(a->path, a->flags, 0666);
            if (fd < 0) {
                err = errno;
            } else if (n_opened == 16) {
                close(fd);
                err = EMFILE;
            } else {
                opened[n_opened++] = fd;
                if (a->fd >= 0 && a->fd < 3) {
                    std[a->fd] = zdos_fd_spawn_handle(fd);
                }
            }
        }
    }
    pid_t p = -1;
    if (err == 0) {
        p = start_task(path, argv, std, envp, search);
        if (p < 0) {
            err = errno;
        }
    }
    for (int i = 0; i < n_opened; i++) {
        close(opened[i]);
    }
    if (err != 0) {
        return err;
    }
    if (attr != NULL && attr->priority >= 0) {
        zdos->tasks->set_priority((uint32_t)p, (uint32_t)attr->priority);
    }
    if (pid != NULL) {
        *pid = p;
    }
    return 0;
}

// envp NULL: the global variables, as before spawn_env (POSIX leaves it open)
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn_common(pid, path, fa, attr, argv, envp, false);
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    return spawn_common(pid, file, fa, attr, argv, envp, true);
}

/* VFORK
   The child part runs on the parent's stack until exec or _exit; then the
   parent goes on from vfork's setjmp with the child's process ID. A child
   that _exits before exec gets a made-up ID whose status waitpid gives. */

static jmp_buf vfork_jmp;
static zdos_vfork_fds vfork_fds;
static pid_t vfork_pid;

#define MAX_FAKE 8
static struct {
    pid_t pid;
    int status;
} fake_children[MAX_FAKE];
static pid_t next_fake = 0x40000000;

jmp_buf *zdos_vfork_jmp(void) {
    return &vfork_jmp;
}

pid_t zdos_vfork_return(int jumped) {
    if (!jumped) {
        if (zdos_vfork_child != NULL) {
            return fail(EAGAIN); /* a vfork inside a vfork child */
        }
        memset(&vfork_fds, 0, sizeof(vfork_fds));
        vfork_fds.std[0] = ZDOS_SAME_STREAM;
        vfork_fds.std[1] = ZDOS_CALLER_OUTPUT;
        vfork_fds.std[2] = ZDOS_CALLER_ERROR;
        zdos_vfork_child = &vfork_fds;
        return 0;
    }
    zdos_vfork_child = NULL;
    for (int fd = 3; fd < ZDOS_MAX_FILES; fd++) {
        if (vfork_fds.opened[fd]) {
            close(fd); /* the child's own: the program it started has them */
        }
    }
    return vfork_pid;
}

static void vfork_finish(pid_t pid) __attribute__((noreturn));
static void vfork_finish(pid_t pid) {
    vfork_pid = pid;
    longjmp(vfork_jmp, 1);
}

static void vfork_exited(int status) __attribute__((noreturn));
static void vfork_exited(int status) {
    pid_t pid = next_fake++;
    for (int i = 0; i < MAX_FAKE; i++) {
        if (fake_children[i].pid == 0) {
            fake_children[i].pid = pid;
            fake_children[i].status = (status & 0xff) << 8;
            break;
        }
    }
    vfork_finish(pid);
}

// fork() itself is vfork (a macro in unistd.h); only a call through a
// pointer gets here
pid_t(fork)(void) {
    return fail(ENOSYS); /* one address space for all programs: see vfork */
}

// The same for vfork: configure's check for it links against this
pid_t(vfork)(void) {
    return fail(ENOSYS);
}

/* EXEC */

struct exec_ctx {
    const char *args;
    size_t args_len;
};

static int try_exec(const char *path, void *p) {
    struct exec_ctx *c = p;
    int32_t code = zdos->programs->exec(path, strlen(path), c->args, c->args_len);
    if (code >= 0) {
        _exit(code); /* the program ran in place of this one */
    }
    uint32_t e = zdos->programs->last_error();
    if (e == ZDOS_ERROR_NOT_FOUND || e == ZDOS_ERROR_PATH_NOT_FOUND) {
        return -2;
    }
    errno = zdos_errno_from_code(e);
    return -1;
}

// The variables become envp's for a program run in place of this one: its
// own scope (setenv's) set from envp, the others unset there
static int exec_env(char *const envp[]) {
    char buf[600];
    for (uint32_t i = 0, steps = 0; steps < 1000; steps++) {
        int64_t n = zdos->programs->var_at(i, buf, sizeof(buf));
        if (n < 0) {
            break;
        }
        buf[(size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1] = '\0';
        char *eq = strchr(buf, '=');
        bool keep = false;
        if (eq != NULL) {
            *eq = '\0';
            size_t len = (size_t)(eq - buf);
            for (char *const *e = envp; *e != NULL && !keep; e++) {
                keep = strncasecmp(*e, buf, len) == 0 && (*e)[len] == '=';
            }
        }
        // Unsetting takes it out of what var_at lists: the same index again
        if (eq == NULL || keep || unsetenv(buf) != 0) {
            i++;
        }
    }
    for (char *const *e = envp; *e != NULL; e++) {
        if (putenv(*e) != 0) {
            return -1;
        }
    }
    return 0;
}

static int exec_common(const char *path, char *const argv[], char *const envp[], bool search) {
    if (zdos == NULL) {
        return fail(ENOSYS);
    }
    if (zdos_vfork_child != NULL) {
        // A vfork child: the program becomes a task, the parent goes on
        pid_t p = start_task(path, argv, zdos_vfork_child->std, envp, search);
        if (p < 0) {
            return -1; /* the child goes on (and usually _exits) */
        }
        vfork_finish(p);
    }
    if (envp != NULL && exec_env(envp) != 0) {
        return -1;
    }
    zdos_flush_streams();
    struct exec_ctx c;
    char *args = join_args(argv, &c.args_len);
    if (args == NULL) {
        return fail(ENOMEM);
    }
    c.args = args;
    int r = with_path(path, search, try_exec, &c);
    free(args);
    return r == -2 ? fail(ENOENT) : -1;
}

int execv(const char *path, char *const argv[]) {
    return exec_common(path, argv, NULL, false);
}

int execve(const char *path, char *const argv[], char *const envp[]) {
    return exec_common(path, argv, envp, false);
}

int execvp(const char *file, char *const argv[]) {
    return exec_common(file, argv, NULL, true);
}

// The arguments of execl and its kin as an argv (at most 64)
#define MAX_EXEC_ARGS 64
static void collect_args(char **argv, const char *first, va_list ap) {
    int n = 0;
    argv[n++] = (char *)first;
    while (first != NULL && n < MAX_EXEC_ARGS) {
        char *a = va_arg(ap, char *);
        argv[n++] = a;
        if (a == NULL) {
            return;
        }
    }
    argv[MAX_EXEC_ARGS] = NULL;
}

int execl(const char *path, const char *arg, ...) {
    char *argv[MAX_EXEC_ARGS + 1];
    va_list ap;
    va_start(ap, arg);
    collect_args(argv, arg, ap);
    va_end(ap);
    return execv(path, argv);
}

int execlp(const char *file, const char *arg, ...) {
    char *argv[MAX_EXEC_ARGS + 1];
    va_list ap;
    va_start(ap, arg);
    collect_args(argv, arg, ap);
    va_end(ap);
    return execvp(file, argv);
}

// The environment follows the arguments' NULL
int execle(const char *path, const char *arg, ...) {
    char *argv[MAX_EXEC_ARGS + 1];
    va_list ap;
    va_start(ap, arg);
    collect_args(argv, arg, ap);
    va_end(ap);
    // collect_args's copy of ap moved on, not ours (x86): walk past the NULL
    va_start(ap, arg);
    for (const char *a = arg; a != NULL;) {
        a = va_arg(ap, const char *);
    }
    char *const *envp = va_arg(ap, char *const *);
    va_end(ap);
    return execve(path, argv, envp);
}

/* WAITPID */

static int encode_status(const zdos_task_end *e) {
    return e->signal != 0 ? (e->signal & 0x7f) : (e->code << 8);
}

pid_t waitpid(pid_t pid, int *status, int options) {
    if (zdos == NULL) {
        return fail(ECHILD);
    }
    for (int i = 0; i < MAX_FAKE; i++) {
        pid_t f = fake_children[i].pid;
        if (f != 0 && (pid <= 0 || pid == f)) {
            if (status != NULL) {
                *status = fake_children[i].status;
            }
            fake_children[i].pid = 0;
            return f;
        }
    }
    zdos_task_end e;
    if (pid <= 0) {
        int32_t id = zdos->tasks->wait_any((options & WNOHANG) ? ZDOS_WAIT_NO_HANG : 0, &e);
        if (id < 0) {
            return zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED ? fail(ECHILD) : fail_last();
        }
        if (id == 0) {
            return 0;
        }
        if (status != NULL) {
            *status = encode_status(&e);
        }
        return (pid_t)id;
    }
    uint32_t id = (uint32_t)pid;
    if (options & WNOHANG) {
        uint8_t code;
        if (!zdos->tasks->ended(id, &code)) {
            return zdos->tasks->priority(id) < 0 ? fail(ECHILD) : 0;
        }
    }
    if (!zdos->tasks->wait_end(id, &e)) {
        uint32_t c = zdos->programs->last_error();
        return c == ZDOS_ERROR_INVALID_ARGUMENT || c == ZDOS_ERROR_NOT_SUPPORTED ? fail(ECHILD) : fail_last();
    }
    if (status != NULL) {
        *status = encode_status(&e);
    }
    return pid;
}

pid_t wait(int *status) {
    return waitpid(-1, status, 0);
}

/* SIGNALS */

int kill(pid_t pid, int sig) {
    if (zdos == NULL || sig < 0 || sig >= ZDOS_NSIG - 1) {
        return fail(EINVAL);
    }
    if (pid == 0) {
        pid = getpid(); /* no process groups: the caller */
    }
    if (pid < 0) {
        return fail(EINVAL);
    }
    if (!zdos->signals->send((uint32_t)pid, (uint32_t)sig)) {
        uint32_t c = zdos->programs->last_error();
        return fail(c == ZDOS_ERROR_NOT_FOUND ? ESRCH : c == ZDOS_ERROR_NOT_SUPPORTED ? ENOSYS : EINVAL);
    }
    return 0;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->sig_action(sig, act, old);
    }
    if (sig <= 0 || sig >= ZDOS_NSIG - 1 || (act != NULL && (sig == SIGKILL || sig == SIGSTOP))) {
        return fail(EINVAL);
    }
    if (old != NULL) {
        old->sa_handler = zdos_signal_handlers[sig];
        old->sa_mask = zdos_signal_masks[sig];
        old->sa_flags = zdos_signal_flags[sig];
    }
    if (act != NULL) {
        zdos_signal_handlers[sig] = act->sa_handler;
        zdos_signal_masks[sig] = act->sa_mask;
        zdos_signal_flags[sig] = act->sa_flags;
        zdos_signals_sync();
    }
    return 0;
}

int sigprocmask(int how, const sigset_t *set, sigset_t *old) {
    if (how < SIG_BLOCK || how > SIG_SETMASK) {
        return fail(EINVAL);
    }
    uint64_t prev = zdos != NULL ? zdos->signals->mask(set != NULL ? (uint32_t)how : SIG_BLOCK, set != NULL ? *set : 0) : 0;
    if (old != NULL) {
        *old = prev;
    }
    return 0;
}

void zdos_sigsetjmp_save(sigjmp_buf env, int save) {
    env->saved = save;
    if (save) {
        sigset_t now;
        sigprocmask(SIG_BLOCK, NULL, &now);
        env->mask = now;
    }
}

void siglongjmp(sigjmp_buf env, int val) {
    if (env->saved) {
        sigset_t mask = env->mask;
        sigprocmask(SIG_SETMASK, &mask, NULL);
    }
    longjmp(env->buf, val);
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) {
    return sigprocmask(how, set, old) == 0 ? 0 : errno;
}

int sigpending(sigset_t *set) {
    *set = zdos != NULL ? zdos->signals->pending() : 0;
    return 0;
}

int sigsuspend(const sigset_t *mask) {
    if (zdos != NULL) {
        zdos->signals->wait(*mask);
    }
    return fail(EINTR);
}

int pause(void) {
    if (zdos != NULL) {
        zdos->signals->wait(zdos->signals->mask(SIG_BLOCK, 0));
    }
    return fail(EINTR);
}

unsigned int alarm(unsigned int seconds) {
    if (zdos == NULL) {
        return 0;
    }
    uint64_t left = zdos->signals->alarm((uint64_t)seconds * 1000);
    return (unsigned int)((left + 999) / 1000);
}

/* THE TASK'S TIMER: SETITIMER (ITIMER_REAL) AND POSIX TIMERS
   One per task in ZDOS (signals->set_timer), shared with alarm */

static uint64_t tv_ns(const struct timeval *tv) {
    return (uint64_t)tv->tv_sec * 1000000000ULL + (uint64_t)tv->tv_usec * 1000ULL;
}

static void ns_tv(uint64_t ns, struct timeval *tv) {
    tv->tv_sec = (time_t)(ns / 1000000000ULL);
    tv->tv_usec = (suseconds_t)((ns % 1000000000ULL) / 1000ULL);
}

static uint64_t ts_ns(const struct timespec *ts) {
    return (uint64_t)ts->tv_sec * 1000000000ULL + (uint64_t)ts->tv_nsec;
}

static void ns_ts(uint64_t ns, struct timespec *ts) {
    ts->tv_sec = (time_t)(ns / 1000000000ULL);
    ts->tv_nsec = (long)(ns % 1000000000ULL);
}

static bool have_timer(void) {
    return zdos != NULL && zdos->signals->set_timer != NULL && zdos->signals->timer != NULL;
}

int setitimer(int which, const struct itimerval *value, struct itimerval *old) {
    if (which != ITIMER_REAL || value == NULL || value->it_value.tv_usec < 0 || value->it_value.tv_usec >= 1000000 ||
        value->it_interval.tv_usec < 0 || value->it_interval.tv_usec >= 1000000) {
        return fail(EINVAL);
    }
    if (!have_timer()) {
        return fail(ENOSYS);
    }
    zdos_timer_setting before;
    zdos->signals->set_timer(SIGALRM, tv_ns(&value->it_value), tv_ns(&value->it_interval), &before);
    if (old != NULL) {
        ns_tv(before.left, &old->it_value);
        ns_tv(before.interval, &old->it_interval);
    }
    return 0;
}

int getitimer(int which, struct itimerval *value) {
    if (which != ITIMER_REAL || value == NULL) {
        return fail(EINVAL);
    }
    if (!have_timer()) {
        return fail(ENOSYS);
    }
    zdos_timer_setting now;
    zdos->signals->timer(&now);
    ns_tv(now.left, &value->it_value);
    ns_tv(now.interval, &value->it_interval);
    return 0;
}

/* The one timer: its signal and clock while created */
static int timer_sig = 0; /* 0: none created */
static clockid_t timer_clock = CLOCK_MONOTONIC;

int timer_create(clockid_t clock, struct sigevent *ev, timer_t *id) {
    if ((clock != CLOCK_MONOTONIC && clock != CLOCK_REALTIME) || id == NULL) {
        return fail(EINVAL);
    }
    if (!have_timer()) {
        return fail(ENOSYS);
    }
    if (timer_sig != 0) {
        return fail(EAGAIN); /* one per task */
    }
    int sig = SIGALRM;
    if (ev != NULL) {
        if (ev->sigev_notify == SIGEV_NONE) {
            sig = -1;
        } else if (ev->sigev_notify == SIGEV_SIGNAL && ev->sigev_signo > 0 && ev->sigev_signo < 64) {
            sig = ev->sigev_signo;
        } else {
            return fail(EINVAL);
        }
    }
    timer_sig = sig;
    timer_clock = clock;
    *id = 1;
    return 0;
}

int timer_delete(timer_t id) {
    if (id != 1 || timer_sig == 0) {
        return fail(EINVAL);
    }
    zdos->signals->set_timer(SIGALRM, 0, 0, NULL);
    timer_sig = 0;
    return 0;
}

int timer_settime(timer_t id, int flags, const struct itimerspec *value, struct itimerspec *old) {
    if (id != 1 || timer_sig == 0 || value == NULL || value->it_value.tv_nsec < 0 || value->it_value.tv_nsec >= 1000000000L ||
        value->it_interval.tv_nsec < 0 || value->it_interval.tv_nsec >= 1000000000L) {
        return fail(EINVAL);
    }
    uint64_t first = ts_ns(&value->it_value);
    if (first != 0 && (flags & TIMER_ABSTIME)) {
        /* An absolute time on the timer's clock: as from now */
        struct timespec now;
        clock_gettime(timer_clock, &now);
        uint64_t n = ts_ns(&now);
        first = first > n ? first - n : 1;
    }
    /* SIGEV_NONE: a timer that runs without a signal; ZDOS's timer always
       signals, so it keeps SIGALRM's place unarmed (gettime then shows 0) */
    int sig = timer_sig > 0 ? timer_sig : SIGALRM;
    if (timer_sig < 0) {
        first = 0;
    }
    zdos_timer_setting before;
    zdos->signals->set_timer((uint32_t)sig, first, ts_ns(&value->it_interval), &before);
    if (old != NULL) {
        ns_ts(before.left, &old->it_value);
        ns_ts(before.interval, &old->it_interval);
    }
    return 0;
}

int timer_gettime(timer_t id, struct itimerspec *value) {
    if (id != 1 || timer_sig == 0 || value == NULL) {
        return fail(EINVAL);
    }
    zdos_timer_setting now;
    zdos->signals->timer(&now);
    ns_ts(now.left, &value->it_value);
    ns_ts(now.interval, &value->it_interval);
    return 0;
}

int timer_getoverrun(timer_t id) {
    if (id != 1 || timer_sig == 0) {
        return fail(EINVAL);
    }
    return 0;
}

int sigemptyset(sigset_t *set) {
    *set = 0;
    return 0;
}

int sigfillset(sigset_t *set) {
    *set = ~(sigset_t)1;
    return 0;
}

int sigaddset(sigset_t *set, int sig) {
    if (sig <= 0 || sig >= 64) {
        return fail(EINVAL);
    }
    *set |= (sigset_t)1 << sig;
    return 0;
}

int sigdelset(sigset_t *set, int sig) {
    if (sig <= 0 || sig >= 64) {
        return fail(EINVAL);
    }
    *set &= ~((sigset_t)1 << sig);
    return 0;
}

int sigismember(const sigset_t *set, int sig) {
    if (sig <= 0 || sig >= 64) {
        return fail(EINVAL);
    }
    return (*set >> sig) & 1;
}

int getdtablesize(void) {
    return ZDOS_MAX_FILES;
}

long sysconf(int name) {
    switch (name) {
        case _SC_CLK_TCK: return 1000;
        case _SC_OPEN_MAX: return ZDOS_MAX_FILES;
        case _SC_PAGESIZE: return 4096;
        case _SC_NPROCESSORS_CONF:
        case _SC_NPROCESSORS_ONLN: return zdos != NULL && zdos->cores->count != NULL ? (long)zdos->cores->count() : 1;
        case _SC_PHYS_PAGES:
        case _SC_AVPHYS_PAGES: {
            zdos_system_info info;
            zdos->programs->system_info(&info);
            return (long)((name == _SC_PHYS_PAGES ? info.total_memory : info.free_memory) / 4096);
        }
        default: return fail(EINVAL);
    }
}

/* THREADS Each thread created here has a record (its errno first, so
   __errno_location finds it through threads->local, then its keys' values);
   the program's own thread uses main_thread. */

struct zdos_thread {
    int err;
    void *(*start)(void *);
    void *arg;
    void *values[PTHREAD_KEYS_MAX];
    void *tls; /* its thread_local block (zdos_tls.c) */
};

static struct zdos_thread main_thread;
static void (*key_destructors[PTHREAD_KEYS_MAX])(void *);
static bool key_used[PTHREAD_KEYS_MAX];

static struct zdos_thread *self_record(void) {
    if (!zdos_threads_started) {
        return &main_thread;
    }
    struct zdos_thread *t = (struct zdos_thread *)zdos->threads->local();
    return t != NULL ? t : &main_thread;
}

static void run_destructors(struct zdos_thread *t) {
    for (int round = 0; round < 4; round++) {
        bool any = false;
        for (int k = 0; k < PTHREAD_KEYS_MAX; k++) {
            void *v = t->values[k];
            if (v != NULL && key_used[k] && key_destructors[k] != NULL) {
                t->values[k] = NULL;
                key_destructors[k](v);
                any = true;
            }
        }
        if (!any) {
            return;
        }
    }
}

static void end_thread(void *result) __attribute__((noreturn));
static void end_thread(void *result) {
    struct zdos_thread *t = self_record();
    if (zdos_thread_dtors_hook != NULL) {
        zdos_thread_dtors_hook();
    }
    run_destructors(t);
    if (t != &main_thread) {
        zdos->threads->set_local(0);
        zdos->threads->set_thread_pointer(0);
        zdos_tls_free(t->tls);
        free(t);
    }
    zdos->threads->exit((uintptr_t)result);
}

static uintptr_t ZDOS_CALL thread_start(void *p) {
    struct zdos_thread *t = p;
    zdos->threads->set_local((uintptr_t)t);
    t->tls = zdos_tls_start();
    end_thread(t->start(t->arg));
}

// The lock that makes first uses (static initializers) safe once threads exist
static void lock_init(void) {
    zdos_init_lock_take();
}

static void unlock_init(void) {
    zdos_init_lock_give();
}

int pthread_attr_init(pthread_attr_t *a) {
    memset(a, 0, sizeof(*a));
    a->priority = -1;
    return 0;
}

int pthread_attr_destroy(pthread_attr_t *a) {
    (void)a;
    return 0;
}

int pthread_attr_setdetachstate(pthread_attr_t *a, int state) {
    a->detached = (a->detached & ~1) | (state == PTHREAD_CREATE_DETACHED);
    return 0;
}

int pthread_attr_getdetachstate(const pthread_attr_t *a, int *state) {
    *state = (a->detached & 1) ? PTHREAD_CREATE_DETACHED : PTHREAD_CREATE_JOINABLE;
    return 0;
}

int pthread_attr_setstacksize(pthread_attr_t *a, size_t size) {
    if (size < PTHREAD_STACK_MIN) {
        return EINVAL;
    }
    a->stack_size = size;
    return 0;
}

int pthread_attr_getstacksize(const pthread_attr_t *a, size_t *size) {
    size_t def = zdos->threads->default_stack_size();
    *size = a->stack_size != 0 ? a->stack_size : def != 0 ? def : 256 * 1024; /* 0: an older ZDOS */
    return 0;
}

int pthread_attr_setschedparam(pthread_attr_t *a, const struct sched_param *p) {
    if (p->sched_priority < 0 || p->sched_priority > 31) {
        return EINVAL;
    }
    a->priority = p->sched_priority;
    return 0;
}

int pthread_attr_getschedparam(const pthread_attr_t *a, struct sched_param *p) {
    p->sched_priority = a->priority < 0 ? 16 : a->priority;
    return 0;
}

/* The policy rides in `detached`'s bits 4-5 as policy + 1 (0: the
   creator's), keeping pthread_attr_t's size */
int pthread_attr_setschedpolicy(pthread_attr_t *a, int policy) {
    if (policy != SCHED_FIFO && policy != SCHED_RR && policy != SCHED_OTHER) {
        return EINVAL;
    }
    a->detached = (a->detached & 1) | (policy + 1) << 4;
    return 0;
}

int pthread_attr_getschedpolicy(const pthread_attr_t *a, int *policy) {
    int p = (a->detached >> 4) & 3;
    *policy = p != 0 ? p - 1 : SCHED_OTHER;
    return 0;
}

int pthread_attr_setinheritsched(pthread_attr_t *a, int inherit) {
    if (inherit == PTHREAD_INHERIT_SCHED) {
        a->detached &= 1;
    }
    return 0;
}

/* A task's policy and priority (sched_setscheduler, pthread_setschedparam) */
static int set_sched(uint32_t id, int policy, const struct sched_param *p) {
    if ((policy != SCHED_OTHER && policy != SCHED_FIFO && policy != SCHED_RR) || p->sched_priority < 0 ||
        p->sched_priority > 31) {
        return EINVAL;
    }
    if (policy == SCHED_OTHER) {
        policy = SCHED_RR; /* ZDOS's default is round robin */
    }
    if (!zdos->tasks->set_priority(id, (uint32_t)p->sched_priority)) {
        return zdos->programs->last_error() == ZDOS_ERROR_ACCESS_DENIED ? EPERM : ESRCH;
    }
    if (!zdos->tasks->set_policy(id, (uint32_t)policy) && policy != SCHED_RR) {
        uint32_t e = zdos->programs->last_error();
        return e == ZDOS_ERROR_ACCESS_DENIED ? EPERM : e == ZDOS_ERROR_NOT_SUPPORTED ? ENOSYS : ESRCH;
    }
    return 0;
}

static int get_policy(uint32_t id) {
    int32_t p = zdos->tasks->policy(id);
    return p < 0 ? -1 : p == SCHED_FIFO ? SCHED_FIFO : p == SCHED_DEADLINE ? SCHED_DEADLINE : SCHED_RR; /* an older ZDOS answers 0 */
}

/* AFFINITY: ZDOS KEEPS UP TO 64 CORES PER TASK */

int __zdos_cpu_count(size_t size, const cpu_set_t *set) {
    int n = 0;
    for (size_t i = 0; i < size / sizeof(unsigned long); i++) {
        n += __builtin_popcountl(set->__bits[i]);
    }
    return n;
}

static int set_affinity(uint32_t id, size_t size, const cpu_set_t *set) {
    uint64_t mask = 0;
    for (size_t c = 0; c < 64 && c < size * 8; c++) {
        if (set->__bits[__ZDOS_CPU_W(c)] & __ZDOS_CPU_B(c)) {
            mask |= (uint64_t)1 << c;
        }
    }
    if (zdos->cores->set_affinity(id, mask)) {
        return 0;
    }
    uint32_t e = zdos->programs->last_error();
    return e == ZDOS_ERROR_ACCESS_DENIED ? EPERM : e == ZDOS_ERROR_NOT_SUPPORTED ? ENOSYS : EINVAL;
}

/* The task's set, limited to the cores there are (all ones means any) */
static int get_affinity(uint32_t id, size_t size, cpu_set_t *set) {
    uint64_t mask = zdos->cores->affinity(id);
    if (mask == 0) {
        mask = ~(uint64_t)0; /* an older ZDOS: any */
    }
    uint32_t n = zdos->cores->count();
    if (n < 64) {
        mask &= ((uint64_t)1 << n) - 1;
    }
    __builtin_memset(set, 0, size);
    for (size_t c = 0; c < 64 && c < size * 8; c++) {
        if (mask & ((uint64_t)1 << c)) {
            set->__bits[__ZDOS_CPU_W(c)] |= __ZDOS_CPU_B(c);
        }
    }
    return 0;
}

int pthread_setaffinity_np(pthread_t thread, size_t size, const cpu_set_t *set) {
    return set_affinity((uint32_t)thread, size, set);
}

int pthread_getaffinity_np(pthread_t thread, size_t size, cpu_set_t *set) {
    return get_affinity((uint32_t)thread, size, set);
}

int sched_setaffinity(pid_t pid, size_t size, const cpu_set_t *set) {
    int r = set_affinity(pid == 0 ? zdos->tasks->id() : (uint32_t)pid, size, set);
    return r == 0 ? 0 : fail(r);
}

int sched_getaffinity(pid_t pid, size_t size, cpu_set_t *set) {
    int r = get_affinity(pid == 0 ? zdos->tasks->id() : (uint32_t)pid, size, set);
    return r == 0 ? 0 : fail(r);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->thread_create(thread, attr, start, arg);
    }
    if (zdos == NULL) {
        return ENOSYS;
    }
    zdos_futex_ok(); /* asked before other threads share last_error */
    struct zdos_thread *t = calloc(1, sizeof(*t));
    if (t == NULL) {
        return EAGAIN;
    }
    t->start = start;
    t->arg = arg;
    zdos_threads_started = true;
    int32_t id = zdos->threads->create(thread_start, t, attr != NULL ? attr->stack_size : 0,
                                       attr != NULL ? attr->priority : -1);
    if (id < 0) {
        free(t);
        uint32_t c = zdos->programs->last_error();
        return c == ZDOS_ERROR_NOT_SUPPORTED ? ENOSYS : EAGAIN;
    }
    if (attr != NULL && (attr->detached >> 4) & 3) {
        zdos->tasks->set_policy((uint32_t)id, (uint32_t)(((attr->detached >> 4) & 3) - 1));
    }
    if (attr != NULL && (attr->detached & 1)) {
        zdos->threads->detach((uint32_t)id);
    }
    *thread = (pthread_t)id;
    return 0;
}

int pthread_join(pthread_t thread, void **result) {
    if (thread == pthread_self()) {
        return EDEADLK;
    }
    uintptr_t r;
    if (zdos == NULL || !zdos->threads->join((uint32_t)thread, &r)) {
        return ESRCH;
    }
    if (result != NULL) {
        *result = (void *)r;
    }
    return 0;
}

int pthread_detach(pthread_t thread) {
    return zdos != NULL && zdos->threads->detach((uint32_t)thread) ? 0 : ESRCH;
}

void pthread_exit(void *result) {
    if (zdos_runtime_host != NULL) {
        zdos_runtime_host->thread_exit(result);
    }
    end_thread(result);
}

pthread_t pthread_self(void) {
    return zdos != NULL ? (pthread_t)zdos->tasks->id() : 0;
}

int pthread_equal(pthread_t a, pthread_t b) {
    return a == b;
}

int pthread_kill(pthread_t thread, int sig) {
    if (zdos == NULL || !zdos->signals->send((uint32_t)thread, (uint32_t)sig)) {
        return ESRCH;
    }
    return 0;
}

int pthread_cancel(pthread_t thread) {
    (void)thread;
    return ENOSYS; /* no cancellation: let the thread end itself */
}

int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param *p) {
    return set_sched((uint32_t)thread, policy, p);
}

int pthread_getschedparam(pthread_t thread, int *policy, struct sched_param *p) {
    int32_t prio = zdos->tasks->priority((uint32_t)thread);
    if (prio < 0) {
        return ESRCH;
    }
    *policy = get_policy((uint32_t)thread) < 0 ? SCHED_OTHER : get_policy((uint32_t)thread);
    p->sched_priority = prio;
    return 0;
}

/* 0 not yet, 1 running, 2 done, 3 running with waiters */
int pthread_once(pthread_once_t *once, void (*init)(void)) {
    uint32_t *w = (uint32_t *)once;
    for (;;) {
        uint32_t c = __atomic_load_n(w, __ATOMIC_ACQUIRE);
        if (c == 2) {
            return 0;
        }
        if (c == 0) {
            if (__atomic_compare_exchange_n(w, &c, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
                init();
                if (__atomic_exchange_n(w, 2, __ATOMIC_ACQ_REL) == 3) {
                    zdos_futex_wake(w, INT32_MAX);
                }
                return 0;
            }
            continue;
        }
        if (c == 1 && !__atomic_compare_exchange_n(w, &c, 3, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
            continue;
        }
        zdos_futex_wait(w, 3, -1);
    }
}

int pthread_key_create(pthread_key_t *key, void (*destructor)(void *)) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->key_create(key, destructor);
    }
    lock_init();
    for (int k = 0; k < PTHREAD_KEYS_MAX; k++) {
        if (!key_used[k]) {
            key_used[k] = true;
            key_destructors[k] = destructor;
            unlock_init();
            *key = (pthread_key_t)k;
            return 0;
        }
    }
    unlock_init();
    return EAGAIN;
}

int pthread_key_delete(pthread_key_t key) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->key_delete(key);
    }
    if (key >= PTHREAD_KEYS_MAX) {
        return EINVAL;
    }
    key_used[key] = false;
    key_destructors[key] = NULL;
    return 0;
}

void *pthread_getspecific(pthread_key_t key) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->get_specific(key);
    }
    return key < PTHREAD_KEYS_MAX ? self_record()->values[key] : NULL;
}

int pthread_setspecific(pthread_key_t key, const void *value) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->set_specific(key, value);
    }
    if (key >= PTHREAD_KEYS_MAX || !key_used[key]) {
        return EINVAL;
    }
    self_record()->values[key] = (void *)value;
    return 0;
}

const zdos_runtime zdos_runtime_offer = {
    ZDOS_RUNTIME_MAGIC, pthread_create, pthread_exit, pthread_key_create, pthread_key_delete,
    pthread_getspecific, pthread_setspecific, __errno_location, sigaction, raise,
};

/* MUTEXES A lock word (zdos_libc.c) on ZDOS's futex; error-checking and
   recursive ones keep their owner. PTHREAD_PRIO_INHERIT: a ZDOS mutex
   (it inherits priority; 64 in all of ZDOS), made on first use. A mutex
   an older SDK's initializer made (lock -1) is taken as free. */

#define MUTEX_TYPE 0xff
#define MUTEX_PI 0x100
#define LEGACY_FREE UINT32_MAX

static bool valid_time(const struct timespec *at) {
    return at == NULL || (at->tv_nsec >= 0 && at->tv_nsec < 1000000000);
}

int pthread_mutexattr_init(pthread_mutexattr_t *a) {
    a->type = PTHREAD_MUTEX_DEFAULT;
    return 0;
}

int pthread_mutexattr_destroy(pthread_mutexattr_t *a) {
    (void)a;
    return 0;
}

int pthread_mutexattr_settype(pthread_mutexattr_t *a, int type) {
    if (type < PTHREAD_MUTEX_NORMAL || type > PTHREAD_MUTEX_ERRORCHECK) {
        return EINVAL;
    }
    a->type = (a->type & ~MUTEX_TYPE) | type;
    return 0;
}

int pthread_mutexattr_gettype(const pthread_mutexattr_t *a, int *type) {
    *type = a->type & MUTEX_TYPE;
    return 0;
}

int pthread_mutexattr_setprotocol(pthread_mutexattr_t *a, int protocol) {
    if (protocol == PTHREAD_PRIO_PROTECT) {
        return ENOTSUP;
    }
    if (protocol != PTHREAD_PRIO_NONE && protocol != PTHREAD_PRIO_INHERIT) {
        return EINVAL;
    }
    a->type = (a->type & MUTEX_TYPE) | (protocol == PTHREAD_PRIO_INHERIT ? MUTEX_PI : 0);
    return 0;
}

int pthread_mutexattr_getprotocol(const pthread_mutexattr_t *a, int *protocol) {
    *protocol = a->type & MUTEX_PI ? PTHREAD_PRIO_INHERIT : PTHREAD_PRIO_NONE;
    return 0;
}

int pthread_mutexattr_setpshared(pthread_mutexattr_t *a, int shared) {
    (void)a;
    (void)shared;
    return 0; /* one address space: always shared */
}

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
    m->lock = 0;
    m->type = a != NULL ? a->type : PTHREAD_MUTEX_DEFAULT;
    m->count = 0;
    m->owner = 0;
    return 0;
}

// The ZDOS mutex of a PRIO_INHERIT one (+ 1), made on first use; 0: none left
static uint32_t pi_mutex(pthread_mutex_t *m) {
    uint32_t id = __atomic_load_n(&m->lock, __ATOMIC_ACQUIRE);
    if (id == 0 && zdos != NULL) {
        zdos_init_lock_take();
        id = m->lock;
        if (id == 0) {
            int32_t z = zdos->tasks->mutex_create();
            id = z >= 0 ? (uint32_t)z + 1 : 0;
            __atomic_store_n(&m->lock, id, __ATOMIC_RELEASE);
        }
        zdos_init_lock_give();
    }
    return id;
}

static int pi_take(pthread_mutex_t *m, const struct timespec *at, bool try_only) {
    uint32_t id = pi_mutex(m);
    if (id == 0) {
        return EAGAIN;
    }
    if (try_only || at != NULL) {
        for (;;) { /* timed: tries every millisecond */
            if (zdos->tasks->mutex_try_lock((int32_t)id - 1)) {
                return 0;
            }
            if (try_only) {
                return EBUSY;
            }
            if (zdos_ms_until(CLOCK_REALTIME, at) == 0) {
                return ETIMEDOUT;
            }
            zdos->time->nap(1);
        }
    }
    while (!zdos->tasks->mutex_lock((int32_t)id - 1)) {
        if (zdos->programs->last_error() != ZDOS_ERROR_INTERRUPTED) {
            return EINVAL;
        }
    }
    return 0;
}

// The lock itself, its owner left to the caller
static int mutex_acquire(pthread_mutex_t *m, const struct timespec *at, bool try_only) {
    if (m->type & MUTEX_PI) {
        return pi_take(m, at, try_only);
    }
    if (zdos_word_trylock(&m->lock)) {
        return 0;
    }
    uint32_t legacy = LEGACY_FREE;
    if (__atomic_compare_exchange_n(&m->lock, &legacy, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        return 0;
    }
    if (try_only) {
        return EBUSY;
    }
    return zdos_word_lock_until(&m->lock, at, CLOCK_REALTIME) ? 0 : ETIMEDOUT;
}

static void mutex_release(pthread_mutex_t *m) {
    if (m->type & MUTEX_PI) {
        zdos->tasks->mutex_unlock((int32_t)m->lock - 1);
    } else {
        zdos_word_unlock(&m->lock);
    }
}

static bool owner_kept(const pthread_mutex_t *m) {
    return m->type != PTHREAD_MUTEX_NORMAL; /* error-checking, recursive, PRIO_INHERIT */
}

static int mutex_take(pthread_mutex_t *m, const struct timespec *at, bool try_only) {
    if (!valid_time(at)) {
        return EINVAL;
    }
    if (!owner_kept(m)) {
        return mutex_acquire(m, at, try_only);
    }
    uint32_t me = zdos_self_id() + 1;
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) == me) {
        if ((m->type & MUTEX_TYPE) == PTHREAD_MUTEX_RECURSIVE) {
            if (m->count == INT_MAX) {
                return EAGAIN;
            }
            m->count++;
            return 0;
        }
        return try_only ? EBUSY : EDEADLK;
    }
    int e = mutex_acquire(m, at, try_only);
    if (e == 0) {
        __atomic_store_n(&m->owner, me, __ATOMIC_RELAXED);
        m->count = 1;
    }
    return e;
}

int pthread_mutex_lock(pthread_mutex_t *m) {
    if (m->type == PTHREAD_MUTEX_NORMAL && zdos_word_trylock(&m->lock)) {
        return 0;
    }
    return mutex_take(m, NULL, false);
}

int pthread_mutex_trylock(pthread_mutex_t *m) {
    return mutex_take(m, NULL, true);
}

int pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *abstime) {
    return mutex_take(m, abstime, false);
}

int pthread_mutex_unlock(pthread_mutex_t *m) {
    if (!owner_kept(m)) {
        uint32_t was = __atomic_exchange_n(&m->lock, 0, __ATOMIC_RELEASE);
        if (was == 2) {
            zdos_futex_wake(&m->lock, 1);
        }
        return was == 0 ? EPERM : 0;
    }
    if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) != zdos_self_id() + 1 || m->count == 0) {
        return EPERM;
    }
    if (--m->count > 0) {
        return 0;
    }
    __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    mutex_release(m);
    return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m) {
    if (m->type & MUTEX_PI) {
        if (m->count > 0) {
            return EBUSY;
        }
        if (m->lock != 0 && zdos != NULL) {
            zdos->tasks->mutex_destroy((int32_t)m->lock - 1);
        }
    } else if (m->lock != 0 && m->lock != LEGACY_FREE) {
        return EBUSY;
    }
    m->lock = 0;
    return 0;
}

/* CONDITIONS
   A sequence number as the futex word: a waiter reads it before letting
   the mutex go and sleeps while it is unchanged; signal and broadcast add
   1 and wake one or all. A waiter leaves the condition only after it has
   the mutex again (destroying it after a broadcast is safe once the
   waiters have their mutex). */

#define COND_MONOTONIC 1u

int pthread_condattr_init(pthread_condattr_t *a) {
    a->clock = CLOCK_REALTIME;
    return 0;
}

int pthread_condattr_destroy(pthread_condattr_t *a) {
    (void)a;
    return 0;
}

int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t clock) {
    if (clock != CLOCK_REALTIME && clock != CLOCK_MONOTONIC) {
        return EINVAL;
    }
    a->clock = clock;
    return 0;
}

int pthread_condattr_getclock(const pthread_condattr_t *a, clockid_t *clock) {
    *clock = a->clock;
    return 0;
}

int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) {
    c->seq = 0;
    c->waiters = a != NULL && a->clock == CLOCK_MONOTONIC ? COND_MONOTONIC : 0;
    return 0;
}

static int cond_wait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *at) {
    if (!valid_time(at)) {
        return EINVAL;
    }
    uint32_t me = 0;
    int count = 0;
    if (owner_kept(m)) {
        me = zdos_self_id() + 1;
        if (__atomic_load_n(&m->owner, __ATOMIC_RELAXED) != me) {
            return EPERM;
        }
        count = m->count; /* a recursive mutex goes all the way, and comes back so */
    }
    clockid_t clock = __atomic_fetch_add(&c->waiters, 2, __ATOMIC_SEQ_CST) & COND_MONOTONIC ? CLOCK_MONOTONIC
                                                                                          : CLOCK_REALTIME;
    uint32_t seq = __atomic_load_n(&c->seq, __ATOMIC_SEQ_CST);
    if (me != 0) {
        m->count = 0;
        __atomic_store_n(&m->owner, 0, __ATOMIC_RELAXED);
    }
    mutex_release(m);
    int e = 0;
    for (;;) {
        int32_t ms = -1;
        if (at != NULL && (ms = zdos_ms_until(clock, at)) == 0) {
            e = ETIMEDOUT;
            break;
        }
        uint32_t r = zdos_futex_wait(&c->seq, seq, ms);
        // Woken, a signal (a spurious wake),
        // or seq moved on: done; else wait on
        if (r == ZDOS_ERROR_INTERRUPTED || __atomic_load_n(&c->seq, __ATOMIC_ACQUIRE) != seq) {
            break;
        }
    }
    mutex_acquire(m, NULL, false);
    if (me != 0) {
        __atomic_store_n(&m->owner, me, __ATOMIC_RELAXED);
        m->count = count;
    }
    __atomic_fetch_sub(&c->waiters, 2, __ATOMIC_RELEASE);
    return e;
}

int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
    return cond_wait(c, m, NULL);
}

int pthread_cond_timedwait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *abstime) {
    return cond_wait(c, m, abstime);
}

static int cond_wake(pthread_cond_t *c, uint32_t count) {
    __atomic_fetch_add(&c->seq, 1, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&c->waiters, __ATOMIC_SEQ_CST) >= 2) {
        zdos_futex_wake(&c->seq, count);
    }
    return 0;
}

int pthread_cond_signal(pthread_cond_t *c) {
    return cond_wake(c, 1);
}

int pthread_cond_broadcast(pthread_cond_t *c) {
    return cond_wake(c, INT32_MAX);
}

int pthread_cond_destroy(pthread_cond_t *c) {
    (void)c;
    return 0;
}

/* READ-WRITE LOCKS: MANY READERS OR ONE WRITER, WRITERS FIRST
   state counts the readers or is RW_WRITER; who can't have it sleeps on
   seq, which moves on (waking all) whenever the lock comes free. */

#define RW_WRITER 0x80000000u

int pthread_rwlock_init(pthread_rwlock_t *l, const void *attr) {
    (void)attr;
    memset(l, 0, sizeof(*l));
    return 0;
}

static void rw_wake(pthread_rwlock_t *l) {
    __atomic_fetch_add(&l->seq, 1, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&l->sleepers, __ATOMIC_SEQ_CST) > 0) {
        zdos_futex_wake(&l->seq, INT32_MAX);
    }
}

static bool rw_blocked(pthread_rwlock_t *l, uint32_t s, bool write) {
    return write ? s != 0 : (s & RW_WRITER) != 0 || __atomic_load_n(&l->writers, __ATOMIC_SEQ_CST) > 0;
}

static int rw_take(pthread_rwlock_t *l, bool write, bool try_only, const struct timespec *at) {
    if (!valid_time(at)) {
        return EINVAL;
    }
    bool queued = false; /* a writer counted in writers */
    for (;;) {
        uint32_t s = __atomic_load_n(&l->state, __ATOMIC_RELAXED);
        if (s == LEGACY_FREE) { /* an older SDK's initializer */
            __atomic_compare_exchange_n(&l->state, &s, 0, false, __ATOMIC_RELAXED, __ATOMIC_RELAXED);
            continue;
        }
        if (!rw_blocked(l, s, write)) {
            if (!write && s == RW_WRITER - 1) {
                return EAGAIN;
            }
            if (__atomic_compare_exchange_n(&l->state, &s, write ? RW_WRITER : s + 1, false, __ATOMIC_ACQUIRE,
                                            __ATOMIC_RELAXED)) {
                if (queued) {
                    __atomic_fetch_sub(&l->writers, 1, __ATOMIC_SEQ_CST);
                }
                return 0;
            }
            continue;
        }
        if (try_only) {
            return EBUSY;
        }
        int32_t ms = -1;
        if (at != NULL && (ms = zdos_ms_until(CLOCK_REALTIME, at)) == 0) {
            break;
        }
        if (write && !queued) {
            __atomic_fetch_add(&l->writers, 1, __ATOMIC_SEQ_CST);
            queued = true;
            continue;
        }
        __atomic_fetch_add(&l->sleepers, 1, __ATOMIC_SEQ_CST);
        uint32_t seq = __atomic_load_n(&l->seq, __ATOMIC_SEQ_CST);
        if (rw_blocked(l, __atomic_load_n(&l->state, __ATOMIC_SEQ_CST), write)) {
            zdos_futex_wait(&l->seq, seq, ms);
        }
        __atomic_fetch_sub(&l->sleepers, 1, __ATOMIC_SEQ_CST);
    }
    if (queued) { /* readers held back by this writer may go */
        __atomic_fetch_sub(&l->writers, 1, __ATOMIC_SEQ_CST);
        rw_wake(l);
    }
    return ETIMEDOUT;
}

int pthread_rwlock_rdlock(pthread_rwlock_t *l) {
    return rw_take(l, false, false, NULL);
}

int pthread_rwlock_wrlock(pthread_rwlock_t *l) {
    return rw_take(l, true, false, NULL);
}

int pthread_rwlock_tryrdlock(pthread_rwlock_t *l) {
    return rw_take(l, false, true, NULL);
}

int pthread_rwlock_trywrlock(pthread_rwlock_t *l) {
    return rw_take(l, true, true, NULL);
}

int pthread_rwlock_timedrdlock(pthread_rwlock_t *l, const struct timespec *abstime) {
    return rw_take(l, false, false, abstime);
}

int pthread_rwlock_timedwrlock(pthread_rwlock_t *l, const struct timespec *abstime) {
    return rw_take(l, true, false, abstime);
}

int pthread_rwlock_unlock(pthread_rwlock_t *l) {
    uint32_t s = __atomic_load_n(&l->state, __ATOMIC_RELAXED);
    uint32_t n;
    do {
        if (s == 0 || s == LEGACY_FREE) {
            return EPERM;
        }
        n = s == RW_WRITER ? 0 : s - 1;
    } while (!__atomic_compare_exchange_n(&l->state, &s, n, false, __ATOMIC_SEQ_CST, __ATOMIC_RELAXED));
    if (n == 0) {
        rw_wake(l);
    }
    return 0;
}

int pthread_rwlock_destroy(pthread_rwlock_t *l) {
    uint32_t s = l->state;
    return s != 0 && s != LEGACY_FREE ? EBUSY : 0;
}

/* BARRIERS: THE LAST TO ARRIVE STARTS THE NEXT ROUND */

int pthread_barrier_init(pthread_barrier_t *b, const void *attr, unsigned count) {
    (void)attr;
    if (count == 0) {
        return EINVAL;
    }
    memset(b, 0, sizeof(*b));
    b->count = count;
    return 0;
}

int pthread_barrier_wait(pthread_barrier_t *b) {
    int r = 0;
    __atomic_fetch_add(&b->inside, 1, __ATOMIC_RELAXED);
    uint32_t round = __atomic_load_n(&b->round, __ATOMIC_ACQUIRE);
    if (__atomic_add_fetch(&b->waiting, 1, __ATOMIC_ACQ_REL) == b->count) {
        __atomic_store_n(&b->waiting, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&b->round, round + 1, __ATOMIC_RELEASE);
        zdos_futex_wake(&b->round, INT32_MAX);
        r = PTHREAD_BARRIER_SERIAL_THREAD;
    } else {
        while (__atomic_load_n(&b->round, __ATOMIC_ACQUIRE) == round) {
            zdos_futex_wait(&b->round, round, -1);
        }
    }
    __atomic_fetch_sub(&b->inside, 1, __ATOMIC_RELEASE);
    return r;
}

int pthread_barrier_destroy(pthread_barrier_t *b) {
    while (__atomic_load_n(&b->inside, __ATOMIC_ACQUIRE) != 0) { /* the last round's still leaving */
        sched_yield();
    }
    return 0;
}

/* SEMAPHORES: the value is the futex word, SEM_SLEEPERS set while
   someone sleeps on it; a post then clears it and wakes them all
   (sem_t stays 4 bytes) */

#define SEM_SLEEPERS 0x80000000u

int sem_init(sem_t *s, int shared, unsigned value) {
    (void)shared;
    if (value > SEM_VALUE_MAX) {
        return fail(EINVAL);
    }
    s->value = value;
    return 0;
}

int sem_destroy(sem_t *s) {
    (void)s;
    return 0;
}

static int sem_take(sem_t *s, bool try_only, const struct timespec *at) {
    if (!valid_time(at)) {
        return fail(EINVAL);
    }
    for (;;) {
        uint32_t v = __atomic_load_n(&s->value, __ATOMIC_RELAXED);
        if ((v & ~SEM_SLEEPERS) > 0) {
            if (__atomic_compare_exchange_n(&s->value, &v, v - 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
                return 0;
            }
            continue;
        }
        if (try_only) {
            return fail(EAGAIN);
        }
        int32_t ms = -1;
        if (at != NULL && (ms = zdos_ms_until(CLOCK_REALTIME, at)) == 0) {
            return fail(ETIMEDOUT);
        }
        if (v == 0 && !__atomic_compare_exchange_n(&s->value, &v, SEM_SLEEPERS, false, __ATOMIC_RELAXED,
                                                   __ATOMIC_RELAXED)) {
            continue;
        }
        if (zdos_futex_wait(&s->value, SEM_SLEEPERS, ms) == ZDOS_ERROR_INTERRUPTED) {
            return fail(EINTR);
        }
    }
}

int sem_wait(sem_t *s) {
    return sem_take(s, false, NULL);
}

int sem_trywait(sem_t *s) {
    return sem_take(s, true, NULL);
}

int sem_timedwait(sem_t *s, const struct timespec *abstime) {
    return sem_take(s, false, abstime);
}

int sem_post(sem_t *s) {
    uint32_t v = __atomic_load_n(&s->value, __ATOMIC_RELAXED);
    do {
        if ((v & ~SEM_SLEEPERS) >= SEM_VALUE_MAX) {
            return fail(EOVERFLOW);
        }
    } while (!__atomic_compare_exchange_n(&s->value, &v, (v & ~SEM_SLEEPERS) + 1, false, __ATOMIC_RELEASE,
                                          __ATOMIC_RELAXED));
    if (v & SEM_SLEEPERS) {
        zdos_futex_wake(&s->value, INT32_MAX);
    }
    return 0;
}

int sem_getvalue(sem_t *s, int *value) {
    *value = (int)(__atomic_load_n(&s->value, __ATOMIC_RELAXED) & ~SEM_SLEEPERS);
    return 0;
}

/* SCHEDULING: FIXED PRIORITIES 0-31 (HIGHER FIRST), FIFO OR ROUND ROBIN */

int sched_yield(void) {
    if (zdos != NULL) {
        zdos->tasks->yield();
    }
    return 0;
}

int sched_get_priority_min(int policy) {
    (void)policy;
    return 0;
}

int sched_get_priority_max(int policy) {
    (void)policy;
    return 31;
}

int sched_setparam(pid_t pid, const struct sched_param *p) {
    uint32_t id = pid == 0 ? zdos->tasks->id() : (uint32_t)pid;
    if (p->sched_priority < 0 || p->sched_priority > 31) {
        return fail(EINVAL);
    }
    return zdos->tasks->set_priority(id, (uint32_t)p->sched_priority) ? 0 : fail(ESRCH);
}

int sched_getparam(pid_t pid, struct sched_param *p) {
    uint32_t id = pid == 0 ? zdos->tasks->id() : (uint32_t)pid;
    int32_t prio = zdos->tasks->priority(id);
    if (prio < 0) {
        return fail(ESRCH);
    }
    p->sched_priority = prio;
    return 0;
}

int sched_setscheduler(pid_t pid, int policy, const struct sched_param *p) {
    int r = set_sched(pid == 0 ? zdos->tasks->id() : (uint32_t)pid, policy, p);
    return r == 0 ? 0 : fail(r);
}

int sched_getscheduler(pid_t pid) {
    int p = get_policy(pid == 0 ? zdos->tasks->id() : (uint32_t)pid);
    return p < 0 ? fail(ESRCH) : p;
}

int sched_setattr(pid_t pid, struct sched_attr *attr, unsigned int flags) {
    (void)flags;
    if (attr == NULL) {
        return fail(EINVAL);
    }
    uint32_t id = pid == 0 ? zdos->tasks->id() : (uint32_t)pid;
    if (attr->sched_policy != SCHED_DEADLINE) {
        struct sched_param p = {(int)attr->sched_priority};
        int r = set_sched(id, (int)attr->sched_policy, &p);
        return r == 0 ? 0 : fail(r);
    }
    if (zdos->tasks->set_deadline == NULL) {
        return fail(ENOSYS);
    }
    if (!zdos->tasks->set_deadline(id, attr->sched_runtime, attr->sched_deadline, attr->sched_period)) {
        int e = zdos_errno_from_last_error();
        return fail(e == EAGAIN ? EBUSY : e);
    }
    return 0;
}

int sched_getattr(pid_t pid, struct sched_attr *attr, unsigned int size, unsigned int flags) {
    (void)flags;
    if (attr == NULL || size < sizeof(struct sched_attr)) {
        return fail(EINVAL);
    }
    uint32_t id = pid == 0 ? zdos->tasks->id() : (uint32_t)pid;
    int p = get_policy(id);
    if (p < 0) {
        return fail(ESRCH);
    }
    memset(attr, 0, sizeof(*attr));
    attr->size = sizeof(*attr);
    attr->sched_policy = (unsigned int)p;
    zdos_deadline_setting d;
    if (p == SCHED_DEADLINE && zdos->tasks->deadline != NULL && zdos->tasks->deadline(id, &d)) {
        attr->sched_runtime = d.runtime;
        attr->sched_deadline = d.deadline;
        attr->sched_period = d.period;
    } else {
        attr->sched_priority = (unsigned int)zdos->tasks->priority(id);
    }
    return 0;
}

/* POLL AND SELECT */

int32_t zdos_fd_poll_handle(int fd); /* zdos_fs.c */

int poll(struct pollfd *fds, nfds_t n, int timeout) {
    if (zdos == NULL) {
        return fail(ENOSYS);
    }
    zdos_poll_fd *k = malloc(sizeof(*k) * (n + 1));
    int *at = malloc(sizeof(int) * (n + 1));
    if (k == NULL || at == NULL) {
        free(k);
        free(at);
        return fail(ENOMEM);
    }
    int ready = 0;
    uint32_t count = 0;
    for (nfds_t i = 0; i < n; i++) {
        fds[i].revents = 0;
        if (fds[i].fd < 0) {
            continue;
        }
        int32_t h = zdos_fd_poll_handle(fds[i].fd);
        if (h == -100) {
            fds[i].revents = POLLNVAL;
            ready++;
        } else if (h == -3) {
            fds[i].revents = fds[i].events & (POLLIN | POLLOUT);
            if (fds[i].revents) {
                ready++;
            }
        } else {
            k[count] = (zdos_poll_fd){h, (uint16_t)fds[i].events, 0};
            at[count++] = (int)i;
        }
    }
    if (count > 0) {
        int32_t r = zdos->files->poll(k, count, ready > 0 ? 0 : timeout);
        if (r < 0) {
            free(k);
            free(at);
            return fail_last();
        }
        for (uint32_t j = 0; j < count; j++) {
            fds[at[j]].revents = (short)k[j].revents;
            if (k[j].revents) {
                ready++;
            }
        }
    } else if (ready == 0 && timeout != 0) {
        // Nothing to look at: a sleep
        uint32_t left = zdos->time->nap(timeout < 0 ? 0xFFFFFFFFu : (uint32_t)timeout);
        if (left != 0) {
            free(k);
            free(at);
            return fail(EINTR);
        }
    }
    free(k);
    free(at);
    return ready;
}

int select(int nfds, fd_set *rd, fd_set *wr, fd_set *ex, struct timeval *tv) {
    if (nfds < 0 || nfds > FD_SETSIZE) {
        return fail(EINVAL);
    }
    struct pollfd p[FD_SETSIZE];
    int n = 0;
    for (int fd = 0; fd < nfds; fd++) {
        short ev = 0;
        if (rd != NULL && FD_ISSET(fd, rd)) {
            ev |= POLLIN;
        }
        if (wr != NULL && FD_ISSET(fd, wr)) {
            ev |= POLLOUT;
        }
        if (ex != NULL && FD_ISSET(fd, ex)) {
            ev |= POLLPRI;
        }
        if (ev != 0) {
            p[n++] = (struct pollfd){fd, ev, 0};
        }
    }
    int timeout = tv == NULL ? -1 : (int)(tv->tv_sec * 1000 + (tv->tv_usec + 999) / 1000);
    int r = poll(p, (nfds_t)n, timeout);
    if (r < 0) {
        return -1;
    }
    if (rd != NULL) {
        FD_ZERO(rd);
    }
    if (wr != NULL) {
        FD_ZERO(wr);
    }
    if (ex != NULL) {
        FD_ZERO(ex);
    }
    int bits = 0;
    for (int i = 0; i < n; i++) {
        short re = p[i].revents;
        if (re & POLLNVAL) {
            return fail(EBADF);
        }
        if (rd != NULL && (re & (POLLIN | POLLHUP | POLLERR))) {
            FD_SET(p[i].fd, rd);
            bits++;
        }
        if (wr != NULL && (re & (POLLOUT | POLLERR))) {
            FD_SET(p[i].fd, wr);
            bits++;
        }
    }
    if (tv != NULL) {
        tv->tv_sec = 0;
        tv->tv_usec = 0;
    }
    return bits;
}

/* TERMINALS
   One terminal: the keyboard and the screen. ICANON on (the default):
   stdin reads lines with zdos_fs.c's line editor. Off: keys as bytes, as a
   terminal sends them (arrows as ESC [ A ..., Enter as CR, or NL with
   ICRNL, Backspace as DEL), at least VMIN of them, with VTIME tenths of a
   second between them; ECHO shows the printable ones. ISIG off: Ctrl+C is
   a key (byte 3). */

static struct termios tty = {
    .c_iflag = ICRNL,
    .c_oflag = OPOST | ONLCR,
    .c_cflag = CS8 | CREAD,
    .c_lflag = ICANON | ECHO | ECHOE | ISIG | IEXTEN,
    .c_cc = {[VINTR] = 3, [VEOF] = 4, [VERASE] = 127, [VKILL] = 21, [VMIN] = 1, [VTIME] = 0},
};

static unsigned char key_bytes[8];
static size_t key_len, key_pos;

static bool is_tty(int fd) {
    return isatty(fd) != 0;
}

int tcgetattr(int fd, struct termios *t) {
    if (!is_tty(fd)) {
        return fail(ENOTTY);
    }
    *t = tty;
    return 0;
}

int tcsetattr(int fd, int actions, const struct termios *t) {
    (void)actions;
    if (!is_tty(fd)) {
        return fail(ENOTTY);
    }
    bool isig = (tty.c_lflag & ISIG) != 0;
    tty = *t;
    if (((tty.c_lflag & ISIG) != 0) != isig && zdos != NULL) {
        if (tty.c_lflag & ISIG) {
            zdos_signals_sync(); /* Ctrl+C as SIGINT wants it */
        } else {
            zdos->programs->set_ctrl_c(true); /* a key */
        }
    }
    return 0;
}

void cfmakeraw(struct termios *t) {
    t->c_iflag &= ~(tcflag_t)(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    t->c_oflag &= ~(tcflag_t)OPOST;
    t->c_lflag &= ~(tcflag_t)(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    t->c_cflag &= ~(tcflag_t)(CSIZE | PARENB);
    t->c_cflag |= CS8;
    t->c_cc[VMIN] = 1;
    t->c_cc[VTIME] = 0;
}

speed_t cfgetispeed(const struct termios *t) {
    (void)t;
    return B38400;
}

speed_t cfgetospeed(const struct termios *t) {
    (void)t;
    return B38400;
}

int cfsetispeed(struct termios *t, speed_t s) {
    (void)t;
    (void)s;
    return 0;
}

int cfsetospeed(struct termios *t, speed_t s) {
    (void)t;
    (void)s;
    return 0;
}

int tcflush(int fd, int queue) {
    (void)queue;
    if (!is_tty(fd)) {
        return fail(ENOTTY);
    }
    key_len = key_pos = 0;
    zdos_key k;
    while (zdos != NULL && zdos->console->poll_key(&k)) {
        /* dropped */
    }
    return 0;
}

int tcdrain(int fd) {
    return is_tty(fd) ? 0 : fail(ENOTTY);
}

int tcsendbreak(int fd, int duration) {
    (void)duration;
    return is_tty(fd) ? 0 : fail(ENOTTY);
}

int ioctl(int fd, unsigned long request, ...) {
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (request == TIOCGWINSZ) {
        if (!is_tty(fd) || zdos == NULL) {
            return fail(ENOTTY);
        }
        zdos_pos size = zdos->console->screen_size();
        struct winsize *w = arg;
        w->ws_row = (unsigned short)size.row;
        w->ws_col = (unsigned short)size.col;
        w->ws_xpixel = 0;
        w->ws_ypixel = 0;
        return 0;
    }
    if (request == FIONREAD) {
        *(int *)arg = (int)(key_len - key_pos);
        return 0;
    }
    return fail(EINVAL);
}

// A key as a terminal sends it, into key_bytes
static void key_to_bytes(zdos_key k) {
    key_len = key_pos = 0;
    static const char *const seq[] = {
        [ZDOS_SCAN_UP] = "\x1b[A", [ZDOS_SCAN_DOWN] = "\x1b[B", [ZDOS_SCAN_RIGHT] = "\x1b[C",
        [ZDOS_SCAN_LEFT] = "\x1b[D", [ZDOS_SCAN_HOME] = "\x1b[H", [ZDOS_SCAN_END] = "\x1b[F",
        [ZDOS_SCAN_INSERT] = "\x1b[2~", [ZDOS_SCAN_DELETE] = "\x1b[3~", [ZDOS_SCAN_PAGE_UP] = "\x1b[5~",
        [ZDOS_SCAN_PAGE_DOWN] = "\x1b[6~", [ZDOS_SCAN_F1] = "\x1bOP", [ZDOS_SCAN_F1 + 1] = "\x1bOQ",
        [ZDOS_SCAN_F1 + 2] = "\x1bOR", [ZDOS_SCAN_F1 + 3] = "\x1bOS",
    };
    uint32_t c = k.char_;
    if (c == 0) {
        if (k.scan == ZDOS_SCAN_ESC) {
            key_bytes[key_len++] = 0x1b;
        } else if (k.scan < sizeof(seq) / sizeof(seq[0]) && seq[k.scan] != NULL) {
            for (const char *s = seq[k.scan]; *s; s++) {
                key_bytes[key_len++] = (unsigned char)*s;
            }
        }
        return;
    }
    if (c == '\r' && (tty.c_iflag & ICRNL)) {
        c = '\n';
    } else if (c == 8) {
        c = 127; /* Backspace */
    }
    if (c < 0x80) {
        key_bytes[key_len++] = (unsigned char)c;
    } else if (c < 0x800) {
        key_bytes[key_len++] = (unsigned char)(0xC0 | (c >> 6));
        key_bytes[key_len++] = (unsigned char)(0x80 | (c & 0x3F));
    } else {
        key_bytes[key_len++] = (unsigned char)(0xE0 | (c >> 12));
        key_bytes[key_len++] = (unsigned char)(0x80 | ((c >> 6) & 0x3F));
        key_bytes[key_len++] = (unsigned char)(0x80 | (c & 0x3F));
    }
    if ((tty.c_lflag & ECHO) && c >= 0x20 && c != 127) {
        zdos->console->print((const char *)key_bytes, key_len);
    }
}

// Waits up to ms (-1: no limit) for a key; false if none came
static bool next_key(int32_t ms) {
    zdos_key k;
    if (ms < 0) {
        k = zdos->console->read_key();
    } else {
        zdos_poll_fd p = {ZDOS_POLL_STDIN, ZDOS_POLLIN, 0};
        if (zdos->files->poll(&p, 1, ms) <= 0 || !zdos->console->poll_key(&k)) {
            return false;
        }
    }
    key_to_bytes(k);
    return true;
}

static ssize_t tty_read(void *buf, size_t count) {
    if (tty.c_lflag & ICANON) {
        return -2;
    }
    unsigned char *out = buf;
    size_t vmin = tty.c_cc[VMIN];
    int32_t vtime = (int32_t)tty.c_cc[VTIME] * 100;
    size_t n = 0;
    while (n < count) {
        if (key_pos < key_len) {
            out[n++] = key_bytes[key_pos++];
            continue;
        }
        if (n > 0 && n >= vmin) {
            break;
        }
        int32_t wait = -1;
        if (vmin == 0) {
            wait = vtime; /* 0: only what is there */
        } else if (n > 0 && vtime > 0) {
            wait = vtime; /* between bytes */
        }
        if (!next_key(wait)) {
            break;
        }
    }
    return (ssize_t)n;
}

// What zdos_fs.c and zdos_libc.c call through hooks (set before main)
__attribute__((constructor)) static void posix_hooks(void) {
    zdos_tty_read_hook = tty_read;
    zdos_vfork_exit_hook = vfork_exited;
}
