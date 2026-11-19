/* Unix extras for ported programs (each header says what ZDOS makes of it):
 * libgen.h, err.h, sys/resource.h, sys/times.h, grp.h, langinfo.h,
 * sys/uio.h, sys/file.h, dlfcn.h, netdb.h and address text (the sockets are
 * zdos_net.c's), iconv.h, syslog.h, search.h, sys/random.h (and arc4random);
 * pread / pwrite. */
#include "zdos.h"
#include "zdos_internal.h"
#include "zdos_errno.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <err.h>
#include <errno.h>
#include <grp.h>
#include <iconv.h>
#include <langinfo.h>
#include <libgen.h>
#include <limits.h>
#include <netdb.h>
#include <pwd.h>
#include <search.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/times.h>
#include <sys/uio.h>
#include <syslog.h>
#include <unistd.h>
#include <wchar.h>

/* PREAD, PWRITE: AT AN OFFSET, THE FILE POSITION KEPT */

ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved < 0 || lseek(fd, offset, SEEK_SET) < 0) {
        return -1;
    }
    ssize_t n = read(fd, buf, count);
    int e = errno;
    lseek(fd, saved, SEEK_SET);
    errno = e;
    return n;
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved < 0 || lseek(fd, offset, SEEK_SET) < 0) {
        return -1;
    }
    ssize_t n = write(fd, buf, count);
    int e = errno;
    lseek(fd, saved, SEEK_SET);
    errno = e;
    return n;
}

/* libgen.h */

static int is_sep(char c) {
    return c == '/' || c == '\\';
}

char *basename(char *path) {
    if (path == NULL || path[0] == '\0') {
        return ".";
    }
    size_t n = strlen(path);
    while (n > 1 && is_sep(path[n - 1])) {
        path[--n] = '\0';
    }
    if (n == 1 && is_sep(path[0])) {
        return path;
    }
    size_t start = n;
    while (start > 0 && !is_sep(path[start - 1]) && !(start == 2 && path[1] == ':')) {
        start--;
    }
    return path + start;
}

char *dirname(char *path) {
    if (path == NULL || path[0] == '\0') {
        return ".";
    }
    size_t root = (path[0] != '\0' && path[1] == ':') ? 2 : 0; /* "C:" stays */
    size_t n = strlen(path);
    while (n > root + 1 && is_sep(path[n - 1])) {
        n--;
    }
    while (n > root && !is_sep(path[n - 1])) {
        n--;
    }
    if (n == root) {
        if (root == 0) {
            return ".";
        }
        path[root] = '\0';
        return path;
    }
    while (n > root + 1 && is_sep(path[n - 1])) {
        n--;
    }
    path[n] = '\0';
    return path;
}

/* err.h */

static char prog_name[64];

const char *getprogname(void) {
    if (prog_name[0] == '\0' && zdos != NULL) {
        char full[300];
        size_t n = zdos->programs->program_path(full, sizeof(full) - 1);
        full[n] = '\0';
        char *base = basename(full);
        char *dot = strrchr(base, '.');
        if (dot != NULL && strcasecmp(dot, ".APP") == 0) {
            *dot = '\0';
        }
        for (char *c = base; *c != '\0'; c++) {
            if (*c >= 'A' && *c <= 'Z') {
                *c = (char)(*c + 32);
            }
        }
        snprintf(prog_name, sizeof(prog_name), "%s", base);
    }
    return prog_name;
}

void setprogname(const char *name) {
    snprintf(prog_name, sizeof(prog_name), "%s", name);
}

static void report(int with_errno, const char *format, va_list ap) {
    int e = errno;
    fprintf(stderr, "%s: ", getprogname());
    if (format != NULL) {
        vfprintf(stderr, format, ap);
        if (with_errno) {
            fputs(": ", stderr);
        }
    }
    if (with_errno) {
        fputs(strerror(e), stderr);
    }
    fputc('\n', stderr);
}

void vwarn(const char *format, va_list ap) {
    report(1, format, ap);
}

void vwarnx(const char *format, va_list ap) {
    report(0, format, ap);
}

void verr(int code, const char *format, va_list ap) {
    report(1, format, ap);
    exit(code);
}

void verrx(int code, const char *format, va_list ap) {
    report(0, format, ap);
    exit(code);
}

void warn(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    vwarn(format, ap);
    va_end(ap);
}

void warnx(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    vwarnx(format, ap);
    va_end(ap);
}

void err(int code, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    verr(code, format, ap);
}

void errx(int code, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    verrx(code, format, ap);
}

/* sys/resource.h, sys/times.h */

static rlim_t soft_limits[RLIM_NLIMITS];
static int limits_set;

static rlim_t hard_limit(int resource) {
    switch (resource) {
        case RLIMIT_NOFILE: return ZDOS_MAX_FILES;
        case RLIMIT_STACK: return 1024 * 1024; /* a program's (src/kernel/loader.zig) */
        default: return RLIM_INFINITY;
    }
}

int getrlimit(int resource, struct rlimit *limit) {
    if (resource < 0 || resource >= RLIM_NLIMITS) {
        errno = EINVAL;
        return -1;
    }
    limit->rlim_max = hard_limit(resource);
    limit->rlim_cur = (limits_set & (1 << resource)) ? soft_limits[resource] : limit->rlim_max;
    return 0;
}

int setrlimit(int resource, const struct rlimit *limit) {
    if (resource < 0 || resource >= RLIM_NLIMITS || limit->rlim_cur > limit->rlim_max) {
        errno = EINVAL;
        return -1;
    }
    if (limit->rlim_max > hard_limit(resource)) {
        errno = EPERM;
        return -1;
    }
    soft_limits[resource] = limit->rlim_cur;
    limits_set |= 1 << resource;
    return 0;
}


int getrusage(int who, struct rusage *usage) {
    memset(usage, 0, sizeof(*usage));
    if (who == RUSAGE_SELF || who == RUSAGE_THREAD) {
        uint64_t ms = zdos_own_cpu_ms();
        usage->ru_utime.tv_sec = (time_t)(ms / 1000);
        usage->ru_utime.tv_usec = (suseconds_t)(ms % 1000 * 1000);
    } else if (who != RUSAGE_CHILDREN) {
        errno = EINVAL;
        return -1;
    }
    return 0;
}

clock_t times(struct tms *t) {
    if (t != NULL) {
        t->tms_utime = (clock_t)zdos_own_cpu_ms();
        t->tms_stime = 0;
        t->tms_cutime = 0;
        t->tms_cstime = 0;
    }
    return zdos != NULL && zdos->time->millis != NULL ? (clock_t)zdos->time->millis() : 0;
}

