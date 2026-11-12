/* POSIXTEST: tests zdos_posix.c and ZDOS's tasks, threads, signals and
 * pipes under it; what an edition lacks is skipped.
 *   POSIXTEST net [HOST] | net -L [ADDRESS]: the C library's sockets
 * With another word it is a small tool for its own children: echo, cat,
 * yes, head, exit, sleep, spin, sigwait, threadexit, leakthread, getenv. */
#include "zdos.h"
#include <arpa/inet.h>
#include <errno.h>
#include <grp.h>
#include <iconv.h>
#include <langinfo.h>
#include <libgen.h>
#include <math.h>
#include <netdb.h>
#include <search.h>
#include <sys/resource.h>
#include <sys/uio.h>
#include <threads.h>
#include <wchar.h>
#include <wctype.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <regex.h>
#include <pwd.h>
#include <sched.h>
#include <setjmp.h>
#include <semaphore.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

static int passed, failed, skipped, number;

static void check(int ok, const char *what, const char *detail) {
    number++;
    if (ok) {
        passed++;
        printf("ok %d - %s\n", number, what);
    } else {
        failed++;
        printf("not ok %d - %s (%s)\n", number, what, detail ? detail : "");
    }
}

static void skip_because(const char *what, const char *why) {
    number++;
    skipped++;
    printf("ok %d - %s # SKIP %s\n", number, what, why);
}

static void skip(const char *what) {
    skip_because(what, "no tasks here");
}

// BIOS has no paging (address 0 is memory), UEFI turns no CPU fault into
// a signal, and both switch tasks only inside ZDOS. Without PLATFORM
// (an older ZDOS) 32-bit x86 means BIOS.
static int platform_is(const char *name) {
    const char *p = getenv("PLATFORM");
    return p != NULL && strcmp(p, name) == 0;
}
#if defined(__i386__)
#define on_bios 1
#else
#define on_bios platform_is("BIOS")
#endif
#define on_uefi platform_is("UEFI")

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* THE TOOLS */

static volatile sig_atomic_t sigwait_got;

static void handler(int sig) {
    sigwait_got = sig;
}

static void *exiter(void *arg);
static void *spinner(void *arg);

// UEFI and BIOS switch tasks only inside ZDOS: their spinners give the
// CPU up, else nothing else ever runs.
static void spin_turn(void) {
    static int cooperative = -1;
    if (cooperative < 0) {
        const char *p = getenv("PLATFORM");
        cooperative = p != NULL ? strcmp(p, "METAL") != 0 : 1;
    }
    if (cooperative) sched_yield();
}

// null (read address 0), write (to address 16), ill (an invalid
// instruction), fpe (integer division by zero; ARM64 gives 0).
static volatile int zero_divisor;

static void fault(const char *kind) {
    if (strcmp(kind, "write") == 0) {
        *(volatile int *)16 = 1;
    } else if (strcmp(kind, "ill") == 0) {
        __builtin_trap();
    } else if (strcmp(kind, "fpe") == 0) {
        volatile int x = 7 / zero_divisor;
        (void)x;
    } else {
        volatile int x = *(volatile int *)0;
        (void)x;
    }
}

static int tool(int argc, char **argv) {
    const char *w = argv[1];
    if (strcmp(w, "echo") == 0) {
        for (int i = 2; i < argc; i++) {
            printf("%s%s", argv[i], i + 1 < argc ? " " : "\n");
        }
        return 0;
    }
    if (strcmp(w, "cat") == 0) {
        char buf[256];
        ssize_t n;
        while ((n = read(0, buf, sizeof(buf))) > 0) {
            write(1, buf, (size_t)n);
        }
        return 0;
    }
    if (strcmp(w, "yes") == 0) {
        for (;;) {
            write(1, "y\n", 2);
        }
    }
    if (strcmp(w, "head") == 0) {
        int lines = argc > 2 ? atoi(argv[2]) : 10;
        char c;
        while (lines > 0 && read(0, &c, 1) == 1) {
            write(1, &c, 1);
            if (c == '\n') {
                lines--;
            }
        }
        return 0;
    }
    if (strcmp(w, "exit") == 0) {
        return argc > 2 ? atoi(argv[2]) : 0;
    }
    if (strcmp(w, "getenv") == 0) {
        for (int i = 2; i < argc; i++) {
            const char *v = getenv(argv[i]);
            printf("%s=%s%s", argv[i], v != NULL ? v : "-", i + 1 < argc ? " " : "\n");
        }
        return 0;
    }
    if (strcmp(w, "sleep") == 0) {
        usleep((useconds_t)(argc > 2 ? atoi(argv[2]) : 100) * 1000);
        return 0;
    }
    if (strcmp(w, "spin") == 0) {
        volatile unsigned long x = 0;
        for (;;) {
            x++;
            spin_turn();
        }
    }
    if (strcmp(w, "sigwait") == 0) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = handler;
        sigaction(SIGUSR1, &sa, NULL);
        // Blocked until sigsuspend: one coming between the check
        // and the wait would otherwise be missed (pause forever)
        sigset_t usr1, old;
        sigemptyset(&usr1);
        sigaddset(&usr1, SIGUSR1);
        sigprocmask(SIG_BLOCK, &usr1, &old);
        printf("ready\n");
        while (!sigwait_got) {
            sigsuspend(&old);
        }
        printf("got %d\n", (int)sigwait_got);
        return 0;
    }
    if (strcmp(w, "threadexit") == 0) {
        pthread_t t;
        pthread_create(&t, NULL, exiter, NULL);
        pthread_join(t, NULL);
        return 1; /* not reached: the thread's exit ends the program */
    }
    if (strcmp(w, "leakthread") == 0) {
        pthread_t t;
        pthread_create(&t, NULL, spinner, NULL);
        usleep(20000);
        return 3;
    }
    // Not caught: ZDOS says what happened and ends the program:
    if (strcmp(w, "crash") == 0) {
        const char *kind = argc > 2 ? argv[2] : "null";
        printf("crashing: %s\n", kind);
        fflush(stdout);
        fault(kind);
        printf("crash: still here\n");
        return 1;
    }
    // /dev/tty is the keyboard, also when stdin is redirected:
    if (strcmp(w, "ttyread") == 0) {
        int t = open("/dev/tty", O_RDWR);
        char buf[80] = {0};
        write(t, "name? ", 6);
        ssize_t n = read(t, buf, sizeof(buf) - 1);
        printf("tty gave %d: %s", (int)n, buf);
        printf("isatty %d\n", isatty(t));
        close(t);
        return 0;
    }
    if (strcmp(w, "devstd") == 0) {
        int o = open("/dev/stdout", O_WRONLY);
        int e = open("/dev/stderr", O_WRONLY);
        write(o, "to /dev/stdout\n", 15);
        write(e, "to /dev/stderr\n", 15);
        close(o);
        close(e);
        return 0;
    }
    // Another task's priority (ZDOS's own tasks only, unless root):
    if (strcmp(w, "prio") == 0) {
        int id = argc > 2 ? atoi(argv[2]) : 1;
        int r = setpriority(PRIO_PROCESS, (id_t)id, argc > 3 ? atoi(argv[3]) : 5);
        printf("setpriority(%d): %s\n", id, r == 0 ? "done" : strerror(errno));
        return r == 0 ? 0 : 1;
    }
    // Turning off through ZDOS directly, as any program could:
    if (strcmp(w, "halt") == 0) {
        printf("calling shutdown\n");
        fflush(stdout);
        zdos->system->shutdown();
        return 0;
    }
    // Printed after a while: background output while something is typed:
    if (strcmp(w, "later") == 0) {
        usleep((useconds_t)(argc > 2 ? atoi(argv[2]) : 1000) * 1000);
        printf("%s\n", argc > 3 ? argv[3] : "later");
        return 0;
    }
    // A line typed (the C library's line reader), shown back:
    if (strcmp(w, "readline") == 0) {
        char buf[200];
        printf("type: ");
        fflush(stdout);
        if (fgets(buf, sizeof(buf), stdin) != NULL) {
            printf("read: %s", buf);
        }
        return 0;
    }
    fprintf(stderr, "posixtest: unknown tool %s\n", w);
    return 2;
}

static void *exiter(void *arg) {
    (void)arg;
    usleep(20000);
    exit(9);
}

static void *spinner(void *arg) {
    (void)arg;
    volatile unsigned long x = 0;
    for (;;) {
        x++;
        spin_turn();
    }
}

/* HELPERS */

// stdin from in_fd, stdout to out_fd (-1: as ours), envp's variables (NULL:
// the global ones).
static pid_t start_env(const char *const words[], int in_fd, int out_fd, char *const envp[]) {
    char *argv[16];
    int n = 0;
    argv[n++] = "posixtest";
    for (int i = 0; words[i] != NULL && n < 15; i++) {
        argv[n++] = (char *)words[i];
    }
    argv[n] = NULL;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (in_fd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, in_fd, 0);
    }
    if (out_fd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, out_fd, 1);
    }
    pid_t pid = -1;
    int e = posix_spawnp(&pid, "posixtest", &fa, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    if (e != 0) {
        errno = e;
        return -1;
    }
    return pid;
}

static pid_t start(const char *const words[], int in_fd, int out_fd) {
    return start_env(words, in_fd, out_fd, NULL);
}

// Until its end, 0-terminated.
static size_t read_all(int fd, char *buf, size_t size) {
    size_t n = 0;
    ssize_t r;
    while (n + 1 < size && (r = read(fd, buf + n, size - 1 - n)) > 0) {
        n += (size_t)r;
    }
    buf[n] = '\0';
    return n;
}

static char detail[128];

static const char *status_text(int st) {
    if (WIFSIGNALED(st)) {
        snprintf(detail, sizeof(detail), "signal %d", WTERMSIG(st));
    } else {
        snprintf(detail, sizeof(detail), "exit %d", WEXITSTATUS(st));
    }
    return detail;
}

/* TESTS THAT NEED NO OTHER TASK */