/* Niceness -20..19 <-> task priority 31..1 (16 = nice 0; higher runs first) */
static int task_info(id_t who, zdos_task_info *out) {
    if (zdos == NULL || zdos->tasks->info == NULL || zdos->tasks->id == NULL) {
        return 0;
    }
    uint32_t id = who == 0 ? zdos->tasks->id() : who;
    for (uint32_t i = 0; zdos->tasks->info(i, out); i++) {
        if (out->id == id) {
            return 1;
        }
    }
    return 0;
}

int getpriority(int which, id_t who) {
    zdos_task_info info;
    if (which != PRIO_PROCESS) {
        return 0;
    }
    if (!task_info(who, &info)) {
        errno = ESRCH;
        return -1;
    }
    errno = 0;
    return (16 - (int)info.base_priority) * 20 / 16;
}

int setpriority(int which, id_t who, int prio) {
    if (which != PRIO_PROCESS) {
        return 0;
    }
    if (prio < -20) {
        prio = -20;
    }
    if (prio > 19) {
        prio = 19;
    }
    int task_prio = 16 - prio * 16 / 20;
    uint32_t id = who != 0 ? who : (zdos != NULL && zdos->tasks->id != NULL ? zdos->tasks->id() : 0);
    if (zdos == NULL || zdos->tasks->set_priority == NULL || !zdos->tasks->set_priority(id, (uint32_t)task_prio)) {
        errno = zdos != NULL && zdos->programs->last_error() == ZDOS_ERROR_ACCESS_DENIED ? EPERM : ESRCH;
        return -1;
    }
    return 0;
}

/* grp.h: \CONF\GROUPS.CFG, "NAME:GID:MEMBER,MEMBER" */

#define GR_MAX 32
#define GR_MEMBERS 64

static char gr_text[8 * 1024];
static struct group gr_list[GR_MAX];
static char *gr_members[GR_MAX][GR_MEMBERS + 1];
static int gr_count;
static int gr_next;

static void gr_load(void) {
    gr_count = 0;
    const char *spec = getenv("COMSPEC");
    char path[] = "C:\\CONF\\GROUPS.CFG";
    if (spec != NULL && spec[0] != '\0' && spec[1] == ':') {
        path[0] = spec[0];
    }
    FILE *f = fopen(path, "r");
    size_t len = 0;
    if (f != NULL) {
        len = fread(gr_text, 1, sizeof(gr_text) - 1, f);
        fclose(f);
    }
    gr_text[len] = '\0';
    char *line = gr_text;
    int have_root = 0, have_admins = 0;
    while (line != NULL && *line != '\0' && gr_count < GR_MAX) {
        char *next = strchr(line, '\n');
        if (next != NULL) {
            *next++ = '\0';
        }
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\r' || line[n - 1] == ' ')) {
            line[--n] = '\0';
        }
        char *gid = line[0] != '#' ? strchr(line, ':') : NULL;
        if (gid != NULL) {
            *gid++ = '\0';
            char *members = strchr(gid, ':');
            if (members != NULL) {
                *members++ = '\0';
            }
            struct group *g = &gr_list[gr_count];
            g->gr_name = line;
            g->gr_passwd = "x";
            g->gr_gid = (gid_t)strtoul(gid, NULL, 10);
            int m = 0;
            char *save = NULL;
            for (char *tok = members != NULL ? strtok_r(members, ",", &save) : NULL; tok != NULL && m < GR_MEMBERS;
                 tok = strtok_r(NULL, ",", &save)) {
                gr_members[gr_count][m++] = tok;
            }
            gr_members[gr_count][m] = NULL;
            g->gr_mem = gr_members[gr_count];
            have_root |= strcasecmp(line, "root") == 0;
            have_admins |= strcasecmp(line, "admins") == 0;
            gr_count++;
        }
        line = next;
    }
    /* As apps/zdos/users.zig: root (0) and admins (10) are always there */
    static const struct { const char *name; gid_t gid; } fixed[] = {{"ROOT", 0}, {"ADMINS", 10}};
    for (int i = 0; i < 2 && gr_count < GR_MAX; i++) {
        if ((i == 0 && have_root) || (i == 1 && have_admins)) {
            continue;
        }
        gr_list[gr_count] = (struct group){(char *)fixed[i].name, "x", fixed[i].gid, gr_members[gr_count]};
        gr_members[gr_count][0] = NULL;
        gr_count++;
    }
}

/* A user's own group (numbered as the user), as a group entry */
static struct group own_group;
static char *own_members[2];

static struct group *user_group(struct passwd *p) {
    own_group.gr_name = p->pw_name;
    own_group.gr_passwd = "x";
    own_group.gr_gid = p->pw_uid;
    own_members[0] = p->pw_name;
    own_members[1] = NULL;
    own_group.gr_mem = own_members;
    return &own_group;
}

struct group *getgrnam(const char *name) {
    gr_load();
    for (int i = 0; i < gr_count; i++) {
        if (strcasecmp(gr_list[i].gr_name, name) == 0) {
            return &gr_list[i];
        }
    }
    struct passwd *p = getpwnam(name);
    return p != NULL ? user_group(p) : NULL;
}

struct group *getgrgid(gid_t gid) {
    gr_load();
    for (int i = 0; i < gr_count; i++) {
        if (gr_list[i].gr_gid == gid) {
            return &gr_list[i];
        }
    }
    struct passwd *p = getpwuid(gid);
    return p != NULL ? user_group(p) : NULL;
}

/* A group copied into the caller's buffer: the member pointers first
   (aligned), then the strings */
static int group_copy(const struct group *g, struct group *grp, char *buf, size_t len, struct group **result) {
    *result = NULL;
    if (g == NULL) {
        return 0;
    }
    const char *passwd = g->gr_passwd != NULL ? g->gr_passwd : "";
    size_t n = 0, strings = strlen(g->gr_name) + 1 + strlen(passwd) + 1;
    while (g->gr_mem != NULL && g->gr_mem[n] != NULL) {
        strings += strlen(g->gr_mem[n]) + 1;
        n++;
    }
    size_t skip = (sizeof(char *) - (uintptr_t)buf % sizeof(char *)) % sizeof(char *);
    if (len < skip || len - skip < (n + 1) * sizeof(char *) + strings) {
        return ERANGE;
    }
    char **mem = (char **)(void *)(buf + skip);
    char *p = (char *)(mem + n + 1);
    size_t k = strlen(g->gr_name) + 1;
    grp->gr_name = memcpy(p, g->gr_name, k);
    p += k;
    k = strlen(passwd) + 1;
    grp->gr_passwd = memcpy(p, passwd, k);
    p += k;
    for (size_t i = 0; i < n; i++) {
        k = strlen(g->gr_mem[i]) + 1;
        mem[i] = memcpy(p, g->gr_mem[i], k);
        p += k;
    }
    mem[n] = NULL;
    grp->gr_mem = mem;
    grp->gr_gid = g->gr_gid;
    *result = grp;
    return 0;
}