static void test_basics(void) {
    check(getpid() >= 1, "getpid", NULL);
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    usleep(20000);
    clock_gettime(CLOCK_MONOTONIC, &b);
    long ms = (long)(b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000;
    snprintf(detail, sizeof(detail), "%ld ms", ms);
    check(ms >= 19 && ms < 200, "usleep 20 ms and CLOCK_MONOTONIC", detail);
    check(sysconf(_SC_NPROCESSORS_ONLN) >= 1, "sysconf cores", NULL);

    // Users: root is there; the current one is USER:
    struct passwd *root = getpwnam("root");
    struct passwd *me = getpwuid(getuid());
    check(root != NULL && root->pw_uid == 0 && root->pw_dir != NULL && me != NULL && strcmp(me->pw_name, getlogin()) == 0,
          "getpwnam, getpwuid(getuid())", me != NULL ? me->pw_name : "none");

    // POSIX's own paths: /dev/null, /tmp:
    int n = open("/dev/null", O_RDWR);
    char c;
    check(n >= 0 && write(n, "gone", 4) == 4 && read(n, &c, 1) == 0, "/dev/null: writes vanish, reads end", strerror(errno));
    struct stat st;
    check(stat("/dev/null", &st) == 0 && S_ISCHR(st.st_mode), "/dev/null is a character device", NULL);
    close(n);
    check(unlink("/dev/null") == -1, "/dev/null can't be deleted", NULL);
    FILE *t = fopen("/tmp/POSIXT.TMP", "w");
    if (t != NULL) {
        fputs("tmp", t);
        fclose(t);
    }
    char where[300];
    const char *temp = getenv("TEMP");
    snprintf(where, sizeof(where), "%s\\POSIXT.TMP", temp ? temp : "C:\\TEMP");
    check(t != NULL && access(where, F_OK) == 0, "/tmp/x is in TEMP", where);
    unlink("/tmp/POSIXT.TMP");
}

// Through an open descriptor (files->fset_time).
static void test_file_times(void) {
    const char *name = "/tmp/POSIXFT.TMP";
    int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0644);
    write(fd, "times", 5);
    struct tm tm = {.tm_year = 101, .tm_mon = 1, .tm_mday = 3, .tm_hour = 4, .tm_min = 5, .tm_sec = 6, .tm_isdst = -1};
    time_t t = mktime(&tm);
    struct timespec ts[2] = {{t, 0}, {t, 0}};
    errno = 0;
    int r = futimens(fd, ts);
    if (r != 0 && errno == ENOSYS) {
        skip_because("futimens, futimes", "this ZDOS has no files->fset_time");
        close(fd);
        unlink(name);
        return;
    }
    struct stat st;
    memset(&st, 0, sizeof(st));
    fstat(fd, &st);
    snprintf(detail, sizeof(detail), "r=%d errno=%d mtime %lld, wanted %lld", r, errno, (long long)st.st_mtime, (long long)t);
    check(r == 0 && st.st_mtime == t, "futimens on a file just written", detail);
    struct timeval tv[2] = {{t + 3600, 0}, {t + 3600, 0}};
    r = futimes(fd, tv);
    ts[1].tv_nsec = UTIME_OMIT;
    int r2 = futimens(fd, ts);
    close(fd);
    memset(&st, 0, sizeof(st));
    stat(name, &st);
    snprintf(detail, sizeof(detail), "r=%d,%d mtime %lld, wanted %lld", r, r2, (long long)st.st_mtime, (long long)t + 3600);
    check(r == 0 && r2 == 0 && st.st_mtime == t + 3600, "futimes, UTIME_OMIT, then close: the time stays", detail);
    fd = open(name, O_RDONLY);
    r = futimens(fd, NULL);
    memset(&st, 0, sizeof(st));
    fstat(fd, &st);
    close(fd);
    long long age = (long long)(time(NULL) - st.st_mtime);
    snprintf(detail, sizeof(detail), "r=%d errno=%d age %lld s", r, errno, age);
    // Root may on any; others own the file (ext2, Minix) or not (FAT):
    check((r == 0 && age >= -2 && age <= 5) || (r == -1 && errno == EACCES && getuid() != 0),
          "futimens(NULL) on a read-only descriptor: now", detail);
    unlink(name);
    int p[2];
    pipe(p);
    check(futimens(p[0], NULL) == -1, "futimens on a pipe fails", NULL);
    close(p[0]);
    close(p[1]);
}

static void test_pipe_alone(void) {
    int p[2];
    check(pipe(p) == 0, "pipe", strerror(errno));
    check(write(p[1], "hello", 5) == 5, "write to pipe", strerror(errno));
    char buf[16] = {0};
    check(read(p[0], buf, sizeof(buf)) == 5 && memcmp(buf, "hello", 5) == 0, "read from pipe", buf);
    struct stat st;
    check(fstat(p[0], &st) == 0 && S_ISFIFO(st.st_mode), "fstat: pipe is a FIFO", NULL);

    struct pollfd pf = {p[0], POLLIN, 0};
    long t0 = now_ms();
    int r = poll(&pf, 1, 50);
    long waited = now_ms() - t0;
    snprintf(detail, sizeof(detail), "r=%d after %ld ms", r, waited);
    check(r == 0 && waited >= 45, "poll: empty pipe times out", detail);
    write(p[1], "x", 1);
    r = poll(&pf, 1, 1000);
    check(r == 1 && (pf.revents & POLLIN), "poll: data in the pipe", NULL);

    fd_set rs;
    FD_ZERO(&rs);
    FD_SET(p[0], &rs);
    struct timeval tv = {0, 0};
    check(select(p[0] + 1, &rs, NULL, NULL, &tv) == 1 && FD_ISSET(p[0], &rs), "select: pipe readable", NULL);
    read(p[0], buf, 1);

    int fl = fcntl(p[0], F_GETFL);
    fcntl(p[0], F_SETFL, fl | O_NONBLOCK);
    errno = 0;
    r = (int)read(p[0], buf, 1);
    check(r == -1 && errno == EAGAIN, "O_NONBLOCK read of an empty pipe: EAGAIN", strerror(errno));
    fcntl(p[0], F_SETFL, fl);

    close(p[1]);
    r = poll(&pf, 1, 0);
    check(r == 1 && (pf.revents & POLLHUP), "poll: writer gone, POLLHUP", NULL);
    check(read(p[0], buf, 1) == 0, "read: end of pipe", NULL);
    close(p[0]);

    // No reader: EPIPE (SIGPIPE ignored, else it would end us):
    pipe(p);
    close(p[0]);
    signal(SIGPIPE, SIG_IGN);
    errno = 0;
    r = (int)write(p[1], "x", 1);
    check(r == -1 && errno == EPIPE, "write with no reader: EPIPE", strerror(errno));
    signal(SIGPIPE, SIG_DFL);
    close(p[1]);
}

static void test_dup(void) {
    const char *name = "/tmp/POSIXT2.TMP"; /* TEMP: writable for any user */
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    check(fd >= 3, "open a file", strerror(errno));
    int saved = dup(1);
    check(saved >= 3, "dup(1)", strerror(errno));
    int moved = dup2(fd, 1);
    printf("to the file\n");
    fflush(stdout);
    dup2(saved, 1);
    check(moved == 1, "dup2(file, 1)", strerror(errno));
    close(saved);
    close(fd);
    char buf[64] = {0};
    fd = open(name, O_RDONLY);
    read_all(fd, buf, sizeof(buf));
    close(fd);
    check(strcmp(buf, "to the file\n") == 0, "stdout into a file and back", buf);
    int d = fcntl(0, F_DUPFD, 10);
    check(d >= 10, "fcntl F_DUPFD", NULL);
    close(d);
    unlink(name);
}

// Anonymous memory, a file read through memory, a shared mapping
// written back, munmap of parts.
static void test_mmap(void) {
    size_t len = 3 * 4096 + 100;
    unsigned char *a = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    int zero = a != MAP_FAILED && ((uintptr_t)a & 4095) == 0;
    for (size_t i = 0; zero && i < len; i++) {
        zero = a[i] == 0;
    }
    check(zero, "mmap anonymous: page-aligned, zeroed", strerror(errno));
    if (a != MAP_FAILED) {
        memset(a, 0x5A, len);
        check(madvise(a, 4096, MADV_DONTNEED) == 0 && a[0] == 0 && a[4096] == 0x5A, "madvise DONTNEED zeroes", NULL);
        check(munmap(a, 4096) == 0 && munmap(a + 4096, len - 4096) == 0, "munmap in two parts", strerror(errno));
    }

    // 5000 bytes, mapped from page 1 (904 bytes, the rest zeroes):
    const char *name = "/tmp/MMAPTEST.BIN";
    int fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0666);
    char data[5000];
    for (int i = 0; i < 5000; i++) {
        data[i] = (char)('a' + i % 26);
    }
    check(fd >= 0 && write(fd, data, sizeof(data)) == 5000, "a file to map", strerror(errno));
    lseek(fd, 10, SEEK_SET);
    char *p = mmap(NULL, 8192, PROT_READ, MAP_PRIVATE, fd, 4096);
    check(p != MAP_FAILED && memcmp(p, data + 4096, 904) == 0 && p[904] == 0 && p[8191] == 0, "mmap of a file's part", strerror(errno));
    check(lseek(fd, 0, SEEK_CUR) == 10, "mmap keeps the file's position", NULL);
    check(mmap(NULL, 100, PROT_READ, MAP_PRIVATE, fd, 100) == MAP_FAILED && errno == EINVAL, "an offset not on a page: EINVAL", NULL);
    if (p != MAP_FAILED) {
        munmap(p, 8192);
    }

    // Shared and writable: changes reach the file at msync and munmap,
    // also after close; the file doesn't grow:
    char *s = mmap(NULL, 5000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    check(s != MAP_FAILED, "mmap shared, writable", strerror(errno));
    if (s != MAP_FAILED) {
        memcpy(s, "HELLO", 5);
        check(msync(s, 4096, MS_SYNC) == 0, "msync", strerror(errno));
        fd = open(name, O_RDONLY);
        char buf[8] = {0};
        check(read(fd, buf, 5) == 5 && memcmp(buf, "HELLO", 5) == 0, "msync wrote to the file", buf);
        close(fd);
        memcpy(s + 4990, "END", 3);
        s[6000] = 'X'; /* past the file's end: not written */
        check(munmap(s, 5000) == 0, "munmap of a shared mapping", strerror(errno));
        struct stat st;
        fd = open(name, O_RDONLY);
        lseek(fd, 4990, SEEK_SET);
        check(read(fd, buf, 3) == 3 && memcmp(buf, "END", 3) == 0 && fstat(fd, &st) == 0 && st.st_size == 5000,
              "munmap wrote back, the file's size kept", buf);
        close(fd);
    }
    unlink(name);
}

// Caught by a handler that leaves by siglongjmp (twice: the mask is
// restored), and one not caught in another program.
static sigjmp_buf fault_jump;
static volatile sig_atomic_t fault_sig;

static void fault_handler(int sig) {
    fault_sig = sig;
    siglongjmp(fault_jump, 1);
}

static int caught(const char *kind) {
    fault_sig = 0;
    if (sigsetjmp(fault_jump, 1) == 0) {
        fault(kind);
    }
    return fault_sig;
}

static void test_faults(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = fault_handler;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    if (on_uefi) {
        const char *why = "UEFI: CPU faults aren't signals";
        skip_because("reading address 0: SIGSEGV caught", why);
        skip_because("writing near 0: SIGSEGV again (mask restored)", why);
        skip_because("an invalid instruction: SIGILL or SIGTRAP", why);
#if defined(__x86_64__) || defined(__i386__)
        skip_because("division by zero: SIGFPE", why);
#endif
        skip_because("a child's uncaught CPU fault ends it", why);
        sa.sa_handler = SIG_DFL;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGILL, &sa, NULL);
        sigaction(SIGTRAP, &sa, NULL);
        sigaction(SIGFPE, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        return;
    }
    if (on_bios) {
        skip_because("reading address 0: SIGSEGV caught", "BIOS: no paging");
        skip_because("writing near 0: SIGSEGV again (mask restored)", "BIOS: no paging");
    } else {
        check(caught("null") == SIGSEGV, "reading address 0: SIGSEGV caught", NULL);
        check(caught("write") == SIGSEGV, "writing near 0: SIGSEGV again (mask restored)", NULL);
    }
    int ill = caught("ill");
    check(ill == SIGILL || ill == SIGTRAP, "an invalid instruction: SIGILL or SIGTRAP", NULL);
#if defined(__x86_64__) || defined(__i386__)
    check(caught("fpe") == SIGFPE, "division by zero: SIGFPE", NULL);
#endif
    sa.sa_handler = SIG_DFL;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);

    // Not caught, in a child: it ends by the signal, its message to stderr:
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    // BIOS: address 0 doesn't fault; an invalid instruction instead:
    char *cargv[] = {"posixtest", "crash", on_bios ? "ill" : "null", NULL};
    const int child_sig = on_bios ? SIGILL : SIGSEGV;
    pid_t pid;
    int st = 0;
    int ok = posix_spawnp(&pid, "posixtest", &fa, NULL, cargv, NULL) == 0 && waitpid(pid, &st, 0) == pid;
    posix_spawn_file_actions_destroy(&fa);
    check(ok && ((WIFSIGNALED(st) && WTERMSIG(st) == child_sig) || (WIFEXITED(st) && WEXITSTATUS(st) == 128 + child_sig)),
          "a child's uncaught CPU fault ends it", status_text(st));
}

// Headers for ported programs: wide characters, libgen, iconv, network
// addresses, search trees, aligned memory, C11 threads ...
static int compare_ints(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

static int c11_thread(void *arg) {
    return *(int *)arg + 1;
}

static void test_headers(int tasks) {
    wchar_t w[16];
    size_t n = mbstowcs(w, "a\xC3\xA9\xE4\xB8\xAD\xF0\x9F\x98\x80", 16);
    check(n == 4 && w[1] == 0xE9 && w[2] == 0x4E2D && w[3] == 0x1F600, "mbstowcs: UTF-8 to code points", NULL);
    char back[32];
    check(wcstombs(back, w, sizeof(back)) == 10 && strcmp(back, "a\xC3\xA9\xE4\xB8\xAD\xF0\x9F\x98\x80") == 0, "wcstombs back", NULL);
    check(wcwidth(L'a') == 1 && wcwidth(0x4E2D) == 2 && wcwidth(0x301) == 0 && wcswidth(w, 4) == 6, "wcwidth", NULL);
    check(towupper(0xE9) == 0xC9 && towlower(0x416) == 0x436 && iswalpha(0x4E2D) && !iswalpha(L'1'), "towupper, iswalpha", NULL);
    char fmt[64];
    snprintf(fmt, sizeof(fmt), "%ls|%lc", L"x\u00e9", (wint_t)0x4E2D);
    check(strcmp(fmt, "x\xC3\xA9|\xE4\xB8\xAD") == 0, "printf %ls and %lc", fmt);
    wchar_t ws[32];
    swprintf(ws, 32, L"%d-%ls", 42, L"ok");
    check(wcscmp(ws, L"42-ok") == 0, "swprintf", NULL);

    char p1[] = "C:\\DOCS\\README.MD", p2[] = "C:\\DOCS\\README.MD", p3[] = "/usr/lib/";
    check(strcmp(basename(p1), "README.MD") == 0 && strcmp(dirname(p2), "C:\\DOCS") == 0 && strcmp(basename(p3), "lib") == 0,
          "basename, dirname", NULL);

    iconv_t cd = iconv_open("UTF-8", "ISO-8859-1");
    char latin[] = "caf\xE9", out[16] = {0};
    char *in_p = latin, *out_p = out;
    size_t in_left = 4, out_left = sizeof(out);
    check(cd != (iconv_t)-1 && iconv(cd, &in_p, &in_left, &out_p, &out_left) == 0 && strcmp(out, "caf\xC3\xA9") == 0,
          "iconv Latin-1 to UTF-8", NULL);
    iconv_close(cd);

    struct in_addr a4;
    unsigned char a6[16];
    char text[64];
    check(inet_pton(AF_INET, "192.168.1.20", &a4) == 1 && strcmp(inet_ntop(AF_INET, &a4, text, sizeof(text)), "192.168.1.20") == 0 &&
              inet_pton(AF_INET6, "fe80::1:2", a6) == 1 && strcmp(inet_ntop(AF_INET6, a6, text, sizeof(text)), "fe80::1:2") == 0,
          "inet_pton, inet_ntop", text);
    struct addrinfo *ai = NULL;
    // Without NETWORK=true no socket; with it the loopback, where a port
    // nobody listens on refuses at once:
    int ok = getaddrinfo("127.0.0.1", "9", NULL, &ai) == 0 && ai->ai_family == AF_INET;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s >= 0) {
        ok = ok && connect(s, ai->ai_addr, ai->ai_addrlen) == -1 && errno == ECONNREFUSED;
        close(s);
    }
    check(ok, "getaddrinfo numeric; 127.0.0.1 refuses a closed port (or no network)", NULL);
    freeaddrinfo(ai);

    void *root = NULL;
    int keys[] = {5, 2, 8, 1};
    for (int i = 0; i < 4; i++) {
        tsearch(&keys[i], &root, compare_ints);
    }
    int want = 8, missing = 7;
    check(tfind(&want, &root, compare_ints) != NULL && tfind(&missing, &root, compare_ints) == NULL &&
              tdelete(&want, &root, compare_ints) != NULL && tfind(&want, &root, compare_ints) == NULL,
          "tsearch, tfind, tdelete", NULL);

    void *big = aligned_alloc(4096, 100);
    void *mid = NULL;
    check(big != NULL && ((uintptr_t)big & 4095) == 0 && posix_memalign(&mid, 64, 10) == 0 && ((uintptr_t)mid & 63) == 0,
          "aligned_alloc, posix_memalign", NULL);
    free(big);
    free(mid);

    regex_t re;
    regmatch_t m[4];
    check(regcomp(&re, "([a-z]+)@([a-z]+)\\.com", REG_EXTENDED) == 0 && re.re_nsub == 2 &&
              regexec(&re, "mail: bob@example.com!", 3, m, 0) == 0 && m[0].rm_so == 6 && m[0].rm_eo == 21 &&
              m[1].rm_so == 6 && m[1].rm_eo == 9 && m[2].rm_so == 10 && m[2].rm_eo == 17,
          "regex: extended, groups", NULL);
    regfree(&re);
    check(regcomp(&re, "\\(ab*\\)c\\1", 0) == 0 && regexec(&re, "xxabbcabb", 2, m, 0) == 0 && m[0].rm_so == 2 &&
              m[0].rm_eo == 9 && regexec(&re, "abcb", 0, NULL, 0) == REG_NOMATCH,
          "regex: basic, back-reference", NULL);
    regfree(&re);
    check(regcomp(&re, "a|ab|abc", REG_EXTENDED) == 0 && regexec(&re, "abcd", 1, m, 0) == 0 && m[0].rm_eo == 3,
          "regex: the longest of the leftmost", NULL);
    regfree(&re);
    check(regcomp(&re, "^[[:upper:]]+$", REG_EXTENDED | REG_ICASE | REG_NEWLINE) == 0 &&
              regexec(&re, "123\nHello\n", 1, m, 0) == 0 && m[0].rm_so == 4 && m[0].rm_eo == 9,
          "regex: classes, REG_ICASE, REG_NEWLINE", NULL);
    regfree(&re);
    check(regcomp(&re, "(a", REG_EXTENDED) == REG_EPAREN && regcomp(&re, "a{2,1}", REG_EXTENDED) == REG_BADBR,
          "regex: errors", NULL);
    static char long_text[20001];
    memset(long_text, 'a', 20000);
    check(regcomp(&re, "(a|b)*$", REG_EXTENDED) == 0 && regexec(&re, long_text, 1, m, 0) == 0 && m[0].rm_eo == 20000,
          "regex: 20000 characters (no deep recursion)", NULL);
    regfree(&re);

    struct rlimit rl;
    check(getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur > 3, "getrlimit", NULL);
    check(strcmp(nl_langinfo(CODESET), "UTF-8") == 0, "nl_langinfo(CODESET)", NULL);
    struct group *g = getgrnam("admins");
    check(g != NULL && g->gr_gid == 10, "getgrnam(admins)", NULL);

    int fds[2];
    pipe(fds);
    struct iovec iov[2] = {{"ab", 2}, {"cd", 2}};
    char got[8] = {0};
    check(writev(fds[1], iov, 2) == 4 && read(fds[0], got, 4) == 4 && strcmp(got, "abcd") == 0, "writev", got);
    close(fds[0]);
    close(fds[1]);

    if (tasks) {
        thrd_t t;
        int arg = 41, res = 0;
        check(thrd_create(&t, c11_thread, &arg) == thrd_success && thrd_join(t, &res) == thrd_success && res == 42,
              "C11 thrd_create, thrd_join", NULL);
    }
}

// NetBSD's fdlibm and the compiler's runtime: known values, to a few
// units in the last place.
static int near(double got, double want) {
    double tol = fabs(want) * 1e-14 + 1e-300;
    return fabs(got - want) <= tol;
}

static int nearf(float got, float want) {
    return fabsf(got - want) <= fabsf(want) * 1e-6f + 1e-30f;
}

static void test_math(void) {
    check(near(erf(0.5), 0.5204998778130465) && near(erfc(2.0), 0.004677734981047266), "erf, erfc", NULL);
    check(near(tgamma(5.0), 24.0) && near(tgamma(0.5), 1.7724538509055160) && near(lgamma(10.0), 12.801827480081469),
          "tgamma, lgamma", NULL);
    check(near(cbrt(27.0), 3.0) && near(hypot(3.0, 4.0), 5.0) && near(asinh(1.0), 0.8813735870195430) &&
              acosh(1.0) == 0.0 && near(atanh(0.5), 0.5493061443340549),
          "cbrt, hypot, asinh, acosh, atanh", NULL);
    check(near(sinh(1.0), 1.1752011936438014) && near(cosh(1.0), 1.5430806348152437) && near(tanh(1.0), 0.7615941559557649),
          "sinh, cosh, tanh", NULL);
    check(near(asin(1.0), M_PI_2) && near(atan2(1.0, 1.0), M_PI_4) && near(pow(2.0, 0.5), M_SQRT2) &&
              near(expm1(1e-10), 1.00000000005e-10) && near(log1p(1e-10), 9.9999999995e-11),
          "asin, atan2, pow, expm1, log1p", NULL);
    check(near(j0(1.0), 0.7651976865579666) && near(j1(1.0), 0.4400505857449335) && near(y0(1.0), 0.08825696421567696),
          "j0, j1, y0", NULL);
    int q;
    check(rint(2.5) == 2.0 && nearbyint(3.5) == 4.0 && lround(2.5) == 3 && llrint(-2.5) == -2 &&
              remainder(10.0, 3.0) == 1.0 && remquo(10.0, 3.0, &q) == 1.0 && q == 3,
          "rint, nearbyint, lround, remainder, remquo", NULL);
    int e;
    check(nextafter(1.0, 2.0) > 1.0 && ldexp(1.0, 10) == 1024.0 && frexp(8.0, &e) == 0.5 && e == 4 &&
              ilogb(1024.0) == 10 && logb(0.25) == -2.0 && fdim(5.0, 3.0) == 2.0,
          "nextafter, ldexp, frexp, ilogb, logb, fdim", NULL);
    check(nearf(sinf(1.0f), 0.84147098f) && nearf(powf(2.0f, 10.0f), 1024.0f) && nearf(atan2f(1.0f, 1.0f), 0.78539816f) &&
              nearf(tgammaf(5.0f), 24.0f) && nearf(cbrtf(8.0f), 2.0f) && nearf(hypotf(3.0f, 4.0f), 5.0f),
          "float versions", NULL);
    check(fabs((double)(sinl(1.0L) - 0.8414709848078965L)) < 1e-15 && fabs((double)(powl(2.0L, 10.0L) - 1024.0L)) < 1e-12 &&
              fabs((double)(erfl(0.5L) - 0.5204998778130465L)) < 1e-15,
          "long double versions", NULL);
    check(isnan(sqrt(-1.0)) && isinf(log(0.0)) && isnormal(1.0) && !isnormal(0.0) && isgreater(2.0, 1.0),
          "NaN, infinities, comparison macros", NULL);
}