int getgrnam_r(const char *name, struct group *grp, char *buf, size_t len, struct group **result) {
    return group_copy(getgrnam(name), grp, buf, len, result);
}

int getgrgid_r(gid_t gid, struct group *grp, char *buf, size_t len, struct group **result) {
    return group_copy(getgrgid(gid), grp, buf, len, result);
}

void setgrent(void) {
    gr_next = 0;
}

void endgrent(void) {
    gr_next = 0;
}

struct group *getgrent(void) {
    if (gr_next == 0) {
        gr_load();
    }
    return gr_next < gr_count ? &gr_list[gr_next++] : NULL;
}

int getgrouplist(const char *user, gid_t group, gid_t *groups, int *count) {
    gr_load();
    int n = 0;
    int room = *count;
    if (n < room) {
        groups[n] = group;
    }
    n++;
    for (int i = 0; i < gr_count; i++) {
        if (gr_list[i].gr_gid == group) {
            continue;
        }
        for (char **m = gr_list[i].gr_mem; *m != NULL; m++) {
            if (strcasecmp(*m, user) == 0) {
                if (n < room) {
                    groups[n] = gr_list[i].gr_gid;
                }
                n++;
                break;
            }
        }
    }
    *count = n;
    return n <= room ? n : -1;
}

int initgroups(const char *user, gid_t group) {
    gid_t list[16];
    int count = 16;
    if (getgrouplist(user, group, list, &count) < 0) {
        count = 16;
    }
    return setgroups((size_t)count, list);
}

/* langinfo.h */

static const char *const langinfo_texts[] = {
    [CODESET] = "UTF-8", [D_T_FMT] = "%a %b %e %H:%M:%S %Y", [D_FMT] = "%m/%d/%y", [T_FMT] = "%H:%M:%S",
    [T_FMT_AMPM] = "%I:%M:%S %p", [AM_STR] = "AM", [PM_STR] = "PM",
    [DAY_1] = "Sunday", [DAY_2] = "Monday", [DAY_3] = "Tuesday", [DAY_4] = "Wednesday", [DAY_5] = "Thursday",
    [DAY_6] = "Friday", [DAY_7] = "Saturday",
    [ABDAY_1] = "Sun", [ABDAY_2] = "Mon", [ABDAY_3] = "Tue", [ABDAY_4] = "Wed", [ABDAY_5] = "Thu", [ABDAY_6] = "Fri",
    [ABDAY_7] = "Sat",
    [MON_1] = "January", [MON_2] = "February", [MON_3] = "March", [MON_4] = "April", [MON_5] = "May", [MON_6] = "June",
    [MON_7] = "July", [MON_8] = "August", [MON_9] = "September", [MON_10] = "October", [MON_11] = "November",
    [MON_12] = "December",
    [ABMON_1] = "Jan", [ABMON_2] = "Feb", [ABMON_3] = "Mar", [ABMON_4] = "Apr", [ABMON_5] = "May", [ABMON_6] = "Jun",
    [ABMON_7] = "Jul", [ABMON_8] = "Aug", [ABMON_9] = "Sep", [ABMON_10] = "Oct", [ABMON_11] = "Nov", [ABMON_12] = "Dec",
    [ERA] = "", [ERA_D_FMT] = "", [ALT_DIGITS] = "", [ERA_D_T_FMT] = "", [ERA_T_FMT] = "",
    [RADIXCHAR] = ".", [THOUSEP] = "", [YESEXPR] = "^[yY]", [NOEXPR] = "^[nN]", [CRNCYSTR] = "-",
};

char *nl_langinfo(nl_item item) {
    if (item < 0 || item >= (nl_item)(sizeof(langinfo_texts) / sizeof(langinfo_texts[0])) || langinfo_texts[item] == NULL) {
        return "";
    }
    return (char *)langinfo_texts[item];
}

/* sys/uio.h */

ssize_t readv(int fd, const struct iovec *iov, int count) {
    ssize_t total = 0;
    for (int i = 0; i < count; i++) {
        ssize_t n = read(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) {
            return total > 0 ? total : -1;
        }
        total += n;
        if ((size_t)n < iov[i].iov_len) {
            break;
        }
    }
    return total;
}

ssize_t writev(int fd, const struct iovec *iov, int count) {
    ssize_t total = 0;
    for (int i = 0; i < count; i++) {
        ssize_t n = write(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) {
            return total > 0 ? total : -1;
        }
        total += n;
        if ((size_t)n < iov[i].iov_len) {
            break;
        }
    }
    return total;
}

ssize_t preadv(int fd, const struct iovec *iov, int count, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved < 0 || lseek(fd, offset, SEEK_SET) < 0) {
        return -1;
    }
    ssize_t n = readv(fd, iov, count);
    lseek(fd, saved, SEEK_SET);
    return n;
}

ssize_t pwritev(int fd, const struct iovec *iov, int count, off_t offset) {
    off_t saved = lseek(fd, 0, SEEK_CUR);
    if (saved < 0 || lseek(fd, offset, SEEK_SET) < 0) {
        return -1;
    }
    ssize_t n = writev(fd, iov, count);
    lseek(fd, saved, SEEK_SET);
    return n;
}

/* sys/file.h: LOCKS OF A WHOLE FILE */

/* As BSD's: the open file's (dup copies share it), between programs too;
   files->lock on the whole file, converted in place. The standard streams
   have none to take; a ZDOS without locks (NOT_SUPPORTED) grants them. */
int flock(int fd, int operation) {
    int op = operation & ~LOCK_NB;
    if (op != LOCK_SH && op != LOCK_EX && op != LOCK_UN) {
        errno = EINVAL;
        return -1;
    }
    int32_t h = zdos_fd_spawn_handle(fd);
    if (h == -100) {
        errno = EBADF;
        return -1;
    }
    if (h < 0) {
        return 0;
    }
    bool ok = op == LOCK_UN ? zdos->files->unlock(h, 0, 0)
                            : zdos->files->lock(h, 0, 0, op == LOCK_EX ? ZDOS_LOCK_EXCLUSIVE : 0,
                                                (operation & LOCK_NB) ? 0 : -1);
    if (ok) {
        return 0;
    }
    uint32_t e = zdos->programs->last_error();
    if (e == ZDOS_ERROR_NOT_SUPPORTED || (op == LOCK_UN && e == ZDOS_ERROR_INVALID_ARGUMENT)) {
        return 0; /* nothing held, or nothing to hold it with */
    }
    errno = e == ZDOS_ERROR_WOULD_BLOCK ? EWOULDBLOCK : zdos_errno_from_last_error();
    return -1;
}

/* dlfcn.h: no shared libraries; dlsym answers from the tables the
   program registers */

#define DL_TABLES 16
static const char *dl_error;
static char dl_self;
static const zdos_dlsym_entry *dl_tables[DL_TABLES];
static int dl_table_count;

int zdos_dlsym_register(const zdos_dlsym_entry *table) {
    if (dl_table_count == DL_TABLES) {
        errno = ENOMEM;
        return -1;
    }
    dl_tables[dl_table_count++] = table;
    return 0;
}

void *dlopen(const char *file, int mode) {
    (void)mode;
    if (file == NULL) {
        return &dl_self;
    }
    dl_error = "ZDOS has no shared libraries";
    return NULL;
}

void *dlsym(void *handle, const char *name) {
    if (handle == RTLD_DEFAULT || handle == &dl_self) {
        for (int t = dl_table_count - 1; t >= 0; t--) { /* the last registered first */
            for (const zdos_dlsym_entry *e = dl_tables[t]; e->name != NULL; e++) {
                if (strcmp(e->name, name) == 0) {
                    return e->address;
                }
            }
        }
    }
    dl_error = "symbol not found (ZDOS has no dynamic linking)";
    return NULL;
}

int dlclose(void *handle) {
    (void)handle;
    return 0;
}

char *dlerror(void) {
    const char *e = dl_error;
    dl_error = NULL;
    return (char *)e;
}

/* arpa/inet.h: ADDRESS TEXT */

int inet_aton(const char *text, struct in_addr *out) {
    uint32_t parts[4];
    int n = 0;
    const char *s = text;
    while (n < 4) {
        if (*s < '0' || *s > '9') {
            return 0;
        }
        char *end;
        unsigned long v = strtoul(s, &end, 0);
        parts[n++] = (uint32_t)v;
        s = end;
        if (*s != '.') {
            break;
        }
        s++;
    }
    if (*s != '\0') {
        return 0;
    }
    uint32_t addr;
    switch (n) {
        case 1: addr = parts[0]; break;
        case 2: if (parts[0] > 255 || parts[1] > 0xFFFFFF) return 0; addr = parts[0] << 24 | parts[1]; break;
        case 3: if (parts[0] > 255 || parts[1] > 255 || parts[2] > 0xFFFF) return 0; addr = parts[0] << 24 | parts[1] << 16 | parts[2]; break;
        default:
            for (int i = 0; i < 4; i++) {
                if (parts[i] > 255) {
                    return 0;
                }
            }
            addr = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3];
    }
    if (out != NULL) {
        out->s_addr = htonl(addr);
    }
    return 1;
}

in_addr_t inet_addr(const char *text) {
    struct in_addr a;
    return inet_aton(text, &a) ? a.s_addr : INADDR_NONE;
}