static void test_terminal(void) {
    struct termios t;
    if (!isatty(0)) {
        check(tcgetattr(0, &t) == -1 && errno == ENOTTY, "tcgetattr on a redirected stdin: ENOTTY", NULL);
        return;
    }
    check(tcgetattr(0, &t) == 0 && (t.c_lflag & ICANON), "tcgetattr: canonical mode", NULL);
    struct termios raw = t;
    cfmakeraw(&raw);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &raw);
    char c;
    long t0 = now_ms();
    ssize_t r = read(0, &c, 1);
    tcsetattr(0, TCSANOW, &t);
    check(r == 0 && now_ms() - t0 < 100, "raw read with VMIN 0: no key, at once", NULL);
    // Asked of stdin, the terminal here; a redirected stdout is none:
    struct winsize ws;
    check(ioctl(0, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0, "ioctl TIOCGWINSZ", NULL);
    if (!isatty(1)) {
        check(ioctl(1, TIOCGWINSZ, &ws) == -1 && errno == ENOTTY, "ioctl TIOCGWINSZ on a redirected stdout: ENOTTY", NULL);
    }
}

static volatile sig_atomic_t usr1;

static void on_usr1(int sig) {
    usr1 = sig;
}

static volatile sig_atomic_t alarmed;

static void on_alarm(int sig) {
    alarmed = sig;
}

static void test_signals_self(int tasks) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);
    usr1 = 0;
    raise(SIGUSR1);
    check(usr1 == SIGUSR1, "raise: handler called", NULL);
    if (!tasks) {
        skip("kill to itself, sigprocmask, sigpending");
        skip("alarm and pause");
        skip("nanosleep cut short by a signal");
        return;
    }
    sigset_t set, old;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &set, &old);
    usr1 = 0;
    kill(getpid(), SIGUSR1);
    sigset_t pend;
    sigpending(&pend);
    int blocked_ok = usr1 == 0 && sigismember(&pend, SIGUSR1);
    sigprocmask(SIG_SETMASK, &old, NULL);
    check(blocked_ok && usr1 == SIGUSR1, "kill to itself, blocked, pending, then handled", NULL);

    sa.sa_handler = on_alarm;
    sigaction(SIGALRM, &sa, NULL);
    alarmed = 0;
    long t0 = now_ms();
    alarm(1);
    int r = pause();
    long took = now_ms() - t0;
    snprintf(detail, sizeof(detail), "r=%d errno=%d after %ld ms", r, errno, took);
    check(r == -1 && errno == EINTR && alarmed == SIGALRM && took >= 900 && took < 1500, "alarm and pause", detail);

    alarm(1);
    struct timespec req = {3, 0}, rem = {0, 0};
    t0 = now_ms();
    r = nanosleep(&req, &rem);
    took = now_ms() - t0;
    snprintf(detail, sizeof(detail), "r=%d after %ld ms, rem %ld s", r, took, (long)rem.tv_sec);
    check(r == -1 && errno == EINTR && took < 1500 && rem.tv_sec >= 1, "nanosleep cut short by a signal", detail);
    signal(SIGALRM, SIG_DFL);
}

/* TESTS WITH OTHER TASKS */

static void test_spawn(void) {
    int p[2];
    pipe(p);
    const char *w[] = {"echo", "hello", "from a task", NULL};
    pid_t pid = start(w, -1, p[1]);
    close(p[1]);
    check(pid > 1, "posix_spawnp", strerror(errno));
    char buf[128];
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    check(strcmp(buf, "hello from a task\n") == 0, "child's output through a pipe", buf);
    int st = -1;
    check(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 0, "waitpid: exit 0", status_text(st));

    const char *e7[] = {"exit", "7", NULL};
    pid = start(e7, -1, -1);
    check(waitpid(pid, &st, 0) == pid && WEXITSTATUS(st) == 7, "waitpid: exit 7", status_text(st));

    const char *sl[] = {"sleep", "200", NULL};
    pid = start(sl, -1, -1);
    int r = waitpid(pid, &st, WNOHANG);
    check(r == 0, "waitpid WNOHANG: still running", NULL);
    check(wait(&st) == pid && WIFEXITED(st), "wait: any child", status_text(st));
    errno = 0;
    check(wait(&st) == -1 && errno == ECHILD, "wait with no children: ECHILD", strerror(errno));

    // Through a filter: stdin and stdout both pipes:
    int in[2], out[2];
    pipe(in);
    pipe(out);
    const char *cat[] = {"cat", NULL};
    pid = start(cat, in[0], out[1]);
    close(in[0]);
    close(out[1]);
    write(in[1], "abc\ndef\n", 8);
    close(in[1]);
    read_all(out[0], buf, sizeof(buf));
    close(out[0]);
    waitpid(pid, &st, 0);
    check(strcmp(buf, "abc\ndef\n") == 0, "cat between two pipes", buf);

    pid_t bad;
    char *argv[] = {"nosuch", NULL};
    check(posix_spawnp(&bad, "NOSUCHPROGRAM", NULL, NULL, argv, NULL) == ENOENT, "posix_spawnp of a missing program: ENOENT", NULL);
}

// posix_spawn's and execle's envp (tasks->spawn_env).
static void test_spawn_env(void) {
    zdos->tasks->spawn_env("", 0, "", 0, NULL, "", 0);
    if (zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED) {
        skip_because("posix_spawn with envp", "this ZDOS has no tasks->spawn_env");
        skip_because("vfork and execle with envp", "this ZDOS has no tasks->spawn_env");
        return;
    }
    char buf[160];
    int p[2];
    pipe(p);
    const char *w[] = {"getenv", "ZTEST", "ZOTHER", "PLATFORM", NULL};
    char *envp[] = {"ZTEST=42", "zother=low case", NULL};
    pid_t pid = start_env(w, -1, p[1], envp);
    close(p[1]);
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    int st = -1;
    waitpid(pid, &st, 0);
    check(pid > 1 && strcmp(buf, "ZTEST=42 ZOTHER=low case PLATFORM=-\n") == 0, "posix_spawn with envp: just those variables", buf);
    pipe(p);
    pid = start(w, -1, p[1]);
    close(p[1]);
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    waitpid(pid, &st, 0);
    check(strstr(buf, "ZTEST=- ") != NULL && strstr(buf, "PLATFORM=-") == NULL, "posix_spawn without envp: the global ones", buf);
    char *bad[] = {"NOEQUALS", NULL};
    char *argv[] = {"posixtest", "exit", "0", NULL};
    check(posix_spawnp(&pid, "posixtest", NULL, NULL, argv, bad) == EINVAL, "posix_spawn with a bad envp entry: EINVAL", NULL);
    char self[300];
    self[zdos->programs->program_path(self, sizeof(self) - 1)] = '\0';
    pipe(p);
    pid = vfork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        execle(self, "posixtest", "getenv", "ZTEST", (char *)NULL, (char *[]){"ZTEST=from execle", NULL});
        _exit(127);
    }
    close(p[1]);
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    waitpid(pid, &st, 0);
    check(strcmp(buf, "ZTEST=from execle\n") == 0, "vfork and execle with envp", buf);
}

static void test_pipeline(void) {
    // yes | head 3: both running at once; yes ends with SIGPIPE:
    int a[2], b[2];
    pipe(a);
    pipe(b);
    const char *yes[] = {"yes", NULL};
    const char *head[] = {"head", "3", NULL};
    pid_t y = start(yes, -1, a[1]);
    pid_t h = start(head, a[0], b[1]);
    close(a[0]);
    close(a[1]);
    close(b[1]);
    char buf[64];
    read_all(b[0], buf, sizeof(buf));
    close(b[0]);
    check(strcmp(buf, "y\ny\ny\n") == 0, "yes | head 3", buf);
    int st = -1;
    waitpid(h, &st, 0);
    check(WIFEXITED(st) && WEXITSTATUS(st) == 0, "head ended normally", status_text(st));
    waitpid(y, &st, 0);
    check(WIFSIGNALED(st) && WTERMSIG(st) == SIGPIPE, "yes ended by SIGPIPE", status_text(st));
}

static void test_vfork(void) {
    int p[2];
    pipe(p);
    pid_t pid = vfork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        execlp("posixtest", "posixtest", "echo", "vfork", "and", "exec", (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    check(pid > 1, "vfork and exec", strerror(errno));
    char buf[64];
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    check(strcmp(buf, "vfork and exec\n") == 0, "the vfork child's output", buf);
    int st = -1;
    check(waitpid(pid, &st, 0) == pid && WEXITSTATUS(st) == 0, "waitpid of the vfork child", status_text(st));

    pid = vfork();
    if (pid == 0) {
        execlp("NOSUCHPROGRAM", "x", (char *)NULL);
        _exit(127);
    }
    check(waitpid(pid, &st, 0) == pid && WEXITSTATUS(st) == 127, "vfork, failed exec, _exit(127)", status_text(st));
    // fork, as programs write it: the same emulation:
    pipe(p);
    pid = fork();
    if (pid == 0) {
        dup2(p[1], 1);
        close(p[0]);
        close(p[1]);
        execlp("posixtest", "posixtest", "echo", "from", "fork", (char *)NULL);
        exit(127);
    }
    close(p[1]);
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    check(pid > 1 && strcmp(buf, "from fork\n") == 0, "fork, dup2, exec", buf);
    check(waitpid(pid, &st, 0) == pid && WEXITSTATUS(st) == 0, "waitpid of the fork child", status_text(st));
}

static void test_signals_tasks(void) {
    int p[2];
    pipe(p);
    const char *sw[] = {"sigwait", NULL};
    pid_t pid = start(sw, -1, p[1]);
    close(p[1]);
    char buf[64];
    size_t n = 0;
    while (n < 6 && read(p[0], buf + n, 1) == 1) {
        n++; /* "ready\n" */
    }
    kill(pid, SIGUSR1);
    read_all(p[0], buf, sizeof(buf));
    close(p[0]);
    int st = -1;
    waitpid(pid, &st, 0);
    check(strcmp(buf, "got 10\n") == 0 && WEXITSTATUS(st) == 0, "kill SIGUSR1: the child's handler", buf);

    const char *spin[] = {"spin", NULL};
    pid = start(spin, -1, -1);
    usleep(30000);
    long t0 = now_ms();
    kill(pid, SIGTERM);
    waitpid(pid, &st, 0);
    snprintf(detail, sizeof(detail), "%s after %ld ms", status_text(st), now_ms() - t0);
    check(WIFSIGNALED(st) && WTERMSIG(st) == SIGTERM, "SIGTERM ends a task in its own loop", detail);

    pid = start(spin, -1, -1);
    kill(pid, SIGSTOP);
    usleep(20000);
    check(waitpid(pid, &st, WNOHANG) == 0, "SIGSTOP: stopped, not ended", NULL);
    kill(pid, SIGCONT);
    kill(pid, SIGKILL);
    waitpid(pid, &st, 0);
    check(WIFSIGNALED(st) && WTERMSIG(st) == SIGKILL, "SIGCONT, then SIGKILL", status_text(st));
    check(kill(0x7000, SIGTERM) == -1 && errno == ESRCH, "kill of no task: ESRCH", NULL);

    const char *te[] = {"threadexit", NULL};
    pid = start(te, -1, -1);
    waitpid(pid, &st, 0);
    check(WIFEXITED(st) && WEXITSTATUS(st) == 9, "exit in a thread ends the program", status_text(st));
    const char *lt[] = {"leakthread", NULL};
    pid = start(lt, -1, -1);
    waitpid(pid, &st, 0);
    check(WIFEXITED(st) && WEXITSTATUS(st) == 3, "a program's end ends its threads", status_text(st));
}

/* THREADS */

static pthread_mutex_t counter_lock = PTHREAD_MUTEX_INITIALIZER;
static long counter;

static void *add(void *arg) {
    long times = (long)arg;
    for (long i = 0; i < times; i++) {
        pthread_mutex_lock(&counter_lock);
        long c = counter;
        if ((i & 255) == 0) {
            sched_yield(); /* hand over while holding it */
        }
        counter = c + 1;
        pthread_mutex_unlock(&counter_lock);
    }
    return (void *)(times * 2);
}

static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t q_changed = PTHREAD_COND_INITIALIZER;
static int queue[8], q_len, q_done;
static long q_sum;

static void *producer(void *arg) {
    (void)arg;
    for (int i = 1; i <= 100; i++) {
        pthread_mutex_lock(&q_lock);
        while (q_len == 8) {
            pthread_cond_wait(&q_changed, &q_lock);
        }
        queue[q_len++] = i;
        pthread_cond_broadcast(&q_changed);
        pthread_mutex_unlock(&q_lock);
    }
    pthread_mutex_lock(&q_lock);
    q_done = 1;
    pthread_cond_broadcast(&q_changed);
    pthread_mutex_unlock(&q_lock);
    return NULL;
}

static void *consumer(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&q_lock);
        while (q_len == 0 && !q_done) {
            pthread_cond_wait(&q_changed, &q_lock);
        }
        if (q_len == 0) {
            pthread_mutex_unlock(&q_lock);
            return NULL;
        }
        q_sum += queue[--q_len];
        pthread_cond_broadcast(&q_changed);
        pthread_mutex_unlock(&q_lock);
    }
}