char *inet_ntoa(struct in_addr addr) {
    static char buf[INET_ADDRSTRLEN];
    uint32_t a = ntohl(addr.s_addr);
    snprintf(buf, sizeof(buf), "%u.%u.%u.%u", a >> 24, (a >> 16) & 255, (a >> 8) & 255, a & 255);
    return buf;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int pton4(const char *s, uint8_t *out) {
    int n = 0;
    while (n < 4) {
        int v = 0, digits = 0;
        while (*s >= '0' && *s <= '9') {
            v = v * 10 + (*s++ - '0');
            if (++digits > 3 || v > 255) {
                return 0;
            }
        }
        if (digits == 0) {
            return 0;
        }
        out[n++] = (uint8_t)v;
        if (n < 4) {
            if (*s++ != '.') {
                return 0;
            }
        }
    }
    return *s == '\0';
}

static int pton6(const char *s, uint8_t *out) {
    uint16_t words[8];
    int n = 0, gap = -1;
    if (s[0] == ':' && s[1] == ':') {
        gap = 0;
        s += 2;
    }
    while (*s != '\0' && n < 8) {
        if (strchr(s, '.') != NULL && strchr(s, ':') == NULL) {
            uint8_t v4[4];
            if (n > 6 || !pton4(s, v4)) {
                return 0;
            }
            words[n++] = (uint16_t)(v4[0] << 8 | v4[1]);
            words[n++] = (uint16_t)(v4[2] << 8 | v4[3]);
            s += strlen(s);
            break;
        }
        int v = 0, digits = 0, d;
        while ((d = hex_digit(*s)) >= 0) {
            v = v * 16 + d;
            s++;
            if (++digits > 4) {
                return 0;
            }
        }
        if (digits == 0) {
            return 0;
        }
        words[n++] = (uint16_t)v;
        if (*s == ':') {
            s++;
            if (*s == ':') {
                if (gap >= 0) {
                    return 0;
                }
                gap = n;
                s++;
            } else if (*s == '\0') {
                return 0;
            }
        }
    }
    if (*s != '\0' || (gap < 0 && n != 8) || (gap >= 0 && n > 7)) {
        return 0;
    }
    memset(out, 0, 16);
    int tail = gap >= 0 ? n - gap : 0;
    for (int i = 0; i < n - tail; i++) {
        out[2 * i] = (uint8_t)(words[i] >> 8);
        out[2 * i + 1] = (uint8_t)words[i];
    }
    for (int i = 0; i < tail; i++) {
        int at = 8 - tail + i;
        out[2 * at] = (uint8_t)(words[gap + i] >> 8);
        out[2 * at + 1] = (uint8_t)words[gap + i];
    }
    return 1;
}

int inet_pton(int family, const char *text, void *out) {
    if (family == AF_INET) {
        return pton4(text, out);
    }
    if (family == AF_INET6) {
        return pton6(text, out);
    }
    errno = EAFNOSUPPORT;
    return -1;
}

const char *inet_ntop(int family, const void *addr, char *out, socklen_t size) {
    char buf[INET6_ADDRSTRLEN];
    const uint8_t *a = addr;
    if (family == AF_INET) {
        snprintf(buf, sizeof(buf), "%u.%u.%u.%u", a[0], a[1], a[2], a[3]);
    } else if (family == AF_INET6) {
        /* The longest run of zero words (two or more) becomes "::" */
        int best = -1, best_len = 0;
        for (int i = 0; i < 8;) {
            int j = i;
            while (j < 8 && a[2 * j] == 0 && a[2 * j + 1] == 0) {
                j++;
            }
            if (j - i > best_len && j - i > 1) {
                best = i;
                best_len = j - i;
            }
            i = j > i ? j : i + 1;
        }
        size_t n = 0;
        for (int i = 0; i < 8; i++) {
            if (i == best) {
                n += (size_t)snprintf(buf + n, sizeof(buf) - n, "::");
                i += best_len - 1;
                continue;
            }
            if (n > 0 && buf[n - 1] != ':') {
                buf[n++] = ':';
            }
            n += (size_t)snprintf(buf + n, sizeof(buf) - n, "%x", a[2 * i] << 8 | a[2 * i + 1]);
        }
        buf[n] = '\0';
    } else {
        errno = EAFNOSUPPORT;
        return NULL;
    }
    if (strlen(buf) >= size) {
        errno = ENOSPC;
        return NULL;
    }
    strcpy(out, buf);
    return out;
}

/* netdb.h: NUMBERS, LOCALHOST, THEN ZDOS (HOSTS.CFG, DNS) */

// The machine's own name (gethostname): every started interface's
// address, the default route's first (as Windows and
// nss-myhostname give them), else 127.0.0.1; 0 if not that name
#define OWN_MAX 8
static int own_name4(const char *name, struct in_addr *out, int max) {
    char host[256];
    if (gethostname(host, sizeof(host)) != 0 || strcasecmp(name, host) != 0) {
        return 0;
    }
    int n = 0;
    zdos_net_info info;
    for (int pass = 0; pass < 2; pass++) {
        for (uint32_t i = 0; zdos != NULL && zdos->net->interface != NULL && zdos->net->interface(i, &info); i++) {
            int first = (info.flags & ZDOS_NET_DEFAULT_ROUTE) != 0;
            if (!(info.flags & ZDOS_NET_STARTED) || first != (pass == 0) || n == max ||
                !(info.address[0] | info.address[1] | info.address[2] | info.address[3])) {
                continue;
            }
            memcpy(&out[n++].s_addr, info.address, 4);
        }
    }
    if (n == 0) {
        out[n++].s_addr = htonl(INADDR_LOOPBACK);
    }
    return n;
}

// A name's IPv4 address through ZDOS; false if it has none
static bool resolve4(const char *name, struct in_addr *out) {
    uint8_t a[4];
    if (own_name4(name, out, 1) > 0) {
        return true;
    }
    if (zdos == NULL || !zdos->net->resolve(name, strlen(name), a)) {
        return false;
    }
    memcpy(&out->s_addr, a, 4);
    return true;
}

static const struct {
    const char *name;
    uint16_t port;
} services[] = {
    {"ftp", 21}, {"ssh", 22}, {"telnet", 23}, {"smtp", 25}, {"domain", 53}, {"http", 80},
    {"pop3", 110}, {"ntp", 123}, {"imap", 143}, {"https", 443}, {"submission", 587},
};

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    int family = hints != NULL ? hints->ai_family : AF_UNSPEC;
    uint16_t port = 0;
    if (service != NULL) {
        char *end;
        unsigned long p = strtoul(service, &end, 10);
        if (*end != '\0' || p > 65535) {
            struct servent *se = getservbyname(service, NULL);
            if (se == NULL) {
                return EAI_SERVICE;
            }
            p = ntohs((uint16_t)se->s_port);
        }
        port = (uint16_t)p;
    }
    struct in_addr v4;
    uint8_t v6[16];
    int is4 = 0, is6 = 0;
    if (node == NULL || strcmp(node, "localhost") == 0) {
        int passive = hints != NULL && (hints->ai_flags & AI_PASSIVE) && node == NULL;
        if (family == AF_INET6) {
            memset(v6, 0, 16);
            if (!passive) {
                v6[15] = 1;
            }
            is6 = 1;
        } else {
            v4.s_addr = htonl(passive ? INADDR_ANY : INADDR_LOOPBACK);
            is4 = 1;
        }
    } else if (family != AF_INET6 && inet_aton(node, &v4)) {
        is4 = 1;
    } else if (family != AF_INET && pton6(node, v6)) {
        is6 = 1;
    } else if (family != AF_INET6 && (hints == NULL || !(hints->ai_flags & AI_NUMERICHOST)) && resolve4(node, &v4)) {
        is4 = 1;
    } else {
        return EAI_NONAME;
    }
    struct addrinfo *ai = calloc(1, sizeof(*ai) + sizeof(struct sockaddr_in6));
    if (ai == NULL) {
        return EAI_MEMORY;
    }
    ai->ai_socktype = hints != NULL ? hints->ai_socktype : 0;
    ai->ai_protocol = hints != NULL ? hints->ai_protocol : 0;
    ai->ai_addr = (struct sockaddr *)(ai + 1);
    if (is4) {
        struct sockaddr_in *sin = (struct sockaddr_in *)ai->ai_addr;
        sin->sin_family = AF_INET;
        sin->sin_port = htons(port);
        sin->sin_addr = v4;
        ai->ai_family = AF_INET;
        ai->ai_addrlen = sizeof(*sin);
    } else {
        (void)is6;
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ai->ai_addr;
        sin6->sin6_family = AF_INET6;
        sin6->sin6_port = htons(port);
        memcpy(&sin6->sin6_addr, v6, 16);
        ai->ai_family = AF_INET6;
        ai->ai_addrlen = sizeof(*sin6);
    }
    *res = ai;
    return 0;
}

void freeaddrinfo(struct addrinfo *res) {
    while (res != NULL) {
        struct addrinfo *next = res->ai_next;
        free(res);
        res = next;
    }
}

const char *gai_strerror(int code) {
    switch (code) {
        case EAI_NONAME: return "Name not known";
        case EAI_SERVICE: return "Service not known";
        case EAI_MEMORY: return "Out of memory";
        case EAI_FAMILY: return "Address family not supported";
        default: return "Name lookup failed";
    }
}

int getnameinfo(const struct sockaddr *addr, socklen_t len, char *host, socklen_t hostlen, char *serv, socklen_t servlen,
                int flags) {
    (void)len;
    (void)flags;
    uint16_t port;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        if (host != NULL && inet_ntop(AF_INET, &sin->sin_addr, host, hostlen) == NULL) {
            return EAI_FAIL;
        }
        port = ntohs(sin->sin_port);
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        if (host != NULL && inet_ntop(AF_INET6, &sin6->sin6_addr, host, hostlen) == NULL) {
            return EAI_FAIL;
        }
        port = ntohs(sin6->sin6_port);
    } else {
        return EAI_FAMILY;
    }
    if (serv != NULL && servlen > 0) {
        snprintf(serv, servlen, "%u", port);
    }
    return 0;
}

struct hostent *gethostbyname(const char *name) {
    static struct in_addr addr[OWN_MAX];
    static char *addrs[OWN_MAX + 1];
    static struct hostent h;
    static char *no_aliases[1];
    static char host[256];
    int n = 1;
    if (strcmp(name, "localhost") == 0) {
        addr[0].s_addr = htonl(INADDR_LOOPBACK);
    } else if ((n = own_name4(name, addr, OWN_MAX)) == 0) {
        n = 1;
        if (!inet_aton(name, &addr[0]) && !resolve4(name, &addr[0])) {
            return NULL;
        }
    }
    snprintf(host, sizeof(host), "%s", name);
    for (int i = 0; i < n; i++) {
        addrs[i] = (char *)&addr[i];
    }
    addrs[n] = NULL;
    h.h_name = host;
    h.h_aliases = no_aliases;
    h.h_addrtype = AF_INET;
    h.h_length = 4;
    h.h_addr_list = addrs;
    return &h;
}

struct servent *getservbyname(const char *name, const char *proto) {
    static struct servent se;
    static char *no_aliases[1];
    static char tcp[] = "tcp";
    for (size_t i = 0; i < sizeof(services) / sizeof(services[0]); i++) {
        if (strcmp(services[i].name, name) == 0) {
            se.s_name = (char *)services[i].name;
            se.s_aliases = no_aliases;
            se.s_port = htons(services[i].port);
            se.s_proto = proto != NULL ? (char *)proto : tcp;
            return &se;
        }
    }
    return NULL;
}

/* iconv.h */

enum { CS_UTF8, CS_ASCII, CS_LATIN1, CS_CP437, CS_UTF16LE, CS_UTF16BE, CS_UTF16, CS_UTF32LE, CS_UTF32BE, CS_UTF32 };

typedef struct {
    int from, to;
    int bom_read, bom_written, big; /* UTF-16 / UTF-32 without LE or BE: byte order from the mark */
} converter;

static const uint16_t cp437_high[128] = {
    0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
    0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xA2, 0xA3, 0xA5, 0x20A7, 0x192,
    0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0x2310, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
    0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
    0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
    0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
    0x3B1, 0xDF, 0x393, 0x3C0, 0x3A3, 0x3C3, 0xB5, 0x3C4, 0x3A6, 0x398, 0x3A9, 0x3B4, 0x221E, 0x3C6, 0x3B5, 0x2229,
    0x2261, 0xB1, 0x2265, 0x2264, 0x2320, 0x2321, 0xF7, 0x2248, 0xB0, 0x2219, 0xB7, 0x221A, 0x207F, 0xB2, 0x25A0, 0xA0,
};

static int charset(const char *name) {
    char n[24];
    size_t k = 0;
    for (const char *p = name; *p != '\0' && *p != '/' && k < sizeof(n) - 1; p++) {
        if (*p != '-' && *p != '_') {
            n[k++] = (char)(*p >= 'a' && *p <= 'z' ? *p - 32 : *p);
        }
    }
    n[k] = '\0';
    static const struct { const char *name; int cs; } names[] = {
        {"UTF8", CS_UTF8}, {"ASCII", CS_ASCII}, {"USASCII", CS_ASCII}, {"ANSIX3.41968", CS_ASCII},
        {"ISO88591", CS_LATIN1}, {"LATIN1", CS_LATIN1}, {"L1", CS_LATIN1}, {"CP437", CS_CP437}, {"IBM437", CS_CP437},
        {"UTF16LE", CS_UTF16LE}, {"UTF16BE", CS_UTF16BE}, {"UTF16", CS_UTF16}, {"UCS2", CS_UTF16},
        {"UTF32LE", CS_UTF32LE}, {"UTF32BE", CS_UTF32BE}, {"UTF32", CS_UTF32}, {"UCS4", CS_UTF32}, {"WCHART", CS_UTF32LE},
        {"", CS_UTF8},
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(n, names[i].name) == 0) {
            return names[i].cs;
        }
    }
    return -1;
}

iconv_t iconv_open(const char *to, const char *from) {
    int t = charset(to), f = charset(from);
    if (t < 0 || f < 0) {
        errno = EINVAL;
        return (iconv_t)-1;
    }
    converter *c = calloc(1, sizeof(*c));
    if (c == NULL) {
        return (iconv_t)-1;
    }
    c->from = f;
    c->to = t;
    return c;
}

int iconv_close(iconv_t cd) {
    free(cd);
    return 0;
}

/* One character from in: its code point and bytes used; 0 if incomplete,
   -1 if invalid */
static int decode(converter *c, const unsigned char *in, size_t left, uint32_t *out) {
    switch (c->from) {
        case CS_UTF8: {
            mbstate_t st = {0};
            wchar_t w;
            size_t r = mbrtowc(&w, (const char *)in, left, &st);
            if (r == (size_t)-2) return 0;
            if (r == (size_t)-1) return -1;
            *out = (uint32_t)w;
            return r == 0 ? 1 : (int)r;
        }
        case CS_ASCII:
            if (in[0] >= 0x80) return -1;
            *out = in[0];
            return 1;
        case CS_LATIN1:
            *out = in[0];
            return 1;
        case CS_CP437:
            *out = in[0] < 0x80 ? in[0] : cp437_high[in[0] - 0x80];
            return 1;
        case CS_UTF16LE: case CS_UTF16BE: case CS_UTF16: {
            int big = c->from == CS_UTF16BE || (c->from == CS_UTF16 && c->big);
            if (left < 2) return 0;
            uint32_t u = big ? (uint32_t)(in[0] << 8 | in[1]) : (uint32_t)(in[1] << 8 | in[0]);
            if (c->from == CS_UTF16 && !c->bom_read) {
                c->bom_read = 1;
                if (u == 0xFEFF || u == 0xFFFE) {
                    c->big = (in[0] == 0xFE);
                    *out = 0xFEFF;
                    return -2; /* a mark: skipped */
                }
            }
            if (u >= 0xD800 && u <= 0xDBFF) {
                if (left < 4) return 0;
                uint32_t lo = big ? (uint32_t)(in[2] << 8 | in[3]) : (uint32_t)(in[3] << 8 | in[2]);
                if (lo < 0xDC00 || lo > 0xDFFF) return -1;
                *out = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
                return 4;
            }
            if (u >= 0xDC00 && u <= 0xDFFF) return -1;
            *out = u;
            return 2;
        }
        default: {
            int big = c->from == CS_UTF32BE || (c->from == CS_UTF32 && c->big);
            if (left < 4) return 0;
            uint32_t u = big ? (uint32_t)in[0] << 24 | (uint32_t)in[1] << 16 | (uint32_t)in[2] << 8 | in[3]
                             : (uint32_t)in[3] << 24 | (uint32_t)in[2] << 16 | (uint32_t)in[1] << 8 | in[0];
            if (c->from == CS_UTF32 && !c->bom_read) {
                c->bom_read = 1;
                if (u == 0xFEFF || u == 0xFFFE0000) {
                    c->big = in[0] == 0;
                    return -2;
                }
            }
            if (u > 0x10FFFF || (u >= 0xD800 && u <= 0xDFFF)) return -1;
            *out = u;
            return 4;
        }
    }
}