static sem_t sem;
static volatile int sem_seen;

static void *poster(void *arg) {
    (void)arg;
    usleep(30000);
    sem_seen = 1;
    sem_post(&sem);
    return NULL;
}

static pthread_key_t key;
static int key_freed;

static void free_value(void *v) {
    (void)v;
    key_freed++;
}

static void *own_errno(void *arg) {
    (void)arg;
    errno = 77;
    pthread_setspecific(key, (void *)0x1234);
    usleep(10000);
    return (void *)(long)(errno == 77 && pthread_getspecific(key) == (void *)0x1234);
}

static pthread_barrier_t barrier;
static int serial_count;

static void *at_barrier(void *arg) {
    (void)arg;
    if (pthread_barrier_wait(&barrier) == PTHREAD_BARRIER_SERIAL_THREAD) {
        __atomic_fetch_add(&serial_count, 1, __ATOMIC_SEQ_CST);
    }
    return NULL;
}

static pthread_mutex_t held = PTHREAD_MUTEX_INITIALIZER;

static void *try_held(void *arg) {
    (void)arg;
    return (void *)(long)pthread_mutex_trylock(&held);
}

static volatile int writer_done;
static volatile long busy_count;

static void *disk_writer(void *arg) {
    (void)arg;
    static char block[64 * 1024];
    memset(block, 'z', sizeof(block));
    int fd = open("/tmp/POSIXIO.TMP", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    for (int i = 0; i < 64 && fd >= 0; i++) {
        write(fd, block, sizeof(block));
    }
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    writer_done = 1;
    return NULL;
}

static void *busy(void *arg) {
    (void)arg;
    while (!writer_done) {
        busy_count++;
    }
    return NULL;
}

static void test_threads(void) {
    pthread_t t[4];
    counter = 0;
    int created = 0;
    for (int i = 0; i < 4; i++) {
        created += pthread_create(&t[i], NULL, add, (void *)2000L) == 0;
    }
    check(created == 4, "pthread_create x4", NULL);
    long sum = 0;
    for (int i = 0; i < 4; i++) {
        void *r = NULL;
        pthread_join(t[i], &r);
        sum += (long)r;
    }
    snprintf(detail, sizeof(detail), "counter %ld, results %ld", counter, sum);
    check(counter == 8000 && sum == 16000, "mutex: 4 threads x 2000 increments, join results", detail);

    pthread_t pr, c1, c2;
    q_len = q_done = 0;
    q_sum = 0;
    pthread_create(&c1, NULL, consumer, NULL);
    pthread_create(&c2, NULL, consumer, NULL);
    pthread_create(&pr, NULL, producer, NULL);
    pthread_join(pr, NULL);
    pthread_join(c1, NULL);
    pthread_join(c2, NULL);
    snprintf(detail, sizeof(detail), "sum %ld", q_sum);
    check(q_sum == 5050, "condition variable: producer and two consumers", detail);

    sem_init(&sem, 0, 0);
    check(sem_trywait(&sem) == -1 && errno == EAGAIN, "sem_trywait on 0: EAGAIN", NULL);
    struct timespec abs;
    clock_gettime(CLOCK_REALTIME, &abs);
    abs.tv_nsec += 50000000;
    if (abs.tv_nsec >= 1000000000) {
        abs.tv_sec++;
        abs.tv_nsec -= 1000000000;
    }
    long t0 = now_ms();
    int r = sem_timedwait(&sem, &abs);
    snprintf(detail, sizeof(detail), "r=%d errno=%d after %ld ms", r, errno, now_ms() - t0);
    check(r == -1 && errno == ETIMEDOUT, "sem_timedwait: ETIMEDOUT", detail);
    sem_seen = 0;
    pthread_create(&pr, NULL, poster, NULL);
    r = sem_wait(&sem);
    check(r == 0 && sem_seen, "sem_wait woken by another thread's sem_post", NULL);
    pthread_join(pr, NULL);
    sem_destroy(&sem);

    pthread_key_create(&key, free_value);
    errno = 5;
    pthread_t e;
    pthread_create(&e, NULL, own_errno, NULL);
    void *ok = NULL;
    pthread_join(e, &ok);
    check(ok == (void *)1L && errno == 5 && key_freed == 1, "errno and keys per thread", NULL);

    pthread_mutexattr_t ma;
    pthread_mutexattr_init(&ma);
    pthread_mutexattr_settype(&ma, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_t rm;
    pthread_mutex_init(&rm, &ma);
    r = pthread_mutex_lock(&rm) | pthread_mutex_lock(&rm) | pthread_mutex_unlock(&rm) | pthread_mutex_unlock(&rm);
    check(r == 0 && pthread_mutex_unlock(&rm) == EPERM, "recursive mutex", NULL);
    pthread_mutex_destroy(&rm);

    pthread_mutex_lock(&held);
    pthread_create(&e, NULL, try_held, NULL);
    pthread_join(e, &ok);
    pthread_mutex_unlock(&held);
    check((long)ok == EBUSY, "trylock of a mutex another thread holds: EBUSY", NULL);

    pthread_barrier_init(&barrier, NULL, 3);
    serial_count = 0;
    pthread_t b1, b2;
    pthread_create(&b1, NULL, at_barrier, NULL);
    pthread_create(&b2, NULL, at_barrier, NULL);
    at_barrier(NULL);
    pthread_join(b1, NULL);
    pthread_join(b2, NULL);
    check(serial_count == 1, "barrier of 3", NULL);
    pthread_barrier_destroy(&barrier);

    pthread_rwlock_t rw = PTHREAD_RWLOCK_INITIALIZER;
    r = pthread_rwlock_rdlock(&rw) | pthread_rwlock_tryrdlock(&rw);
    int w = pthread_rwlock_trywrlock(&rw);
    pthread_rwlock_unlock(&rw);
    pthread_rwlock_unlock(&rw);
    check(r == 0 && w == EBUSY && pthread_rwlock_trywrlock(&rw) == 0, "read-write lock", NULL);
    pthread_rwlock_unlock(&rw);

    struct sched_param sp = {20};
    pthread_setschedparam(pthread_self(), SCHED_RR, &sp);
    int pol;
    pthread_getschedparam(pthread_self(), &pol, &sp);
    check(sp.sched_priority == 20, "pthread_setschedparam", NULL);
    sp.sched_priority = 16;
    pthread_setschedparam(pthread_self(), SCHED_RR, &sp);

    // A thread's disk writes sleep while the disk works: a lower priority
    // thread computes meanwhile, and gives way when the disk wakes the writer:
    writer_done = 0;
    busy_count = 0;
    pthread_t dw, bz;
    t0 = now_ms();
    pthread_attr_t low;
    pthread_attr_init(&low);
    struct sched_param lp = {8};
    pthread_attr_setschedparam(&low, &lp);
    pthread_create(&dw, NULL, disk_writer, NULL);
    pthread_create(&bz, &low, busy, NULL);
    pthread_join(dw, NULL);
    pthread_join(bz, NULL);
    unlink("/tmp/POSIXIO.TMP");
    long took = now_ms() - t0;
    snprintf(detail, sizeof(detail), "4 MB in %ld ms, the other thread counted %ld", took, busy_count);
    printf("# %s\n", detail);
    if (on_bios || on_uefi)
        skip_because("computing goes on while another thread writes to disk", "tasks switch only inside ZDOS here");
    else if (took < 5)
        // QEMU's AHCI completes a command as it is issued: no wait to compute in
        skip_because("computing goes on while another thread writes to disk", "the disk finished at once");
    else
        check(busy_count > 1000, "computing goes on while another thread writes to disk", detail);
}

/* FUTEX LOCKS: zero objects, kinds, timed waits, many waiters */

static struct timespec in_ms(clockid_t clock, long ms) {
    struct timespec t;
    clock_gettime(clock, &t);
    t.tv_sec += ms / 1000;
    t.tv_nsec += (ms % 1000) * 1000000;
    if (t.tv_nsec >= 1000000000) {
        t.tv_sec++;
        t.tv_nsec -= 1000000000;
    }
    return t;
}

static pthread_mutex_t zero_m; /* all zeros, no initializer */
static pthread_cond_t zero_c;
static int zero_flag;

static void *zero_peer(void *arg) {
    (void)arg;
    pthread_mutex_lock(&zero_m);
    zero_flag = 1;
    pthread_cond_signal(&zero_c);
    pthread_mutex_unlock(&zero_m);
    return NULL;
}

static void *unlock_it(void *arg) {
    return (void *)(long)pthread_mutex_unlock((pthread_mutex_t *)arg);
}

static pthread_mutex_t hold_m = PTHREAD_MUTEX_INITIALIZER;
static sem_t hold_in, hold_out;

static void *holder(void *arg) {
    (void)arg;
    pthread_mutex_lock(&hold_m);
    sem_post(&hold_in);
    sem_wait(&hold_out);
    pthread_mutex_unlock(&hold_m);
    return NULL;
}

static mtx_t c11_m;

static void *c11_timed(void *arg) {
    (void)arg;
    struct timespec at = in_ms(CLOCK_REALTIME, 10);
    return (void *)(long)mtx_timedlock(&c11_m, &at);
}

#define CROWD 12
static pthread_mutex_t crowd_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t crowd_c = PTHREAD_COND_INITIALIZER, crowd_in = PTHREAD_COND_INITIALIZER;
static int crowd_arrived, crowd_go, crowd_woken;

static void *crowd(void *arg) {
    (void)arg;
    pthread_mutex_lock(&crowd_m);
    crowd_arrived++;
    pthread_cond_signal(&crowd_in);
    while (!crowd_go) {
        pthread_cond_wait(&crowd_c, &crowd_m);
    }
    crowd_woken++;
    pthread_mutex_unlock(&crowd_m);
    return NULL;
}

#define MANY 100
static pthread_mutex_t many_m[MANY];
static pthread_cond_t many_c[MANY];
static int many_flag[MANY];

static void *many_waiter(void *arg) {
    (void)arg;
    int done = 0;
    for (int i = 0; i < MANY; i++) {
        pthread_mutex_lock(&many_m[i]);
        while (!many_flag[i]) {
            pthread_cond_wait(&many_c[i], &many_m[i]);
        }
        done++;
        pthread_mutex_unlock(&many_m[i]);
    }
    return (void *)(long)done;
}

static sem_t count_sem;

static void *sem_poster(void *arg) {
    for (long i = 0; i < (long)arg; i++) {
        sem_post(&count_sem);
    }
    return NULL;
}

static void *sem_taker(void *arg) {
    for (long i = 0; i < (long)arg; i++) {
        while (sem_wait(&count_sem) != 0) {
        }
    }
    return NULL;
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static int once_runs, once_seen;

static void once_init(void) {
    usleep(20000);
    __atomic_fetch_add(&once_runs, 1, __ATOMIC_SEQ_CST);
}

static void *once_caller(void *arg) {
    (void)arg;
    pthread_once(&once, once_init);
    if (once_runs == 1) {
        __atomic_fetch_add(&once_seen, 1, __ATOMIC_SEQ_CST);
    }
    return NULL;
}

static pthread_rwlock_t rw_l = PTHREAD_RWLOCK_INITIALIZER;
static volatile long rw_value;
static int rw_bad;

static void *rw_reader(void *arg) {
    (void)arg;
    for (int i = 0; i < 2000; i++) {
        pthread_rwlock_rdlock(&rw_l);
        if (rw_value % 2 != 0) {
            rw_bad++;
        }
        pthread_rwlock_unlock(&rw_l);
    }
    return NULL;
}

static void *rw_writer(void *arg) {
    (void)arg;
    for (int i = 0; i < 1000; i++) {
        pthread_rwlock_wrlock(&rw_l);
        rw_value++;
        if ((i & 63) == 0) {
            sched_yield();
        }
        rw_value++;
        pthread_rwlock_unlock(&rw_l);
    }
    return NULL;
}

static pthread_mutex_t sig_m = PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP;
static pthread_cond_t sig_c = PTHREAD_COND_INITIALIZER;
static int sig_go, sig_returns, sig_in_wait;

static void *sig_waiter(void *arg) {
    (void)arg;
    int ok = 1;
    pthread_mutex_lock(&sig_m);
    sig_in_wait = 1;
    while (!sig_go) {
        pthread_cond_wait(&sig_c, &sig_m);
        sig_returns++;
        ok &= pthread_mutex_trylock(&sig_m) == EBUSY; /* held again: by this thread */
    }
    ok &= pthread_mutex_unlock(&sig_m) == 0;
    return (void *)(long)ok;
}

static volatile int sig_locked;

static void *sig_locker(void *arg) {
    (void)arg;
    pthread_mutex_lock(&hold_m);
    sig_locked = 1;
    pthread_mutex_unlock(&hold_m);
    return NULL;
}

static void test_futex_locks(void) {
    pthread_t t, ts[CROWD];
    void *r = NULL;

    memset(&zero_m, 0, sizeof(zero_m));
    memset(&zero_c, 0, sizeof(zero_c));
    pthread_mutex_lock(&zero_m);
    pthread_create(&t, NULL, zero_peer, NULL);
    while (!zero_flag) {
        pthread_cond_wait(&zero_c, &zero_m);
    }
    pthread_mutex_unlock(&zero_m);
    pthread_join(t, NULL);
    check(zero_flag && pthread_mutex_trylock(&zero_m) == 0 && pthread_mutex_unlock(&zero_m) == 0,
          "zero-filled mutex and condition", NULL);

    pthread_mutexattr_t ma;
    pthread_mutexattr_init(&ma);
    pthread_mutexattr_settype(&ma, PTHREAD_MUTEX_ERRORCHECK);
    pthread_mutex_t em;
    pthread_mutex_init(&em, &ma);
    int e1 = pthread_mutex_unlock(&em), e2 = pthread_mutex_lock(&em), e3 = pthread_mutex_lock(&em);
    int e4 = pthread_mutex_trylock(&em);
    pthread_create(&t, NULL, unlock_it, &em);
    pthread_join(t, &r);
    int e5 = pthread_mutex_unlock(&em);
    snprintf(detail, sizeof(detail), "%d %d %d %d %ld %d", e1, e2, e3, e4, (long)r, e5);
    check(e1 == EPERM && e2 == 0 && e3 == EDEADLK && e4 == EBUSY && (long)r == EPERM && e5 == 0,
          "error-checking mutex: EDEADLK, EPERM for others", detail);
    pthread_mutex_destroy(&em);

    pthread_mutex_t rm = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
    e1 = pthread_mutex_lock(&rm) | pthread_mutex_trylock(&rm) | pthread_mutex_lock(&rm);
    pthread_create(&t, NULL, unlock_it, &rm);
    pthread_join(t, &r);
    e2 = pthread_mutex_unlock(&rm) | pthread_mutex_unlock(&rm);
    e3 = pthread_mutex_destroy(&rm);
    e4 = pthread_mutex_unlock(&rm);
    e5 = pthread_mutex_destroy(&rm);
    check(e1 == 0 && (long)r == EPERM && e2 == 0 && e3 == EBUSY && e4 == 0 && e5 == 0,
          "recursive mutex three deep, EPERM for others, EBUSY destroy", NULL);

    pthread_mutexattr_settype(&ma, PTHREAD_MUTEX_NORMAL);
    pthread_mutexattr_setprotocol(&ma, PTHREAD_PRIO_INHERIT);
    pthread_mutex_t pim;
    pthread_mutex_init(&pim, &ma);
    int proto = -1;
    pthread_mutexattr_getprotocol(&ma, &proto);
    e1 = pthread_mutex_lock(&pim);
    e2 = pthread_mutex_trylock(&pim);
    e3 = pthread_mutex_unlock(&pim);
    check(proto == PTHREAD_PRIO_INHERIT && e1 == 0 && e2 == EBUSY && e3 == 0 && pthread_mutex_destroy(&pim) == 0,
          "PTHREAD_PRIO_INHERIT mutex (a ZDOS mutex)", NULL);
    pthread_mutexattr_destroy(&ma);

    // Timed: a mutex another thread holds, conditions on both clocks:
    sem_init(&hold_in, 0, 0);
    sem_init(&hold_out, 0, 0);
    pthread_create(&t, NULL, holder, NULL);
    sem_wait(&hold_in);
    struct timespec at = in_ms(CLOCK_REALTIME, 50);
    long t0 = now_ms();
    e1 = pthread_mutex_timedlock(&hold_m, &at);
    long took = now_ms() - t0;
    at.tv_nsec = 1000000000;
    e2 = pthread_mutex_timedlock(&hold_m, &at);
    pthread_create(&ts[0], NULL, sig_locker, NULL); /* waits in lock while signals come */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_usr1;
    sigaction(SIGUSR1, &sa, NULL);
    for (int i = 0; i < 5; i++) {
        usleep(5000);
        pthread_kill(ts[0], SIGUSR1);
    }
    usleep(20000);
    int early = sig_locked;
    sem_post(&hold_out);
    pthread_join(t, NULL);
    pthread_join(ts[0], NULL);
    at = in_ms(CLOCK_REALTIME, 1000);
    e3 = pthread_mutex_timedlock(&hold_m, &at);
    pthread_mutex_unlock(&hold_m);
    snprintf(detail, sizeof(detail), "%d after %ld ms, %d, %d", e1, took, e2, e3);
    check(e1 == ETIMEDOUT && took >= 49 && took < 1000 && e2 == EINVAL && e3 == 0, "pthread_mutex_timedlock", detail);
    check(!early && sig_locked, "signals don't break a waiting pthread_mutex_lock", NULL);
    sem_destroy(&hold_in);
    sem_destroy(&hold_out);

    pthread_mutex_t cm = PTHREAD_ERRORCHECK_MUTEX_INITIALIZER_NP;
    pthread_cond_t cr = PTHREAD_COND_INITIALIZER, cmono;
    pthread_condattr_t ca;
    pthread_condattr_init(&ca);
    pthread_condattr_setclock(&ca, CLOCK_MONOTONIC);
    pthread_cond_init(&cmono, &ca);
    clockid_t ck = -1;
    pthread_condattr_getclock(&ca, &ck);
    pthread_mutex_lock(&cm);
    at = in_ms(CLOCK_REALTIME, 50);
    t0 = now_ms();
    e1 = pthread_cond_timedwait(&cr, &cm, &at);
    long took1 = now_ms() - t0;
    int held1 = pthread_mutex_trylock(&cm) == EBUSY;
    at = in_ms(CLOCK_MONOTONIC, 30);
    t0 = now_ms();
    e2 = pthread_cond_timedwait(&cmono, &cm, &at);
    long took2 = now_ms() - t0;
    at = in_ms(CLOCK_REALTIME, 0);
    at.tv_sec--;
    e3 = pthread_cond_timedwait(&cr, &cm, &at);
    at.tv_nsec = -1;
    e4 = pthread_cond_timedwait(&cr, &cm, &at);
    e5 = pthread_mutex_unlock(&cm);
    snprintf(detail, sizeof(detail), "%d after %ld ms, %d after %ld ms, %d, %d, %d", e1, took1, e2, took2, e3, e4, e5);
    check(e1 == ETIMEDOUT && took1 >= 49 && took1 < 1000 && held1 && ck == CLOCK_MONOTONIC && e2 == ETIMEDOUT &&
              took2 >= 29 && took2 < 1000 && e3 == ETIMEDOUT && e4 == EINVAL && e5 == 0,
          "pthread_cond_timedwait: CLOCK_REALTIME, CLOCK_MONOTONIC, past, invalid", detail);
    pthread_cond_destroy(&cmono);
    pthread_condattr_destroy(&ca);

    mtx_init(&c11_m, mtx_timed);
    mtx_lock(&c11_m);
    pthread_create(&t, NULL, c11_timed, NULL);
    pthread_join(t, &r);
    mtx_unlock(&c11_m);
    struct timespec at11 = in_ms(CLOCK_REALTIME, 10);
    check((long)r == thrd_timedout && mtx_timedlock(&c11_m, &at11) == thrd_success && mtx_unlock(&c11_m) == thrd_success,
          "C11 mtx_timedlock", NULL);
    mtx_destroy(&c11_m);

    // A broadcast wakes every waiter:
    crowd_arrived = crowd_go = crowd_woken = 0;
    int made = 0;
    for (int i = 0; i < CROWD; i++) {
        made += pthread_create(&ts[i], NULL, crowd, NULL) == 0;
    }
    pthread_mutex_lock(&crowd_m);
    while (crowd_arrived < made) {
        pthread_cond_wait(&crowd_in, &crowd_m);
    }
    crowd_go = 1;
    pthread_cond_broadcast(&crowd_c);
    pthread_mutex_unlock(&crowd_m);
    for (int i = 0; i < made; i++) {
        pthread_join(ts[i], NULL);
    }
    snprintf(detail, sizeof(detail), "%d of %d woken", crowd_woken, made);
    check(made == CROWD && crowd_woken == CROWD, "one broadcast wakes 12 waiters", detail);

    // More mutexes and conditions than ZDOS has (64), all held at once:
    int locked = 0;
    for (int i = 0; i < MANY; i++) {
        locked += pthread_mutex_lock(&many_m[i]) == 0;
    }
    for (int i = 0; i < MANY; i++) {
        pthread_mutex_unlock(&many_m[i]);
    }
    pthread_create(&t, NULL, many_waiter, NULL);
    for (int i = 0; i < MANY; i++) {
        pthread_mutex_lock(&many_m[i]);
        many_flag[i] = 1;
        pthread_cond_signal(&many_c[i]);
        pthread_mutex_unlock(&many_m[i]);
        if (i % 10 == 0) {
            usleep(1000);
        }
    }
    pthread_join(t, &r);
    snprintf(detail, sizeof(detail), "%d held, %ld waits", locked, (long)r);
    check(locked == MANY && (long)r == MANY, "100 mutexes and 100 conditions alive at once", detail);

    sem_init(&count_sem, 0, 0);
    pthread_t sp[4];
    for (int i = 0; i < 2; i++) {
        pthread_create(&sp[i], NULL, sem_taker, (void *)2000L);
    }
    for (int i = 2; i < 4; i++) {
        pthread_create(&sp[i], NULL, sem_poster, (void *)2000L);
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(sp[i], NULL);
    }
    int v = -1;
    sem_getvalue(&count_sem, &v);
    check(v == 0 && sem_trywait(&count_sem) == -1 && errno == EAGAIN, "semaphore: 2 posters, 2 takers x 2000", NULL);
    sem_t zs;
    memset(&zs, 0, sizeof(zs));
    check(sem_post(&zs) == 0 && sem_trywait(&zs) == 0 && sem_trywait(&zs) == -1, "zero-filled semaphore", NULL);
    sem_destroy(&count_sem);

    once_runs = once_seen = 0;
    for (int i = 0; i < 4; i++) {
        pthread_create(&ts[i], NULL, once_caller, NULL);
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(ts[i], NULL);
    }
    check(once_runs == 1 && once_seen == 4, "pthread_once from 4 threads", NULL);

    rw_value = 0;
    rw_bad = 0;
    for (int i = 0; i < 3; i++) {
        pthread_create(&ts[i], NULL, rw_reader, NULL);
    }
    pthread_create(&ts[3], NULL, rw_writer, NULL);
    for (int i = 0; i < 4; i++) {
        pthread_join(ts[i], NULL);
    }
    at = in_ms(CLOCK_REALTIME, 30);
    pthread_rwlock_rdlock(&rw_l);
    e1 = pthread_rwlock_timedwrlock(&rw_l, &at);
    e2 = pthread_rwlock_tryrdlock(&rw_l); /* no writer waits any more */
    pthread_rwlock_unlock(&rw_l);
    pthread_rwlock_unlock(&rw_l);
    snprintf(detail, sizeof(detail), "value %ld, %d odd, %d, %d", rw_value, rw_bad, e1, e2);
    check(rw_value == 2000 && rw_bad == 0 && e1 == ETIMEDOUT && e2 == 0, "read-write lock: 3 readers, a writer, timed",
          detail);

    // A signal ends a condition wait early (allowed), the mutex held again:
    sig_go = sig_returns = sig_in_wait = 0;
    usr1 = 0;
    pthread_create(&t, NULL, sig_waiter, NULL);
    for (int i = 0; i < 50 && !sig_in_wait; i++) {
        usleep(2000);
    }
    usleep(10000);
    pthread_kill(t, SIGUSR1);
    usleep(20000);
    pthread_mutex_lock(&sig_m);
    sig_go = 1;
    pthread_cond_signal(&sig_c);
    pthread_mutex_unlock(&sig_m);
    pthread_join(t, &r);
    snprintf(detail, sizeof(detail), "signal %d, %d returns, ok %ld", (int)usr1, sig_returns, (long)r);
    check(usr1 == SIGUSR1 && (long)r == 1 && sig_returns >= 1, "a signal during pthread_cond_wait", detail);
    signal(SIGUSR1, SIG_DFL);
}

/* NETWORK: POSIXTEST net [HOST] | net -L [ADDRESS]: the C library's
 * sockets against tests/net/net-tests.py's servers (TCP echo 5555, UDP
 * echo 5556, 5557 closed); -L: the loopback. TAP lines; exit code:
 * failures. */

static int net_failed, net_number;

static void net_check(int ok, const char *what) {
    net_number++;
    if (!ok) net_failed++;
    printf("%s %d - %s%s%s\n", ok ? "ok" : "not ok", net_number, what, ok ? "" : ": ", ok ? "" : strerror(errno));
}

static struct sockaddr_in net_at(const char *host, int port) {
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    inet_pton(AF_INET, host, &a.sin_addr);
    return a;
}

/* LOOPBACK (-L): both ends here, one thread (threads are metal only) */

static long net_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void net_set_nonblock(int s, int on) {
    int f = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, on ? f | O_NONBLOCK : f & ~O_NONBLOCK);
}

static int net_listener(struct sockaddr_in *a) {
    int l = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(l, (struct sockaddr *)a, sizeof(*a)) != 0 || listen(l, 16) != 0) {
        close(l);
        return -1;
    }
    return l;
}

/* *c the connecting end, *s the accepted one */
static int net_pair(int l, struct sockaddr_in *a, int *c, int *s) {
    *c = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    *s = -1;
    if (*c < 0) return 0;
    if (connect(*c, (struct sockaddr *)a, sizeof(*a)) != 0 && errno != EINPROGRESS) return 0;
    struct pollfd p = {l, POLLIN, 0};
    if (poll(&p, 1, 3000) != 1) return 0;
    *s = accept(l, NULL, NULL);
    p = (struct pollfd){*c, POLLOUT, 0};
    if (*s < 0 || poll(&p, 1, 3000) != 1) return 0;
    int err = -1;
    socklen_t len = sizeof(err);
    getsockopt(*c, SOL_SOCKET, SO_ERROR, &err, &len);
    net_set_nonblock(*c, 0);
    int one = 1;
    setsockopt(*c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(*s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval wait = {5, 0};
    setsockopt(*c, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    setsockopt(*s, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    return err == 0;
}

static int net_recv_all(int s, char *buf, int len) {
    int got = 0;
    while (got < len) {
        ssize_t n = recv(s, buf + got, len - got, 0);
        if (n <= 0) return 0;
        got += (int)n;
    }
    return 1;
}

/* c -> s -> c: microseconds each (-1: net_failed) */
static long net_round_trips(int c, int s, int n, int size) {
    char out[1024], in[1024];
    for (int i = 0; i < size; i++) out[i] = (char)('a' + i % 26);
    long t0 = net_now_ms();
    for (int i = 0; i < n; i++) {
        out[0] = (char)i;
        if (send(c, out, size, 0) != size || !net_recv_all(s, in, size)) return -1;
        if (send(s, in, size, 0) != size || !net_recv_all(c, in, size) || memcmp(in, out, size) != 0) return -1;
    }
    return (net_now_ms() - t0) * 1000 / n;
}

/* Both nonblocking, checked: the milliseconds (-1: net_failed) */
static long net_transfer(int c, int s, long total) {
    static unsigned char out[16384], in[16384];
    long sent = 0, got = 0, t0 = net_now_ms(), last = t0;
    net_set_nonblock(c, 1);
    net_set_nonblock(s, 1);
    while (got < total) {
        int moved = 0;
        if (sent < total) {
            int len = (int)(total - sent < (long)sizeof(out) ? total - sent : (long)sizeof(out));
            for (int i = 0; i < len; i++) out[i] = (unsigned char)((sent + i) * 7 + (sent + i) / 4096);
            ssize_t n = send(c, out, len, 0);
            if (n > 0) {
                sent += n;
                moved = 1;
            } else if (n < 0 && errno != EAGAIN) {
                return -1;
            }
        }
        ssize_t n = recv(s, in, sizeof(in), 0);
        if (n > 0) {
            for (ssize_t i = 0; i < n; i++) {
                if (in[i] != (unsigned char)((got + i) * 7 + (got + i) / 4096)) return -1;
            }
            got += n;
            moved = 1;
        } else if (n == 0 || errno != EAGAIN) {
            return -1;
        }
        if (moved) {
            last = net_now_ms();
        } else {
            if (net_now_ms() - last > 10000) return -1;
            struct pollfd p[2] = {{s, POLLIN, 0}, {c, POLLOUT, 0}};
            poll(p, sent < total ? 2 : 1, 100);
        }
    }
    net_set_nonblock(c, 0);
    net_set_nonblock(s, 0);
    long ms = net_now_ms() - t0;
    return ms > 0 ? ms : 1;
}

static void net_close_pair(int c, int s) {
    if (c >= 0) close(c);
    if (s >= 0) close(s);
}

/* A connection, its addresses, round trips, a large transfer */
static void net_lo_tcp(const char *addr, int port, long big) {
    char what[96];
    struct sockaddr_in a = net_at(addr, port);
    int l = net_listener(&a);
    snprintf(what, sizeof(what), "listen on %s:%d", addr, port);
    net_check(l >= 0, what);
    if (l < 0) return;
    int c, s;
    snprintf(what, sizeof(what), "connect / accept on %s", addr);
    net_check(net_pair(l, &a, &c, &s), what);
    struct sockaddr_in me, peer;
    socklen_t ml = sizeof(me), pl = sizeof(peer);
    getsockname(c, (struct sockaddr *)&me, &ml);
    getpeername(s, (struct sockaddr *)&peer, &pl);
    snprintf(what, sizeof(what), "%s: getsockname / getpeername", addr);
    net_check(me.sin_addr.s_addr == a.sin_addr.s_addr && peer.sin_addr.s_addr == a.sin_addr.s_addr &&
          me.sin_port == peer.sin_port, what);
    long us = net_round_trips(c, s, 2000, 1);
    snprintf(what, sizeof(what), "%s: 2000 TCP round trips", addr);
    net_check(us >= 0, what);
    printf("# %s TCP round trip (1 byte): %ld us\n", addr, us);
    us = net_round_trips(c, s, 500, 1000);
    printf("# %s TCP round trip (1000 bytes): %ld us\n", addr, us);
    long ms = net_transfer(c, s, big);
    snprintf(what, sizeof(what), "%s: %ld MiB checked", addr, big >> 20);
    net_check(ms > 0, what);
    if (ms > 0) printf("# %s TCP throughput: %ld MiB in %ld ms, %ld MB/s\n", addr, big >> 20, ms, big / 1000 / ms);
    ms = net_transfer(s, c, big / 4);
    snprintf(what, sizeof(what), "%s: %ld MiB the other way", addr, (big / 4) >> 20);
    net_check(ms > 0, what);
    /* The close reaches the other end: EOF: */
    char b;
    close(c);
    snprintf(what, sizeof(what), "%s: EOF after close", addr);
    net_check(recv(s, &b, 1, 0) == 0, what);
    close(s);
    close(l);
}

static void net_lo_many(const char *addr, int port) {
    enum { N = 24 };
    struct sockaddr_in a = net_at(addr, port);
    int l = net_listener(&a), c[N], s[N], ok = l >= 0, made = 0;
    for (int i = 0; ok && i < N; i++, made++) ok = net_pair(l, &a, &c[i], &s[i]);
    for (int i = 0; ok && i < N; i++) {
        char m[8];
        snprintf(m, sizeof(m), "c%02d", i);
        ok = send(c[i], m, 4, 0) == 4;
    }
    for (int i = 0; ok && i < N; i++) {
        char m[8], in[8];
        snprintf(m, sizeof(m), "c%02d", i);
        ok = net_recv_all(s[i], in, 4) && memcmp(in, m, 4) == 0 && send(s[i], in, 4, 0) == 4 &&
             net_recv_all(c[i], in, 4) && memcmp(in, m, 4) == 0;
    }
    for (int i = 0; i < made; i++) net_close_pair(c[i], s[i]);
    net_check(ok, "24 connections at once on 127.0.0.1");
    /* One after the other: TIME_WAIT pcbs get reused: */
    long t0 = net_now_ms();
    int i = 0;
    for (; ok && i < 300; i++) {
        int x, y;
        char in[4];
        ok = net_pair(l, &a, &x, &y) && send(x, "ping", 4, 0) == 4 && net_recv_all(y, in, 4) && memcmp(in, "ping", 4) == 0;
        net_close_pair(x, y);
    }
    net_check(ok, "300 connections one after the other on 127.0.0.1");
    if (ok) printf("# 127.0.0.1 connect + send + close: %ld us each\n", (net_now_ms() - t0) * 1000 / 300);
    if (l >= 0) close(l);
}

static void net_lo_udp(void) {
    int a = socket(AF_INET, SOCK_DGRAM, 0), b = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in at_a = net_at("127.0.0.1", 7104);
    net_check(bind(a, (struct sockaddr *)&at_a, sizeof(at_a)) == 0, "UDP bind 127.0.0.1");
    struct timeval wait = {3, 0};
    setsockopt(a, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    setsockopt(b, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    char buf[2048];
    struct sockaddr_in from;
    socklen_t fl = sizeof(from);
    int ok = sendto(b, "to-lo", 5, 0, (struct sockaddr *)&at_a, sizeof(at_a)) == 5 &&
             recvfrom(a, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl) == 5 && memcmp(buf, "to-lo", 5) == 0 &&
             from.sin_addr.s_addr == htonl(0x7F000001);
    net_check(ok, "UDP sendto / recvfrom 127.0.0.1");
    long t0 = net_now_ms();
    int i = 0;
    for (; ok && i < 2000; i++) {
        struct sockaddr_in f2;
        socklen_t l2 = sizeof(f2);
        ok = sendto(b, buf, 64, 0, (struct sockaddr *)&at_a, sizeof(at_a)) == 64 &&
             recvfrom(a, buf, sizeof(buf), 0, (struct sockaddr *)&f2, &l2) == 64 &&
             sendto(a, buf, 64, 0, (struct sockaddr *)&from, fl) == 64 && recv(b, buf, sizeof(buf), 0) == 64;
    }
    net_check(ok, "2000 UDP round trips on 127.0.0.1");
    if (ok) printf("# 127.0.0.1 UDP round trip (64 bytes): %ld us\n", (net_now_ms() - t0) * 1000 / 2000);
    /* A large datagram: no fragments on the loopback: */
    static char big[16000];
    for (int k = 0; k < (int)sizeof(big); k++) big[k] = (char)k;
    static char in[16000];
    ok = sendto(b, big, sizeof(big), 0, (struct sockaddr *)&at_a, sizeof(at_a)) == (ssize_t)sizeof(big) &&
         recv(a, in, sizeof(in), 0) == (ssize_t)sizeof(big) && memcmp(in, big, sizeof(big)) == 0;
    net_check(ok, "UDP 16000-byte datagram on 127.0.0.1");
    close(a);
    close(b);
}

/* Towards 10.0.2.2; none without a card */
static int net_own_address(char *out, size_t len) {
    long t0 = net_now_ms();
    while (net_now_ms() - t0 < 15000) { /* DHCP may still be asking */
        int u = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in to = net_at("10.0.2.2", 9), me;
        socklen_t ml = sizeof(me);
        int ok = connect(u, (struct sockaddr *)&to, sizeof(to)) == 0 &&
                 getsockname(u, (struct sockaddr *)&me, &ml) == 0 && me.sin_addr.s_addr != 0;
        close(u);
        if (ok) return inet_ntop(AF_INET, &me.sin_addr, out, (socklen_t)len) != NULL;
        usleep(500000);
    }
    return 0;
}

static int net_loopback(const char *own) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    net_check(getaddrinfo("localhost", "7100", &hints, &res) == 0 && res != NULL &&
          ((struct sockaddr_in *)res->ai_addr)->sin_addr.s_addr == htonl(0x7F000001), "getaddrinfo localhost");
    if (res != NULL) freeaddrinfo(res);
    net_lo_tcp("127.0.0.1", 7100, 8L << 20);
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in closed = net_at("127.0.0.1", 7199);
    errno = 0;
    long t0 = net_now_ms();
    net_check(connect(s, (struct sockaddr *)&closed, sizeof(closed)) < 0 && errno == ECONNREFUSED, "127.0.0.1: ECONNREFUSED");
    printf("# 127.0.0.1 refused in %ld ms\n", net_now_ms() - t0);
    close(s);
    net_lo_many("127.0.0.1", 7102);
    net_lo_udp();
    char me[32];
    if (own != NULL || net_own_address(me, sizeof(me))) {
        if (own != NULL) snprintf(me, sizeof(me), "%s", own);
        printf("# own address: %s\n", me);
        net_lo_tcp(me, 7103, 4L << 20);
    } else {
        printf("# no own address (no card): skipped\n");
    }
    printf("# POSIXTEST net: %d passed, %d failed\n", net_number - net_failed, net_failed);
    return net_failed;
}

static int net_main(int argc, char **argv) {
    if (argc > 1 && (strcmp(argv[1], "-L") == 0 || strcmp(argv[1], "-l") == 0)) return net_loopback(argc > 2 ? argv[2] : NULL);
    const char *host = argc > 1 ? argv[1] : "10.0.2.2";

    /* getaddrinfo with a written address and a service name: */
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    int r = getaddrinfo(host, "http", &hints, &res);
    net_check(r == 0 && res != NULL && ntohs(((struct sockaddr_in *)res->ai_addr)->sin_port) == 80, "getaddrinfo");
    if (res != NULL) freeaddrinfo(res);

    /* TCP echo with send / recv, then read / write: */
    int s = socket(AF_INET, SOCK_STREAM, 0);
    net_check(s >= 3, "socket");
    struct sockaddr_in echo = net_at(host, 5555);
    net_check(connect(s, (struct sockaddr *)&echo, sizeof(echo)) == 0, "connect");
    int one = 1;
    net_check(setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) == 0, "TCP_NODELAY");
    net_check(send(s, "hello", 5, 0) == 5, "send");
    char buf[64] = {0};
    int got = 0;
    while (got < 5) {
        ssize_t n = recv(s, buf + got, sizeof(buf) - got, 0);
        if (n <= 0) break;
        got += (int)n;
    }
    net_check(got == 5 && memcmp(buf, "hello", 5) == 0, "recv");
    net_check(write(s, "abc", 3) == 3, "write");
    struct pollfd p = {s, POLLIN, 0};
    net_check(poll(&p, 1, 3000) == 1 && (p.revents & POLLIN), "poll");
    net_check(read(s, buf, 3) == 3 && memcmp(buf, "abc", 3) == 0, "read");
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    net_check(getpeername(s, (struct sockaddr *)&peer, &plen) == 0 && ntohs(peer.sin_port) == 5555, "getpeername");
    int type = 0;
    socklen_t tlen = sizeof(type);
    net_check(getsockopt(s, SOL_SOCKET, SO_TYPE, &type, &tlen) == 0 && type == SOCK_STREAM, "SO_TYPE");
    /* select: nothing to read now: */
    fd_set rd;
    FD_ZERO(&rd);
    FD_SET(s, &rd);
    struct timeval tv = {0, 100000};
    net_check(select(s + 1, &rd, NULL, NULL, &tv) == 0, "select timeout");
    close(s);

    /* Nonblocking connect: */
    s = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    r = connect(s, (struct sockaddr *)&echo, sizeof(echo));
    net_check(r == 0 || errno == EINPROGRESS, "nonblocking connect");
    p = (struct pollfd){s, POLLOUT, 0};
    poll(&p, 1, 5000);
    int err = -1;
    socklen_t elen = sizeof(err);
    net_check(getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &elen) == 0 && err == 0, "SO_ERROR after connect");
    errno = 0;
    net_check(recv(s, buf, sizeof(buf), 0) < 0 && errno == EAGAIN, "EAGAIN");
    close(s);

    /* Refused: */
    s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in closed = net_at(host, 5557);
    errno = 0;
    net_check(connect(s, (struct sockaddr *)&closed, sizeof(closed)) < 0 && (errno == ECONNREFUSED || errno == ECONNRESET), "ECONNREFUSED");
    close(s);

    /* UDP echo: */
    s = socket(AF_INET, SOCK_DGRAM, 0);
    struct timeval wait = {3, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
    struct sockaddr_in udp = net_at(host, 5556);
    net_check(sendto(s, "datagram", 8, 0, (struct sockaddr *)&udp, sizeof(udp)) == 8, "sendto");
    struct sockaddr_in from;
    socklen_t flen = sizeof(from);
    ssize_t n = recvfrom(s, buf, sizeof(buf), 0, (struct sockaddr *)&from, &flen);
    net_check(n == 8 && memcmp(buf, "datagram", 8) == 0 && ntohs(from.sin_port) == 5556, "recvfrom");
    close(s);

    /* Not supported: */
    errno = 0;
    net_check(socket(AF_INET6, SOCK_STREAM, 0) < 0 && errno == EAFNOSUPPORT, "AF_INET6: EAFNOSUPPORT");

    printf("# POSIXTEST net: %d passed, %d failed\n", net_number - net_failed, net_failed);
    return net_failed;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "net") == 0) return net_main(argc - 1, argv + 1);
    if (argc > 1) {
        return tool(argc, argv);
    }
    pid_t probe;
    char *pargv[] = {"posixtest", "exit", "0", NULL};
    int tasks = posix_spawnp(&probe, "posixtest", NULL, NULL, pargv, NULL) == 0;
    if (tasks) {
        waitpid(probe, NULL, 0);
    }
    printf("# POSIXTEST: %s\n", tasks ? "tasks run at the same time here" : "one task here");
    test_basics();
    test_file_times();
    test_pipe_alone();
    test_dup();
    test_mmap();
    test_headers(tasks);
    test_math();
    test_terminal();
    test_signals_self(tasks);
    if (tasks) {
        test_spawn();
        test_spawn_env();
        test_pipeline();
        test_vfork();
        test_signals_tasks();
        test_threads();
        test_futex_locks();
        test_faults();
    } else {
        skip("posix_spawn, waitpid");
        skip("posix_spawn with envp");
        skip("pipelines");
        skip("vfork");
        skip("signals between tasks");
        pthread_t t;
        check(pthread_create(&t, NULL, add, NULL) == ENOSYS, "pthread_create: ENOSYS", NULL);
        pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
        check(pthread_mutex_lock(&m) == 0 && pthread_mutex_unlock(&m) == 0, "mutex in the one thread", NULL);
        pthread_cond_t c = PTHREAD_COND_INITIALIZER;
        struct timespec at = in_ms(CLOCK_REALTIME, 20);
        pthread_mutex_lock(&m);
        check(pthread_cond_timedwait(&c, &m, &at) == ETIMEDOUT && pthread_mutex_unlock(&m) == 0,
              "pthread_cond_timedwait in the one thread", NULL);
    }
    printf("# posixtest: %d passed, %d failed, %d skipped\n", passed, failed, skipped);
    return failed == 0 ? 0 : 1;
}