/* u into out: the bytes written; 0 if no room, -1 if the set lacks it */
static int encode(converter *c, uint32_t u, unsigned char *out, size_t left) {
    unsigned char buf[8];
    int n = 0;
    switch (c->to) {
        case CS_UTF8: {
            char tmp[4];
            n = (int)wcrtomb(tmp, (wchar_t)u, NULL);
            memcpy(buf, tmp, (size_t)n);
            break;
        }
        case CS_ASCII:
            if (u >= 0x80) return -1;
            buf[n++] = (unsigned char)u;
            break;
        case CS_LATIN1:
            if (u >= 0x100) return -1;
            buf[n++] = (unsigned char)u;
            break;
        case CS_CP437:
            if (u < 0x80) {
                buf[n++] = (unsigned char)u;
            } else {
                int found = -1;
                for (int i = 0; i < 128; i++) {
                    if (cp437_high[i] == u) {
                        found = i;
                        break;
                    }
                }
                if (found < 0) return -1;
                buf[n++] = (unsigned char)(0x80 + found);
            }
            break;
        case CS_UTF16LE: case CS_UTF16BE: case CS_UTF16: {
            int big = c->to == CS_UTF16BE;
            if (c->to == CS_UTF16 && !c->bom_written) { /* a mark first, little endian */
                buf[n++] = 0xFF;
                buf[n++] = 0xFE;
            }
            uint16_t w[2];
            int k = 0;
            if (u >= 0x10000) {
                w[k++] = (uint16_t)(0xD800 + ((u - 0x10000) >> 10));
                w[k++] = (uint16_t)(0xDC00 + ((u - 0x10000) & 0x3FF));
            } else {
                w[k++] = (uint16_t)u;
            }
            for (int i = 0; i < k; i++) {
                buf[n++] = (unsigned char)(big ? w[i] >> 8 : w[i]);
                buf[n++] = (unsigned char)(big ? w[i] : w[i] >> 8);
            }
            break;
        }
        default: {
            int big = c->to == CS_UTF32BE;
            if (c->to == CS_UTF32 && !c->bom_written) {
                buf[n++] = 0xFF; buf[n++] = 0xFE; buf[n++] = 0; buf[n++] = 0;
            }
            for (int i = 0; i < 4; i++) {
                buf[n++] = (unsigned char)(big ? u >> (24 - 8 * i) : u >> (8 * i));
            }
        }
    }
    if ((size_t)n > left) return 0;
    memcpy(out, buf, (size_t)n);
    c->bom_written = 1;
    return n;
}

size_t iconv(iconv_t cd, char **in, size_t *in_left, char **out, size_t *out_left) {
    converter *c = cd;
    if (in == NULL || *in == NULL) {
        c->bom_read = 0; /* back to the starting state */
        return 0;
    }
    size_t count = 0;
    while (*in_left > 0) {
        uint32_t u;
        int used = decode(c, (unsigned char *)*in, *in_left, &u);
        if (used == -2) { /* a byte order mark */
            int skip = (c->from == CS_UTF16) ? 2 : 4;
            *in += skip;
            *in_left -= (size_t)skip;
            continue;
        }
        if (used == 0) {
            errno = EINVAL;
            return (size_t)-1;
        }
        if (used < 0) {
            errno = EILSEQ;
            return (size_t)-1;
        }
        int wrote = encode(c, u, (unsigned char *)*out, *out_left);
        if (wrote == 0) {
            errno = E2BIG;
            return (size_t)-1;
        }
        if (wrote < 0) {
            errno = EILSEQ;
            return (size_t)-1;
        }
        *in += used;
        *in_left -= (size_t)used;
        *out += wrote;
        *out_left -= (size_t)wrote;
        count++;
    }
    (void)count;
    return 0;
}

/* syslog.h: TO STDERR */

static const char *log_ident;
static int log_mask = 0xFF;

void openlog(const char *ident, int option, int facility) {
    (void)option;
    (void)facility;
    log_ident = ident;
}

void closelog(void) {
    log_ident = NULL;
}

int setlogmask(int mask) {
    int old = log_mask;
    if (mask != 0) {
        log_mask = mask;
    }
    return old;
}

void vsyslog(int priority, const char *format, va_list ap) {
    if (!(log_mask & LOG_MASK(priority & 7))) {
        return;
    }
    fprintf(stderr, "%s: ", log_ident != NULL ? log_ident : getprogname());
    vfprintf(stderr, format, ap);
    fputc('\n', stderr);
}

void syslog(int priority, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    vsyslog(priority, format, ap);
    va_end(ap);
}

/* search.h */

typedef struct tnode {
    const void *key; /* first: a found node is returned as a pointer to it */
    struct tnode *left, *right;
} tnode;

void *tsearch(const void *key, void **root, int (*compare)(const void *, const void *)) {
    if (root == NULL) {
        return NULL;
    }
    tnode **at = (tnode **)root;
    while (*at != NULL) {
        int c = compare(key, (*at)->key);
        if (c == 0) {
            return *at;
        }
        at = c < 0 ? &(*at)->left : &(*at)->right;
    }
    tnode *n = malloc(sizeof(*n));
    if (n == NULL) {
        return NULL;
    }
    n->key = key;
    n->left = n->right = NULL;
    *at = n;
    return n;
}

void *tfind(const void *key, void *const *root, int (*compare)(const void *, const void *)) {
    if (root == NULL) {
        return NULL;
    }
    tnode *n = *root;
    while (n != NULL) {
        int c = compare(key, n->key);
        if (c == 0) {
            return n;
        }
        n = c < 0 ? n->left : n->right;
    }
    return NULL;
}

/* Returns the parent of the deleted node (or the root itself, as glibc) */
void *tdelete(const void *key, void **root, int (*compare)(const void *, const void *)) {
    if (root == NULL || *root == NULL) {
        return NULL;
    }
    tnode **at = (tnode **)root;
    tnode *parent = *at;
    while (*at != NULL) {
        int c = compare(key, (*at)->key);
        if (c == 0) {
            break;
        }
        parent = *at;
        at = c < 0 ? &(*at)->left : &(*at)->right;
    }
    tnode *n = *at;
    if (n == NULL) {
        return NULL;
    }
    if (n->left == NULL) {
        *at = n->right;
    } else if (n->right == NULL) {
        *at = n->left;
    } else {
        tnode **succ = &n->right;
        while ((*succ)->left != NULL) {
            succ = &(*succ)->left;
        }
        tnode *s = *succ;
        *succ = s->right;
        s->left = n->left;
        s->right = n->right;
        *at = s;
    }
    free(n);
    return parent;
}

static void walk(const tnode *n, void (*action)(const void *, VISIT, int), int depth) {
    if (n->left == NULL && n->right == NULL) {
        action(n, leaf, depth);
        return;
    }
    action(n, preorder, depth);
    if (n->left != NULL) {
        walk(n->left, action, depth + 1);
    }
    action(n, postorder, depth);
    if (n->right != NULL) {
        walk(n->right, action, depth + 1);
    }
    action(n, endorder, depth);
}

void twalk(const void *root, void (*action)(const void *, VISIT, int)) {
    if (root != NULL && action != NULL) {
        walk(root, action, 0);
    }
}

void tdestroy(void *root, void (*free_node)(void *)) {
    tnode *n = root;
    if (n == NULL) {
        return;
    }
    tdestroy(n->left, free_node);
    tdestroy(n->right, free_node);
    free_node((void *)n->key);
    free(n);
}

static ENTRY *htab;
static size_t htab_size;

int hcreate(size_t size) {
    if (htab != NULL) {
        return 0;
    }
    htab_size = size < 8 ? 8 : size + size / 3;
    htab = calloc(htab_size, sizeof(ENTRY));
    return htab != NULL;
}

void hdestroy(void) {
    free(htab);
    htab = NULL;
    htab_size = 0;
}

ENTRY *hsearch(ENTRY item, ACTION action) {
    if (htab == NULL) {
        errno = ESRCH;
        return NULL;
    }
    size_t h = 5381;
    for (const char *p = item.key; *p != '\0'; p++) {
        h = h * 33 + (unsigned char)*p;
    }
    for (size_t i = 0; i < htab_size; i++) {
        ENTRY *e = &htab[(h + i) % htab_size];
        if (e->key == NULL) {
            if (action == FIND) {
                errno = ESRCH;
                return NULL;
            }
            *e = item;
            return e;
        }
        if (strcmp(e->key, item.key) == 0) {
            return e;
        }
    }
    errno = ENOMEM;
    return NULL;
}

void *lfind(const void *key, const void *base, size_t *count, size_t size, int (*compare)(const void *, const void *)) {
    const char *p = base;
    for (size_t i = 0; i < *count; i++, p += size) {
        if (compare(key, p) == 0) {
            return (void *)p;
        }
    }
    return NULL;
}

void *lsearch(const void *key, void *base, size_t *count, size_t size, int (*compare)(const void *, const void *)) {
    void *found = lfind(key, base, count, size, compare);
    if (found != NULL) {
        return found;
    }
    char *end = (char *)base + *count * size;
    memcpy(end, key, size);
    (*count)++;
    return end;
}

/* GETENTROPY, ARC4RANDOM: THE CPU'S GENERATOR, ELSE CLOCKS MIXED */

static uint64_t mix64(uint64_t x) { /* splitmix64's finalizer */
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ull;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}

static uint64_t cpu_counter(void) {
#if defined(__x86_64__) || defined(__i386__)
    uint32_t lo, hi;
    __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
#elif defined(__aarch64__)
    uint64_t v;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v));
    return v;
#else
    return 0;
#endif
}

/* -1: not known yet, 0: none, 1: RDRAND / RNDR */
static int hw_random = -1;

static bool hw_random_word(uint64_t *out) {
#if defined(__x86_64__) || defined(__i386__)
    if (hw_random < 0) {
        uint32_t a = 1, b, c, d;
        __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "=c"(c), "=d"(d));
        hw_random = (c >> 30) & 1;
    }
    for (int tries = 0; hw_random && tries < 10; tries++) {
        unsigned char ok;
#if defined(__x86_64__)
        uint64_t v;
        __asm__ volatile("rdrand %0; setc %1" : "=r"(v), "=qm"(ok));
#else
        uint32_t lo, hi;
        unsigned char ok2;
        __asm__ volatile("rdrand %0; setc %1" : "=r"(lo), "=qm"(ok));
        __asm__ volatile("rdrand %0; setc %1" : "=r"(hi), "=qm"(ok2));
        ok &= ok2;
        uint64_t v = ((uint64_t)hi << 32) | lo;
#endif
        if (ok) {
            *out = v;
            return true;
        }
    }
#elif defined(__aarch64__)
    if (hw_random < 0) { /* ID_AA64ISAR0_EL1.RNDR (programs run at EL1) */
        uint64_t isar0;
        __asm__ volatile("mrs %0, s3_0_c0_c6_0" : "=r"(isar0));
        hw_random = ((isar0 >> 60) & 0xF) != 0;
    }
    for (int tries = 0; hw_random && tries < 10; tries++) {
        uint64_t v, fail;
        __asm__ volatile("mrs %0, s3_3_c2_c4_0; cset %1, eq" : "=r"(v), "=r"(fail) : : "cc");
        if (!fail) {
            *out = v;
            return true;
        }
    }
#endif
    (void)out;
    return false;
}

static uint64_t random_word(void) {
    static uint64_t state;
    uint64_t v;
    if (hw_random_word(&v)) return v;
    uint64_t ms = zdos != NULL ? zdos->time->millis() : 0;
    state += 0x9e3779b97f4a7c15ull ^ cpu_counter() ^ (ms << 32) ^ (uint64_t)(uintptr_t)&v;
    return mix64(state);
}

int getentropy(void *buf, size_t len) {
    if (len > 256) {
        errno = EIO;
        return -1;
    }
    unsigned char *p = buf;
    while (len > 0) {
        uint64_t v = random_word();
        size_t n = len < sizeof(v) ? len : sizeof(v);
        memcpy(p, &v, n);
        p += n;
        len -= n;
    }
    return 0;
}

ssize_t getrandom(void *buf, size_t len, unsigned flags) {
    (void)flags;
    unsigned char *p = buf;
    for (size_t done = 0; done < len; done += 256) {
        getentropy(p + done, len - done < 256 ? len - done : 256);
    }
    return (ssize_t)len;
}

uint32_t arc4random(void) {
    return (uint32_t)random_word();
}

void arc4random_buf(void *buf, size_t n) {
    getrandom(buf, n, 0);
}

uint32_t arc4random_uniform(uint32_t bound) {
    if (bound < 2) return 0;
    uint32_t min = -bound % bound; /* 2^32 mod bound: below it would be biased */
    for (;;) {
        uint32_t r = arc4random();
        if (r >= min) return r % bound;
    }
}

/* TTYNAME */
/* The console is the only terminal (/dev/tty, sdk/README.md's POSIX paths) */

int ttyname_r(int fd, char *buf, size_t len) {
    static const char tty[] = "/dev/tty";
    if (!isatty(fd)) {
        return errno == EBADF ? EBADF : ENOTTY;
    }
    if (len < sizeof(tty)) {
        return ERANGE;
    }
    memcpy(buf, tty, sizeof(tty));
    return 0;
}

char *ttyname(int fd) {
    static char name[16];
    int e = ttyname_r(fd, name, sizeof(name));
    if (e != 0) {
        errno = e;
        return NULL;
    }
    return name;
}
