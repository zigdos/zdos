/* Small freestanding C compatibility layer. This is not a full libc. */
#include <stdbool.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#include "assert.h"
#include "ctype.h"
#include "errno.h"
#include "inttypes.h"
#include "limits.h"
#include "locale.h"
#include "math.h"
#include "signal.h"
#include "stdio.h"
#include "stdlib.h"
#include "string.h"
#include "strings.h"
#include "sys/time.h"
#include "time.h"
#include "unistd.h"
#include "wchar.h"
#include "getopt.h"
#include "fnmatch.h"
#include "pwd.h"
#include "sys/utsname.h"
#include "zdos.h"
#include "zdos_errno.h"
#include "zdos_internal.h"

static int zdos_errno;
bool zdos_threads_started;
const zdos_runtime *zdos_runtime_host;
bool zdos_library_one_copy;
void (*zdos_vfork_exit_hook)(int status);

/* FUTEXES AND LOCK WORDS (pthreads, streams, guards) */

static int futex_state; /* 1: ZDOS has futexes, -1: it hasn't, 0: not asked yet */

bool zdos_futex_ok(void) {
    int st = __atomic_load_n(&futex_state, __ATOMIC_RELAXED);
    if (st == 0) {
        // No bits: INVALID_ARGUMENT (-1) from a futex, 0 from a reserved slot
        static uint32_t probe;
        st = zdos != NULL && zdos->threads->futex_wake(&probe, 1, 0) < 0 ? 1 : -1;
        __atomic_store_n(&futex_state, st, __ATOMIC_RELAXED);
    }
    return st > 0;
}

uint32_t zdos_futex_wait(const uint32_t *word, uint32_t expected, int32_t timeout_ms) {
    if (zdos_futex_ok()) {
        return zdos->threads->futex_wait(word, expected, timeout_ms, 0xffffffffu);
    }
    if (__atomic_load_n(word, __ATOMIC_ACQUIRE) != expected) {
        return ZDOS_ERROR_WOULD_BLOCK;
    }
    if (timeout_ms == 0 || zdos == NULL) {
        return ZDOS_ERROR_TIMED_OUT;
    }
    zdos->tasks->yield();
    if (__atomic_load_n(word, __ATOMIC_ACQUIRE) == expected) {
        zdos->time->nap(1);
    }
    return ZDOS_ERROR_NONE;
}

void zdos_futex_wake(const uint32_t *word, uint32_t count) {
    if (zdos_futex_ok()) {
        zdos->threads->futex_wake(word, count, 0xffffffffu);
    }
}

int32_t zdos_ms_until(int clock, const struct timespec *at) {
    struct timespec now;
    clock_gettime(clock, &now);
    int64_t s = (int64_t)at->tv_sec - (int64_t)now.tv_sec;
    if (s > 2000000) {
        return INT32_MAX;
    }
    int64_t ns = s * 1000000000 + (at->tv_nsec - now.tv_nsec);
    return ns <= 0 ? 0 : (int32_t)((ns + 999999) / 1000000);
}

static inline void cpu_relax(void) {
#if defined(__x86_64__) || defined(__i386__)
    __asm__ volatile("pause");
#elif defined(__aarch64__)
    __asm__ volatile("yield");
#endif
}

bool zdos_word_trylock(uint32_t *word) {
    uint32_t c = 0;
    return __atomic_compare_exchange_n(word, &c, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
}

bool zdos_word_lock_until(uint32_t *word, const struct timespec *at, int clock) {
    uint32_t c = 0;
    if (__atomic_compare_exchange_n(word, &c, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        return true;
    }
    // A short spin first: the holder may be about to let go on another core
    for (int i = 0; i < 100 && c != 0; i++) {
        cpu_relax();
        c = __atomic_load_n(word, __ATOMIC_RELAXED);
        if (c == 0 && __atomic_compare_exchange_n(word, &c, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
            return true;
        }
    }
    if (c != 2) {
        c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    }
    while (c != 0) {
        int32_t ms = -1;
        if (at != NULL && (ms = zdos_ms_until(clock, at)) == 0) {
            return false;
        }
        zdos_futex_wait(word, 2, ms); /* woken, timed out, a signal: look again */
        c = __atomic_exchange_n(word, 2, __ATOMIC_ACQUIRE);
    }
    return true;
}

void zdos_word_lock(uint32_t *word) {
    zdos_word_lock_until(word, NULL, 0);
}

void zdos_word_unlock(uint32_t *word) {
    if (__atomic_exchange_n(word, 0, __ATOMIC_RELEASE) == 2) {
        zdos_futex_wake(word, 1);
    }
}

uint32_t zdos_self_id(void) {
    static uint32_t main_id = UINT32_MAX;
    if (zdos_threads_started) {
        return zdos->tasks->id();
    }
    if (main_id == UINT32_MAX) { /* one thread yet: it is this one */
        main_id = zdos != NULL ? zdos->tasks->id() : 0;
    }
    return main_id;
}

static uint32_t init_lock;

void zdos_init_lock_take(void) {
    zdos_word_lock(&init_lock);
}

void zdos_init_lock_give(void) {
    zdos_word_unlock(&init_lock);
}

bool zdos_rlock_take(zdos_rlock *l, bool try_only) {
    uint32_t me = zdos_self_id();
    if (__atomic_load_n(&l->owner, __ATOMIC_RELAXED) == me && l->count > 0) {
        l->count++;
        return true;
    }
    if (try_only) {
        if (!zdos_word_trylock(&l->word)) {
            return false;
        }
    } else {
        zdos_word_lock(&l->word);
    }
    __atomic_store_n(&l->owner, me, __ATOMIC_RELAXED);
    l->count = 1;
    return true;
}

void zdos_rlock_give(zdos_rlock *l) {
    if (l->count == 0 || --l->count > 0) {
        return;
    }
    __atomic_store_n(&l->owner, UINT32_MAX, __ATOMIC_RELAXED);
    zdos_word_unlock(&l->word);
}

// Each thread's own once threads exist (zdos_posix.c: the first int of
// its threads->local() record); the program's own thread has the global one
int *__errno_location(void) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->errno_location();
    }
    if (zdos_threads_started) {
        int *own = (int *)zdos->threads->local();
        if (own != NULL) {
            return own;
        }
    }
    return &zdos_errno;
}

/* MEMORY */

/* Before each block: its size, and how far after the start of what ZDOS
   gave the block is (0, more for aligned_alloc and posix_memalign) */
typedef union {
    struct {
        size_t size;
        size_t offset;
    } value;
    uint64_t alignment[2];
} zdos_alloc_header_t;

void *malloc(size_t size) {
    if (zdos == NULL || zdos->memory->alloc == NULL || size > SIZE_MAX - sizeof(zdos_alloc_header_t)) {
        return NULL;
    }
    if (size == 0) {
        size = 1;
    }
    zdos_alloc_header_t *header = zdos->memory->alloc(sizeof(*header) + size);
    if (header == NULL) {
        zdos_errno = ENOMEM;
        return NULL;
    }
    header->value.size = size;
    header->value.offset = 0;
    return header + 1;
}

void free(void *ptr) {
    if (ptr != NULL && zdos != NULL && zdos->memory->free != NULL) {
        zdos_alloc_header_t *header = (zdos_alloc_header_t *)ptr - 1;
        zdos->memory->free((char *)header - header->value.offset);
    }
}

/* size bytes at a multiple of alignment (a power of two): more is taken,
   and the header put right before the aligned block */
void *aligned_alloc(size_t alignment, size_t size) {
    if (alignment <= sizeof(zdos_alloc_header_t)) {
        return malloc(size);
    }
    if ((alignment & (alignment - 1)) != 0 || size > SIZE_MAX - alignment - sizeof(zdos_alloc_header_t) ||
        zdos == NULL || zdos->memory->alloc == NULL) {
        zdos_errno = EINVAL;
        return NULL;
    }
    char *raw = zdos->memory->alloc(sizeof(zdos_alloc_header_t) + alignment + size);
    if (raw == NULL) {
        zdos_errno = ENOMEM;
        return NULL;
    }
    uintptr_t first = (uintptr_t)raw + sizeof(zdos_alloc_header_t);
    char *block = (char *)((first + alignment - 1) & ~(uintptr_t)(alignment - 1));
    zdos_alloc_header_t *header = (zdos_alloc_header_t *)block - 1;
    header->value.size = size;
    header->value.offset = (size_t)((char *)header - raw);
    return block;
}

int posix_memalign(void **out, size_t alignment, size_t size) {
    if (alignment < sizeof(void *) || (alignment & (alignment - 1)) != 0) {
        return EINVAL;
    }
    void *p = aligned_alloc(alignment, size == 0 ? 1 : size);
    if (p == NULL) {
        return ENOMEM;
    }
    *out = p;
    return 0;
}

void *memalign(size_t alignment, size_t size) {
    return aligned_alloc(alignment, size);
}

void *valloc(size_t size) {
    return aligned_alloc(4096, size);
}

size_t malloc_usable_size(void *ptr) {
    return ptr != NULL ? ((zdos_alloc_header_t *)ptr - 1)->value.size : 0;
}

void *realloc(void *ptr, size_t size) {
    if (ptr == NULL) {
        return malloc(size);
    }
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    zdos_alloc_header_t *old_header = (zdos_alloc_header_t *)ptr - 1;
    void *new_ptr = malloc(size);
    if (new_ptr != NULL) {
        size_t copy_size = old_header->value.size < size ? old_header->value.size : size;
        memcpy(new_ptr, ptr, copy_size);
        free(ptr);
    }
    return new_ptr;
}

void *calloc(size_t count, size_t size) {
    if (size != 0 && count > SIZE_MAX / size) {
        zdos_errno = ENOMEM;
        return NULL;
    }
    size_t bytes = count * size;
    void *ptr = malloc(bytes);
    if (ptr != NULL) {
        memset(ptr, 0, bytes);
    }
    return ptr;
}

/* MEMORY AND STRINGS */

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    for (size_t i = 0; i < n; ++i) {
        d[i] = s[i];
    }
    return dest;
}

void *memset(void *dest, int value, size_t n) {
    unsigned char *d = dest;
    for (size_t i = 0; i < n; ++i) {
        d[i] = (unsigned char)value;
    }
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    uintptr_t du = (uintptr_t)d;
    uintptr_t su = (uintptr_t)s;
    if (du <= su || du - su >= n) {
        for (size_t i = 0; i < n; ++i) {
            d[i] = s[i];
        }
    } else {
        for (size_t i = n; i > 0; --i) {
            d[i - 1] = s[i - 1];
        }
    }
    return dest;
}

int memcmp(const void *lhs, const void *rhs, size_t n) {
    const unsigned char *a = lhs;
    const unsigned char *b = rhs;
    for (size_t i = 0; i < n; ++i) {
        if (a[i] != b[i]) {
            return (int)a[i] - (int)b[i];
        }
    }
    return 0;
}

void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    for (size_t i = 0; i < n; ++i) {
        if (p[i] == (unsigned char)c) {
            return (void *)(p + i);
        }
    }
    return NULL;
}

void bzero(void *s, size_t n) {
    memset(s, 0, n);
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p != '\0') {
        ++p;
    }
    return (size_t)(p - s);
}

size_t strnlen(const char *s, size_t maxlen) {
    size_t n = 0;
    while (n < maxlen && s[n] != '\0') {
        ++n;
    }
    return n;
}

int strcmp(const char *lhs, const char *rhs) {
    while (*lhs != '\0' && (unsigned char)*lhs == (unsigned char)*rhs) {
        ++lhs;
        ++rhs;
    }
    return (int)(unsigned char)*lhs - (int)(unsigned char)*rhs;
}

int strncmp(const char *lhs, const char *rhs, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        unsigned char a = (unsigned char)lhs[i];
        unsigned char b = (unsigned char)rhs[i];
        if (a != b || a == '\0') {
            return (int)a - (int)b;
        }
    }
    return 0;
}

int strcoll(const char *lhs, const char *rhs) {
    return strcmp(lhs, rhs);
}

size_t strxfrm(char *dest, const char *src, size_t n) {
    size_t len = strlen(src);
    if (len < n) {
        memcpy(dest, src, len + 1);
    }
    return len;
}

int strcasecmp(const char *lhs, const char *rhs) {
    for (;; ++lhs, ++rhs) {
        int a = tolower((unsigned char)*lhs);
        int b = tolower((unsigned char)*rhs);
        if (a != b || a == '\0') {
            return a - b;
        }
    }
}

int strncasecmp(const char *lhs, const char *rhs, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        int a = tolower((unsigned char)lhs[i]);
        int b = tolower((unsigned char)rhs[i]);
        if (a != b || a == '\0') {
            return a - b;
        }
    }
    return 0;
}

char *strchr(const char *s, int c) {
    unsigned char target = (unsigned char)c;
    do {
        if ((unsigned char)*s == target) {
            return (char *)s;
        }
    } while (*s++ != '\0');
    return NULL;
}

char *strrchr(const char *s, int c) {
    const char *found = NULL;
    unsigned char target = (unsigned char)c;
    do {
        if ((unsigned char)*s == target) {
            found = s;
        }
    } while (*s++ != '\0');
    return (char *)found;
}

char *strstr(const char *haystack, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0) {
        return (char *)haystack;
    }
    for (; *haystack != '\0'; ++haystack) {
        if (*haystack == *needle && strncmp(haystack, needle, n) == 0) {
            return (char *)haystack;
        }
    }
    return NULL;
}

size_t strspn(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n] != '\0' && strchr(accept, s[n]) != NULL) {
        ++n;
    }
    return n;
}

size_t strcspn(const char *s, const char *reject) {
    size_t n = 0;
    while (s[n] != '\0' && strchr(reject, s[n]) == NULL) {
        ++n;
    }
    return n;
}

char *strpbrk(const char *s, const char *accept) {
    s += strcspn(s, accept);
    return *s != '\0' ? (char *)s : NULL;
}

char *strcpy(char *dest, const char *src) {
    char *result = dest;
    while ((*dest++ = *src++) != '\0') {
    }
    return result;
}

char *strncpy(char *dest, const char *src, size_t n) {
    size_t i = 0;
    while (i < n && src[i] != '\0') {
        dest[i] = src[i];
        ++i;
    }
    while (i < n) {
        dest[i++] = '\0';
    }
    return dest;
}

char *strcat(char *dest, const char *src) {
    strcpy(dest + strlen(dest), src);
    return dest;
}

char *strncat(char *dest, const char *src, size_t n) {
    char *d = dest + strlen(dest);
    size_t i = 0;
    while (i < n && src[i] != '\0') {
        d[i] = src[i];
        ++i;
    }
    d[i] = '\0';
    return dest;
}

char *strndup(const char *s, size_t n) {
    size_t len = strnlen(s, n);
    char *copy = malloc(len + 1);
    if (copy != NULL) {
        memcpy(copy, s, len);
        copy[len] = '\0';
    }
    return copy;
}

char *strdup(const char *s) {
    return strndup(s, SIZE_MAX);
}

char *strtok_r(char *s, const char *delim, char **save) {
    if (s == NULL) {
        s = *save;
    }
    if (s == NULL) {
        return NULL;
    }
    s += strspn(s, delim);
    if (*s == '\0') {
        *save = NULL;
        return NULL;
    }
    char *end = s + strcspn(s, delim);
    if (*end != '\0') {
        *end++ = '\0';
        *save = end;
    } else {
        *save = NULL;
    }
    return s;
}

char *strtok(char *s, const char *delim) {
    static char *save;
    return strtok_r(s, delim, &save);
}

char *strerror(int errnum) {
    switch (errnum) {
        case 0: return "No error";
        case EPERM: return "Operation not permitted";
        case ENOENT: return "No such file or directory";
        case EINTR: return "Interrupted";
        case EIO: return "Disk error";
        case EBADF: return "Bad file descriptor";
        case EAGAIN: return "Try again";
        case ENOMEM: return "Not enough memory";
        case EACCES: return "Access denied";
        case EEXIST: return "File exists";
        case ENODEV: return "No such device";
        case ENOTDIR: return "Not a directory";
        case EISDIR: return "Is a directory";
        case EINVAL: return "Invalid argument";
        case EMFILE: return "Too many open files";
        case EFBIG: return "File too large";
        case ENOSPC: return "Disk full";
        case ESPIPE: return "Illegal seek";
        case EROFS: return "Disk is write-protected";
        case EDOM: return "Argument out of domain";
        case ERANGE: return "Result out of range";
        case ENAMETOOLONG: return "File name too long";
        case ENOSYS: return "Function not implemented";
        case ENOTEMPTY: return "Directory not empty";
        case EOPNOTSUPP: return "Not supported";
        case ENOTSOCK: return "Not a socket";
        case EMSGSIZE: return "Message too long";
        case EAFNOSUPPORT: return "Address family not supported";
        case EADDRINUSE: return "Address in use";
        case EADDRNOTAVAIL: return "Address not available";
        case ENETDOWN: return "No network";
        case ENETUNREACH: return "Network unreachable";
        case ECONNABORTED: return "Connection aborted";
        case ECONNRESET: return "Connection reset";
        case EISCONN: return "Already connected";
        case ENOTCONN: return "Not connected";
        case ETIMEDOUT: return "Timed out";
        case ECONNREFUSED: return "Connection refused";
        case EHOSTUNREACH: return "Host unreachable";
        case EALREADY: return "Already connecting";
        case EINPROGRESS: return "Connecting";
        case EPIPE: return "Broken pipe";
        default: return "Unknown error";
    }
}

/* POSIX (XSI) form: the text into buf; 0, or ERANGE if it doesn't fit */
int strerror_r(int errnum, char *buf, size_t size) {
    const char *text = strerror(errnum);
    size_t n = strlen(text);
    if (size == 0) {
        return ERANGE;
    }
    if (n >= size) {
        memcpy(buf, text, size - 1);
        buf[size - 1] = '\0';
        return ERANGE;
    }
    memcpy(buf, text, n + 1);
    return 0;
}

char *strsignal(int sig) {
    switch (sig) {
        case SIGINT: return "Interrupt";
        case SIGILL: return "Illegal instruction";
        case SIGABRT: return "Aborted";
        case SIGFPE: return "Floating point exception";
        case SIGSEGV: return "Segmentation fault";
        case SIGTERM: return "Terminated";
        default: return "Unknown signal";
    }
}

/* The first place needle (needle_len bytes) is in haystack, or NULL */
void *memmem(const void *haystack, size_t haystack_len, const void *needle, size_t needle_len) {
    const unsigned char *h = haystack;
    if (needle_len == 0) {
        return (void *)h;
    }
    if (haystack_len < needle_len) {
        return NULL;
    }
    const unsigned char first = *(const unsigned char *)needle;
    for (size_t i = 0; i <= haystack_len - needle_len; i++) {
        if (h[i] == first && memcmp(h + i, needle, needle_len) == 0) {
            return (void *)(h + i);
        }
    }
    return NULL;
}

/* strstr without regard to case (ASCII letters) */
char *strcasestr(const char *haystack, const char *needle) {
    size_t n = strlen(needle);
    for (; *haystack != '\0'; ++haystack) {
        if (strncasecmp(haystack, needle, n) == 0) {
            return (char *)haystack;
        }
    }
    return n == 0 ? (char *)haystack : NULL;
}

/* CHARACTER CLASSES ("C" LOCALE, ASCII) */

int isdigit(int c) { return c >= '0' && c <= '9'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int isalpha(int c) { return islower(c) || isupper(c); }
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isxdigit(int c) { return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
int isblank(int c) { return c == ' ' || c == '\t'; }
int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
int iscntrl(int c) { return (c >= 0 && c < 0x20) || c == 0x7f; }
int isprint(int c) { return c >= 0x20 && c < 0x7f; }
int isgraph(int c) { return c > 0x20 && c < 0x7f; }
int ispunct(int c) { return isgraph(c) && !isalnum(c); }
int tolower(int c) { return isupper(c) ? c - 'A' + 'a' : c; }
int toupper(int c) { return islower(c) ? c - 'a' + 'A' : c; }
int isascii(int c) { return c >= 0 && c < 0x80; }
int toascii(int c) { return c & 0x7f; }

/* NUMBERS FROM TEXT */

static int digit_value(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 10;
    }
    return -1;
}

/* The common part of the strto* functions: the magnitude, at most limit_pos
   (or limit_neg after a '-'); ERANGE and the limit when it is larger */
static unsigned long long parse_integer(const char *str, char **endptr, int base,
    unsigned long long limit_pos, unsigned long long limit_neg, bool *negative) {
    const char *start = str;
    while (isspace((unsigned char)*str)) {
        ++str;
    }
    *negative = false;
    if (*str == '+' || *str == '-') {
        *negative = *str == '-';
        ++str;
    }
    if (base != 0 && (base < 2 || base > 36)) {
        if (endptr != NULL) {
            *endptr = (char *)start;
        }
        zdos_errno = EINVAL;
        return 0;
    }
    if ((base == 0 || base == 16) && str[0] == '0' && (str[1] == 'x' || str[1] == 'X') && digit_value(str[2]) >= 0 &&
        digit_value(str[2]) < 16) {
        base = 16;
        str += 2;
    } else if (base == 0) {
        base = str[0] == '0' ? 8 : 10;
    }

    unsigned long long limit = *negative ? limit_neg : limit_pos;
    unsigned long long value = 0;
    bool any = false;
    bool overflow = false;
    for (;;) {
        int digit = digit_value(*str);
        if (digit < 0 || digit >= base) {
            break;
        }
        any = true;
        if (value > (limit - (unsigned long long)digit) / (unsigned long long)base) {
            overflow = true;
        } else if (!overflow) {
            value = value * (unsigned long long)base + (unsigned long long)digit;
        }
        ++str;
    }
    if (endptr != NULL) {
        *endptr = (char *)(any ? str : start);
    }
    if (!any) {
        return 0;
    }
    if (overflow) {
        zdos_errno = ERANGE;
        return limit;
    }
    return value;
}

long strtol(const char *str, char **endptr, int base) {
    bool negative;
    unsigned long long v = parse_integer(str, endptr, base, LONG_MAX, (unsigned long long)LONG_MAX + 1, &negative);
    return negative ? (long)(0 - v) : (long)v;
}

long long strtoll(const char *str, char **endptr, int base) {
    bool negative;
    unsigned long long v = parse_integer(str, endptr, base, LLONG_MAX, (unsigned long long)LLONG_MAX + 1, &negative);
    return negative ? (long long)(0 - v) : (long long)v;
}

unsigned long strtoul(const char *str, char **endptr, int base) {
    bool negative;
    unsigned long long v = parse_integer(str, endptr, base, ULONG_MAX, ULONG_MAX, &negative);
    if (negative && v != ULONG_MAX) {
        v = (unsigned long)(0 - v);
    }
    return (unsigned long)v;
}

unsigned long long strtoull(const char *str, char **endptr, int base) {
    bool negative;
    unsigned long long v = parse_integer(str, endptr, base, ULLONG_MAX, ULLONG_MAX, &negative);
    if (negative && v != ULLONG_MAX) {
        v = 0 - v;
    }
    return v;
}

intmax_t strtoimax(const char *str, char **endptr, int base) {
    return strtoll(str, endptr, base);
}

uintmax_t strtoumax(const char *str, char **endptr, int base) {
    return strtoull(str, endptr, base);
}

int atoi(const char *str) {
    return (int)strtol(str, NULL, 10);
}

long atol(const char *str) {
    return strtol(str, NULL, 10);
}

long long atoll(const char *str) {
    return strtoll(str, NULL, 10);
}

/* FLOATING POINT NUMBERS FROM TEXT
   strtod rounds correctly: an estimate from 19 digits is corrected by
   comparing the text with the halfway point, both as big integers. 769
   significant digits decide; later ones only count as "nonzero follows". */

#define RD_LIMBS 320   /* 32-bit limbs: 10240 bits, more than the largest product */
#define RD_DIGITS 769

typedef struct {
    uint32_t limb[RD_LIMBS]; /* least significant first */
    int count;
} rd_big;

static double rd_from_bits(uint64_t bits) {
    union { uint64_t u; double f; } v = { .u = bits };
    return v.f;
}

static uint64_t rd_bits(double f) {
    union { double f; uint64_t u; } v = { .f = f };
    return v.u;
}

static double rd_pow2(int e) { /* e in -1022 .. 1023 */
    return rd_from_bits((uint64_t)(e + 1023) << 52);
}

// x * 2^e for x in [1, 2^64), with a single rounding
static double rd_ldexp(double x, int e) {
    if (e > 1023) {
        x *= rd_pow2(1023);
        e -= 1023;
        if (e > 1023) {
            return x * rd_pow2(1023); /* inf */
        }
    } else if (e < -1022) {
        x *= rd_pow2(-1022); /* still normal: exact */
        e += 1022;
        if (e < -1022) {
            return 0; /* far below the smallest double */
        }
    }
    return x * rd_pow2(e);
}

static void rd_mul_small(rd_big *b, uint32_t factor, uint32_t add) {
    uint64_t carry = add;
    for (int i = 0; i < b->count; ++i) {
        uint64_t x = (uint64_t)b->limb[i] * factor + carry;
        b->limb[i] = (uint32_t)x;
        carry = x >> 32;
    }
    if (carry != 0 && b->count < RD_LIMBS) {
        b->limb[b->count++] = (uint32_t)carry;
    }
}

static void rd_mul_pow5(rd_big *b, int n) {
    while (n >= 13) {
        rd_mul_small(b, 1220703125u, 0); /* 5^13 */
        n -= 13;
    }
    static const uint32_t pow5[13] = { 1, 5, 25, 125, 625, 3125, 15625, 78125, 390625, 1953125, 9765625,
        48828125, 244140625 };
    if (n > 0) {
        rd_mul_small(b, pow5[n], 0);
    }
}

static void rd_shift_left(rd_big *b, int n) {
    if (b->count == 0) {
        return;
    }
    int words = n / 32;
    int bits = n % 32;
    if (b->count + words + 1 > RD_LIMBS) {
        words = RD_LIMBS - b->count - 1; /* can't happen for the sizes strtod makes */
    }
    if (bits != 0) {
        uint32_t top = b->limb[b->count - 1] >> (32 - bits);
        for (int i = b->count - 1; i > 0; --i) {
            b->limb[i] = (b->limb[i] << bits) | (b->limb[i - 1] >> (32 - bits));
        }
        b->limb[0] <<= bits;
        if (top != 0) {
            b->limb[b->count++] = top;
        }
    }
    if (words > 0) {
        memmove(b->limb + words, b->limb, (size_t)b->count * sizeof(uint32_t));
        memset(b->limb, 0, (size_t)words * sizeof(uint32_t));
        b->count += words;
    }
}

static int rd_compare_big(const rd_big *a, const rd_big *b) {
    if (a->count != b->count) {
        return a->count < b->count ? -1 : 1;
    }
    for (int i = a->count - 1; i >= 0; --i) {
        if (a->limb[i] != b->limb[i]) {
            return a->limb[i] < b->limb[i] ? -1 : 1;
        }
    }
    return 0;
}

// Compares digits * 10^dexp with h * 2^j
static int rd_compare(const char *digits, int nd, int dexp, uint64_t h, int j) {
    rd_big a, b;
    a.count = 0;
    int i = 0;
    while (i < nd) { /* nine digits at a time */
        uint32_t chunk = 0;
        uint32_t scale = 1;
        for (int k = 0; k < 9 && i < nd; ++k, ++i) {
            chunk = chunk * 10 + (uint32_t)(digits[i] - '0');
            scale *= 10;
        }
        if (a.count == 0) {
            if (chunk != 0) {
                a.limb[0] = chunk;
                a.count = 1;
            }
        } else {
            rd_mul_small(&a, scale, chunk);
        }
    }
    b.count = 0;
    if (h != 0) {
        b.limb[b.count++] = (uint32_t)h;
        if ((h >> 32) != 0) {
            b.limb[b.count++] = (uint32_t)(h >> 32);
        }
    }
    int p5a = dexp > 0 ? dexp : 0;
    int p5b = dexp < 0 ? -dexp : 0;
    int p2a = p5a + (j < 0 ? -j : 0);
    int p2b = p5b + (j > 0 ? j : 0);
    int common = p2a < p2b ? p2a : p2b;
    rd_mul_pow5(&a, p5a);
    rd_shift_left(&a, p2a - common);
    rd_mul_pow5(&b, p5b);
    rd_shift_left(&b, p2b - common);
    return rd_compare_big(&a, &b);
}

static const double rd_pow10[23] = { 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
    1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

// Splits off the binary exponent: x = x' * 2^e with x' in [1, 2) (x normal)
static double rd_normalize(double x, int *e) {
    uint64_t bits = rd_bits(x);
    *e += (int)((bits >> 52) & 0x7FF) - 1023;
    return rd_from_bits((bits & ~(UINT64_C(0x7FF) << 52)) | (UINT64_C(1023) << 52));
}

// digits (no leading or trailing zeros, nd > 0) * 10^dexp, correctly rounded
static double rd_decimal(const char *digits, int nd, int dexp) {
    uint64_t m = 0;
    int i = 0;
    for (; i < nd && i < 19; ++i) {
        m = m * 10 + (uint64_t)(digits[i] - '0');
    }
    int e10 = dexp + (nd - i);
    int e2 = 0;
    double z = rd_normalize((double)m, &e2);
    while (e10 > 0) {
        int k = e10 > 22 ? 22 : e10;
        z = rd_normalize(z * rd_pow10[k], &e2);
        e10 -= k;
    }
    while (e10 < 0) {
        int k = -e10 > 22 ? 22 : -e10;
        z = rd_normalize(z / rd_pow10[k], &e2);
        e10 += k;
    }
    z = rd_ldexp(z, e2);

    uint64_t bits = rd_bits(z);
    const uint64_t inf_bits = UINT64_C(0x7FF) << 52;
    if (bits >= inf_bits) {
        bits = inf_bits - 1; /* the largest double; checked against inf below */
    } else if (bits == 0) {
        bits = 1; /* the smallest one; checked against 0 below */
    }
    for (;;) {
        uint64_t frac = bits & ((UINT64_C(1) << 52) - 1);
        int exp_field = (int)(bits >> 52);
        uint64_t mant = exp_field == 0 ? frac : frac | (UINT64_C(1) << 52);
        int k = exp_field == 0 ? -1074 : exp_field - 1075;

        int up = rd_compare(digits, nd, dexp, 2 * mant + 1, k - 1);
        if (up > 0 || (up == 0 && (mant & 1))) {
            ++bits; /* above the halfway point, or on it with an odd mant: the next one */
            if (bits >= inf_bits) {
                return rd_from_bits(inf_bits);
            }
            if (up == 0) {
                return rd_from_bits(bits);
            }
            continue;
        }
        if (up == 0) {
            return rd_from_bits(bits);
        }
        int down = mant == (UINT64_C(1) << 52) && exp_field > 1
            ? rd_compare(digits, nd, dexp, 4 * mant - 1, k - 2)
            : rd_compare(digits, nd, dexp, 2 * mant - 1, k - 1);
        if (down < 0 || (down == 0 && (mant & 1))) {
            --bits; /* below the lower halfway point, or on it with an odd mant */
            if (bits == 0 || down == 0) {
                return rd_from_bits(bits);
            }
            continue;
        }
        return rd_from_bits(bits);
    }
}

static int rd_hex_digit(int c) {
    int d = digit_value((char)c);
    return d >= 0 && d < 16 ? d : -1;
}

// "0x1.8p3": the part after "0x"; exact up to 16 significant hex digits,
// the rest only counts as nonzero or not
static double rd_hex(const char *s, const char **end) {
    uint64_t m = 0;
    int bexp = 0;
    bool sticky = false;
    bool any = false;
    for (; rd_hex_digit(*s) >= 0; ++s) {
        any = true;
        if ((m >> 60) == 0) {
            m = m * 16 + (uint64_t)rd_hex_digit(*s);
        } else {
            bexp += 4;
            sticky |= *s != '0';
        }
    }
    if (*s == '.') {
        for (++s; rd_hex_digit(*s) >= 0; ++s) {
            any = true;
            if ((m >> 60) == 0) {
                m = m * 16 + (uint64_t)rd_hex_digit(*s);
                bexp -= 4;
            } else {
                sticky |= *s != '0';
            }
        }
    }
    if (!any) {
        *end = NULL;
        return 0;
    }
    if ((*s == 'p' || *s == 'P') && (isdigit((unsigned char)s[1]) ||
        ((s[1] == '+' || s[1] == '-') && isdigit((unsigned char)s[2])))) {
        bool negative = s[1] == '-';
        s += s[1] == '+' || s[1] == '-' ? 2 : 1;
        int e = 0;
        for (; isdigit((unsigned char)*s); ++s) {
            if (e < 100000) {
                e = e * 10 + (*s - '0');
            }
        }
        bexp += negative ? -e : e;
    }
    *end = s;
    if (m == 0) {
        return 0;
    }
    while ((m >> 63) == 0) {
        m <<= 1;
        --bexp;
    }
    int top = bexp + 63; /* the value is in [2^top, 2^(top+1)) */
    if (top > 1023) {
        zdos_errno = ERANGE;
        return HUGE_VAL;
    }
    int shift = top >= -1022 ? 11 : 11 + (-1022 - top);
    if (shift > 64) {
        zdos_errno = ERANGE;
        return 0;
    }
    uint64_t kept = shift == 64 ? 0 : m >> shift;
    uint64_t rest = shift == 64 ? m : m & ((UINT64_C(1) << shift) - 1);
    uint64_t half = UINT64_C(1) << (shift - 1);
    if (rest > half || (rest == half && (sticky || (kept & 1)))) {
        ++kept;
    }
    double v = rd_ldexp((double)kept, bexp + shift);
    if (v == 0 || v == HUGE_VAL) {
        zdos_errno = ERANGE;
    }
    return v;
}

double strtod(const char *str, char **endptr) {
    const char *s = str;
    while (isspace((unsigned char)*s)) {
        ++s;
    }
    bool negative = false;
    if (*s == '+' || *s == '-') {
        negative = *s == '-';
        ++s;
    }
    double v;
    if (strncasecmp(s, "inf", 3) == 0) {
        s += strncasecmp(s, "infinity", 8) == 0 ? 8 : 3;
        v = HUGE_VAL;
    } else if (strncasecmp(s, "nan", 3) == 0) {
        s += 3;
        if (*s == '(') {
            const char *p = s + 1;
            while (isalnum((unsigned char)*p) || *p == '_') {
                ++p;
            }
            if (*p == ')') {
                s = p + 1;
            }
        }
        v = NAN;
    } else if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X') &&
        (rd_hex_digit(s[2]) >= 0 || (s[2] == '.' && rd_hex_digit(s[3]) >= 0))) {
        v = rd_hex(s + 2, &s);
    } else {
        char digits[RD_DIGITS + 1];
        int nd = 0;
        int dexp = 0;
        bool any = false;
        bool sticky = false;
        for (; isdigit((unsigned char)*s); ++s) {
            any = true;
            if (nd == 0 && *s == '0') {
                continue;
            }
            if (nd < RD_DIGITS) {
                digits[nd++] = *s;
            } else {
                ++dexp;
                sticky |= *s != '0';
            }
        }
        if (*s == '.' && (any || isdigit((unsigned char)s[1]))) {
            for (++s; isdigit((unsigned char)*s); ++s) {
                any = true;
                if (nd == 0 && *s == '0') {
                    --dexp;
                } else if (nd < RD_DIGITS) {
                    digits[nd++] = *s;
                    --dexp;
                } else {
                    sticky |= *s != '0';
                }
            }
        }
        if (!any) {
            if (endptr != NULL) {
                *endptr = (char *)str;
            }
            return 0;
        }
        if ((*s == 'e' || *s == 'E') && (isdigit((unsigned char)s[1]) ||
            ((s[1] == '+' || s[1] == '-') && isdigit((unsigned char)s[2])))) {
            bool exp_negative = s[1] == '-';
            s += s[1] == '+' || s[1] == '-' ? 2 : 1;
            int e = 0;
            for (; isdigit((unsigned char)*s); ++s) {
                if (e < 100000) {
                    e = e * 10 + (*s - '0');
                }
            }
            dexp += exp_negative ? -e : e;
        }
        if (sticky) { /* digits were left out: a nonzero one makes it a bit more */
            digits[nd++] = '1';
            --dexp;
        }
        while (nd > 0 && digits[nd - 1] == '0') {
            --nd;
            ++dexp;
        }
        if (nd == 0) {
            v = 0;
        } else if (nd + dexp > 310) {
            zdos_errno = ERANGE;
            v = HUGE_VAL;
        } else if (nd + dexp < -323) {
            zdos_errno = ERANGE;
            v = 0;
        } else {
            v = rd_decimal(digits, nd, dexp);
            if (v == 0 || v == HUGE_VAL) {
                zdos_errno = ERANGE;
            }
        }
    }
    if (endptr != NULL) {
        *endptr = (char *)s;
    }
    return negative ? -v : v;
}

float strtof(const char *str, char **endptr) {
    return (float)strtod(str, endptr);
}

long double strtold(const char *str, char **endptr) {
    return strtod(str, endptr);
}

double atof(const char *str) {
    return strtod(str, NULL);
}

/* ARITHMETIC, SORTING, RANDOM NUMBERS */

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

div_t div(int num, int den) {
    div_t r = { num / den, num % den };
    return r;
}

ldiv_t ldiv(long num, long den) {
    ldiv_t r = { num / den, num % den };
    return r;
}

lldiv_t lldiv(long long num, long long den) {
    lldiv_t r = { num / den, num % den };
    return r;
}

static void swap_bytes(char *a, char *b, size_t n) {
    while (n-- > 0) {
        char t = *a;
        *a++ = *b;
        *b++ = t;
    }
}

typedef int (*compare_r_fn)(const void *, const void *, void *);

static void sift_down(char *base, size_t root, size_t end, size_t size, compare_r_fn compare, void *arg) {
    while (2 * root + 1 < end) {
        size_t child = 2 * root + 1;
        if (child + 1 < end && compare(base + child * size, base + (child + 1) * size, arg) < 0) {
            ++child;
        }
        if (compare(base + root * size, base + child * size, arg) >= 0) {
            return;
        }
        swap_bytes(base + root * size, base + child * size, size);
        root = child;
    }
}

/* Heap sort: no extra memory, no deep recursion (not stable, as
   qsort needn't be). qsort_r passes arg on to compare (the GNU and
   POSIX 2024 order). */
void qsort_r(void *base, size_t count, size_t size, int (*compare)(const void *, const void *, void *), void *arg) {
    char *b = base;
    if (count < 2 || size == 0) {
        return;
    }
    for (size_t i = count / 2; i > 0; --i) {
        sift_down(b, i - 1, count, size, compare, arg);
    }
    for (size_t end = count - 1; end > 0; --end) {
        swap_bytes(b, b + end * size, size);
        sift_down(b, 0, end, size, compare, arg);
    }
}

struct plain_compare {
    int (*compare)(const void *, const void *);
};

static int call_plain_compare(const void *a, const void *b, void *arg) {
    return ((struct plain_compare *)arg)->compare(a, b);
}

void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
    struct plain_compare c = {compare};
    qsort_r(base, count, size, call_plain_compare, &c);
}

void *bsearch(const void *key, const void *base, size_t count, size_t size, int (*compare)(const void *, const void *)) {
    const char *b = base;
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = compare(key, b + mid * size);
        if (c == 0) {
            return (void *)(b + mid * size);
        }
        if (c < 0) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return NULL;
}

static uint64_t rand_state = 1;

int rand(void) {
    rand_state = rand_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return (int)(rand_state >> 33);
}

void srand(unsigned int seed) {
    rand_state = seed;
}

/* VARIABLES AND COMMANDS */

/* Values handed out by getenv: kept until the program ends (ZDOS frees its
   memory then), so earlier pointers stay valid when a variable changes */
typedef struct env_entry {
    struct env_entry *next;
    char *name;
    char *value;
} env_entry;
static env_entry *env_cache;

/* Variables the program set where ZDOS let it not (global variables are
   for admins only): its own, as a process's environment on Unix; getenv
   sees them first, programs it starts don't */
typedef struct own_var {
    struct own_var *next;
    char *name;
    char *value; /* NULL: unset here */
} own_var;
static own_var *own_vars;

static own_var *own_find(const char *name) {
    for (own_var *v = own_vars; v != NULL; v = v->next) {
        if (strcasecmp(v->name, name) == 0) {
            return v;
        }
    }
    return NULL;
}

static int own_set(const char *name, const char *value) {
    own_var *v = own_find(name);
    if (v == NULL) {
        v = calloc(1, sizeof(*v));
        if (v == NULL || (v->name = strdup(name)) == NULL) {
            free(v);
            errno = ENOMEM;
            return -1;
        }
        v->next = own_vars;
        own_vars = v;
    }
    char *copy = value != NULL ? strdup(value) : NULL;
    if (value != NULL && copy == NULL) {
        errno = ENOMEM;
        return -1;
    }
    free(v->value);
    v->value = copy;
    return 0;
}

char *getenv(const char *name) {
    if (zdos == NULL || zdos->programs->get_var == NULL || name == NULL) {
        return NULL;
    }
    own_var *own = own_find(name);
    if (own != NULL) {
        return own->value;
    }
    size_t name_len = strlen(name);
    char small[128];
    int64_t n = zdos->programs->get_var(name, name_len, small, sizeof(small));
    if (n < 0) {
        return NULL;
    }
    char *value = malloc((size_t)n + 1);
    if (value == NULL) {
        return NULL;
    }
    if ((size_t)n <= sizeof(small)) {
        memcpy(value, small, (size_t)n);
    } else {
        zdos->programs->get_var(name, name_len, value, (size_t)n);
    }
    value[n] = '\0';
    if (zdos_library_one_copy) {
        return value; /* the caller's memory: no cache other programs see */
    }
    for (env_entry *e = env_cache; e != NULL; e = e->next) {
        if (strcmp(e->name, name) == 0 && strcmp(e->value, value) == 0) {
            free(value);
            return e->value;
        }
    }
    env_entry *e = malloc(sizeof(*e));
    char *name_copy = strdup(name);
    if (e == NULL || name_copy == NULL) {
        free(e);
        free(name_copy);
        return value; /* not cached: still valid until the program ends */
    }
    e->name = name_copy;
    e->value = value;
    e->next = env_cache;
    env_cache = e;
    return value;
}

int system(const char *command) {
    if (zdos == NULL || zdos->programs->run_command == NULL) {
        return command == NULL ? 0 : -1;
    }
    if (command == NULL) {
        return 1;
    }
    return zdos->programs->run_command(command, strlen(command));
}

/* setenv and its kin: the first change pushes a variable scope (push_vars),
   which ZDOS drops when the program ends. An empty value removes the
   variable (ZDOS has no empty ones). */
static bool env_scope_pushed;

static int env_check_name(const char *name) {
    if (name == NULL || name[0] == '\0' || strchr(name, '=') != NULL) {
        errno = EINVAL;
        return -1;
    }
    if (zdos == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (!env_scope_pushed) {
        if (!zdos->system->push_vars()) {
            errno = ENOMEM;
            return -1;
        }
        env_scope_pushed = true;
    }
    return 0;
}

void (*zdos_environ_hook)(const char *name, const char *value);

int setenv(const char *name, const char *value, int overwrite) {
    if (env_check_name(name) != 0) {
        return -1;
    }
    if (!overwrite && getenv(name) != NULL) {
        return 0;
    }
    if (!zdos->programs->set_var(name, strlen(name), value, strlen(value))) {
        if (zdos->programs->last_error() != ZDOS_ERROR_ACCESS_DENIED) {
            errno = zdos_errno_from_last_error();
            return -1;
        }
        if (own_set(name, value) != 0) {
            return -1;
        }
    } else if (own_find(name) != NULL) {
        own_set(name, value);
    }
    if (zdos_environ_hook != NULL) {
        zdos_environ_hook(name, value);
    }
    return 0;
}

int unsetenv(const char *name) {
    if (env_check_name(name) != 0) {
        return -1;
    }
    if (!zdos->programs->set_var(name, strlen(name), "", 0)) {
        if (zdos->programs->last_error() != ZDOS_ERROR_ACCESS_DENIED) {
            errno = zdos_errno_from_last_error();
            return -1;
        }
        if (own_set(name, NULL) != 0) {
            return -1;
        }
    } else if (own_find(name) != NULL) {
        own_set(name, NULL);
    }
    if (zdos_environ_hook != NULL) {
        zdos_environ_hook(name, NULL);
    }
    return 0;
}

/* "NAME=value" sets, "NAME" removes. The text is copied: changing it later
   does not change the variable, as it would on POSIX. */
int putenv(char *string) {
    const char *eq = string != NULL ? strchr(string, '=') : NULL;
    if (eq == NULL) {
        return unsetenv(string);
    }
    char *name = strndup(string, (size_t)(eq - string));
    if (name == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int result = setenv(name, eq + 1, 1);
    free(name);
    return result;
}

/* ENDING THE PROGRAM */

/* atexit's functions and C++'s destructors (__cxa_atexit), run
   in reverse order: 32 in place, more in blocks from malloc */
typedef struct exit_block {
    struct exit_block *prev;
    int count;
    struct {
        void (*plain)(void);
        void (*with_arg)(void *);
        void *arg;
    } fns[32];
} exit_block;
static exit_block first_exit_block;
static exit_block *exit_fns = &first_exit_block;
void (*zdos_crt0_fini)(void);
void (*zdos_thread_dtors_hook)(void);

/* What C++ objects are registered with (one program, no shared objects) */
__attribute__((visibility("hidden"))) void *__dso_handle = &__dso_handle;

static int add_exit_fn(void (*plain)(void), void (*with_arg)(void *), void *arg) {
    int result = 0;
    zdos_init_lock_take();
    exit_block *b = exit_fns;
    if (b->count == 32) {
        b = calloc(1, sizeof(*b));
        if (b != NULL) {
            b->prev = exit_fns;
            exit_fns = b;
        }
    }
    if (b == NULL) {
        result = -1;
    } else {
        b->fns[b->count].plain = plain;
        b->fns[b->count].with_arg = with_arg;
        b->fns[b->count].arg = arg;
        b->count++;
    }
    zdos_init_lock_give();
    return result;
}

int atexit(void (*func)(void)) {
    return add_exit_fn(func, NULL, NULL);
}

int __cxa_atexit(void (*func)(void *), void *arg, void *dso) {
    (void)dso;
    return add_exit_fn(NULL, func, arg);
}

// Each runs once, also when one of them calls exit or adds another
static void run_exit_fns(void) {
    for (;;) {
        exit_block *b = exit_fns;
        if (b->count == 0) {
            if (b->prev == NULL) {
                return;
            }
            exit_fns = b->prev;
            continue;
        }
        int i = --b->count;
        if (b->fns[i].plain != NULL) {
            b->fns[i].plain();
        } else {
            b->fns[i].with_arg(b->fns[i].arg);
        }
    }
}

void _Exit(int status) {
    if (zdos_vfork_child != NULL && zdos_vfork_exit_hook != NULL) {
        zdos_vfork_exit_hook(status); /* a vfork child's: the parent goes on */
    }
    if (zdos != NULL && zdos->programs->exit != NULL) {
        zdos->programs->exit((uint8_t)status);
    }
    for (;;) { /* no exit in the table: nothing else to do */
        if (zdos != NULL && zdos->time->sleep != NULL) {
            zdos->time->sleep(1000);
        }
    }
}

void _exit(int status) {
    _Exit(status);
}

void exit(int status) {
    if (zdos_vfork_child != NULL) {
        _Exit(status); /* a vfork child's: nothing of the parent's is run */
    }
    if (zdos_thread_dtors_hook != NULL) {
        zdos_thread_dtors_hook();
    }
    run_exit_fns();
    if (zdos_crt0_fini != NULL) {
        void (*fini)(void) = zdos_crt0_fini;
        zdos_crt0_fini = NULL;
        fini();
    }
    zdos_flush_streams();
    _Exit(status);
}

static void print_str(const char *s) {
    if (zdos != NULL && zdos->console->print != NULL) {
        zdos->console->print(s, strlen(s));
    }
}

void abort(void) {
    print_str("Abnormal program termination\n");
    _Exit(3);
}

void __assert_fail(const char *expr, const char *file, int line) {
    printf("Assertion failed: %s, file %s, line %d\n", expr, file, line);
    abort();
}

/* SIGNALS
   Raised by the program itself, and SIGINT for Ctrl+C: by default ZDOS ends
   the program on Ctrl+C. With SIGINT ignored or handled, the SDK tells zdos
   to pass Ctrl+C on as a key (set_ctrl_c); a Ctrl+C typed while the SDK
   reads a line from the keyboard (stdin) then calls the handler. */

void (*zdos_signal_handlers[ZDOS_NSIG])(int);
uint64_t zdos_signal_masks[ZDOS_NSIG]; /* sigaction's sa_mask */
int zdos_signal_flags[ZDOS_NSIG];      /* sigaction's sa_flags */
#define signal_handlers zdos_signal_handlers

static void sync_ctrl_c(void) {
    if (zdos != NULL && zdos->programs->set_ctrl_c != NULL) {
        zdos->programs->set_ctrl_c(signal_handlers[SIGINT] != SIG_DFL);
    }
}

/* Signals sent by other tasks (kill; on the metal editions) come here: the
   handler runs with its sa_mask blocked too, the signal itself blocked by
   ZDOS meanwhile */
static void ZDOS_CALL signal_dispatch(int sig) {
    if (sig <= 0 || sig >= ZDOS_NSIG) {
        return;
    }
    void (*handler)(int) = signal_handlers[sig];
    if (handler == SIG_DFL || handler == SIG_IGN) {
        return;
    }
    uint64_t mask = zdos_signal_masks[sig];
    uint64_t old = mask != 0 ? zdos->signals->mask(0, mask) : 0;
    if (zdos_signal_flags[sig] & SA_RESETHAND) {
        signal_handlers[sig] = SIG_DFL;
        zdos_signals_sync();
    }
    if (zdos_signal_flags[sig] & SA_SIGINFO) {
        siginfo_t info;
        memset(&info, 0, sizeof(info));
        info.si_signo = sig;
        ((void (*)(int, siginfo_t *, void *))(void *)handler)(sig, &info, NULL);
    } else {
        handler(sig);
    }
    if (mask != 0) {
        zdos->signals->mask(2, old);
    }
}

// Tells ZDOS the signals with a handler and those ignored, and whether Ctrl+C
// is a key
void zdos_signals_sync(void) {
    if (zdos_runtime_host != NULL) {
        return; /* in a library: the program's handlers are ZDOS's */
    }
    sync_ctrl_c();
    if (zdos == NULL || zdos->signals->set_handler == NULL) {
        return;
    }
    uint64_t caught = 0, ignored = 0;
    if (zdos_signal_flags[SIGCHLD] & SA_NOCLDWAIT) {
        ignored |= 1; /* bit 0: no status kept for this program's ended children */
    }
    for (int sig = 1; sig < ZDOS_NSIG - 1; sig++) {
        if (signal_handlers[sig] == SIG_IGN) {
            ignored |= (uint64_t)1 << sig;
        } else if (signal_handlers[sig] != SIG_DFL) {
            caught |= (uint64_t)1 << sig;
        }
    }
    zdos->signals->set_handler(caught != 0 ? signal_dispatch : NULL, caught, ignored);
}

void (*signal(int sig, void (*handler)(int)))(int) {
    if (sig <= 0 || sig >= ZDOS_NSIG - 1 || sig == SIGKILL || sig == SIGSTOP) {
        zdos_errno = EINVAL;
        return SIG_ERR;
    }
    if (zdos_runtime_host != NULL) {
        struct sigaction a, o;
        memset(&a, 0, sizeof(a));
        a.sa_handler = handler;
        return zdos_runtime_host->sig_action(sig, &a, &o) == 0 ? o.sa_handler : SIG_ERR;
    }
    void (*old)(int) = signal_handlers[sig];
    signal_handlers[sig] = handler;
    zdos_signal_masks[sig] = 0;
    zdos_signal_flags[sig] = 0;
    zdos_signals_sync();
    return old;
}

void zdos_ctrl_c_typed(void) {
    raise(SIGINT);
}

// The program's own signal, handled at once (on every edition). A handler
// stays set (as on Linux and BSD), unless sigaction gave SA_RESETHAND.
int raise(int sig) {
    if (zdos_runtime_host != NULL) {
        return zdos_runtime_host->sig_raise(sig);
    }
    if (sig <= 0 || sig >= ZDOS_NSIG - 1) {
        zdos_errno = EINVAL;
        return -1;
    }
    void (*handler)(int) = signal_handlers[sig];
    if (handler == SIG_IGN) {
        return 0;
    }
    if (handler == SIG_DFL) {
        if (sig == SIGABRT) {
            abort();
        }
        if (sig == SIGCHLD || sig == SIGURG || sig == SIGWINCH || sig == SIGCONT) {
            return 0; /* ignored by default */
        }
        _Exit(3);
    }
    signal_dispatch(sig);
    return 0;
}

/* LOCALE: "C" ONLY */

char *setlocale(int category, const char *locale) {
    (void)category;
    if (locale == NULL || locale[0] == '\0' || strcmp(locale, "C") == 0 || strcmp(locale, "POSIX") == 0) {
        return "C";
    }
    return NULL;
}

struct lconv *localeconv(void) {
    static struct lconv c = { ".", "", "", "", "", "", "", "", "", "",
                              CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX,
                              CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX, CHAR_MAX };
    return &c;
}

/* locale_t objects: all of them the "C" locale */
struct zdos_locale {
    int unused;
};
static struct zdos_locale c_locale;

locale_t newlocale(int mask, const char *name, locale_t base) {
    (void)mask;
    (void)base;
    if (name == NULL || setlocale(LC_ALL, name) == NULL) {
        errno = name == NULL ? EINVAL : ENOENT;
        return NULL;
    }
    return &c_locale;
}

locale_t duplocale(locale_t loc) {
    (void)loc;
    return &c_locale;
}

void freelocale(locale_t loc) {
    (void)loc;
}

locale_t uselocale(locale_t loc) {
    (void)loc;
    return LC_GLOBAL_LOCALE;
}

int isalnum_l(int c, locale_t loc) { (void)loc; return isalnum(c); }
int isalpha_l(int c, locale_t loc) { (void)loc; return isalpha(c); }
int isblank_l(int c, locale_t loc) { (void)loc; return isblank(c); }
int iscntrl_l(int c, locale_t loc) { (void)loc; return iscntrl(c); }
int isdigit_l(int c, locale_t loc) { (void)loc; return isdigit(c); }
int isgraph_l(int c, locale_t loc) { (void)loc; return isgraph(c); }
int islower_l(int c, locale_t loc) { (void)loc; return islower(c); }
int isprint_l(int c, locale_t loc) { (void)loc; return isprint(c); }
int ispunct_l(int c, locale_t loc) { (void)loc; return ispunct(c); }
int isspace_l(int c, locale_t loc) { (void)loc; return isspace(c); }
int isupper_l(int c, locale_t loc) { (void)loc; return isupper(c); }
int isxdigit_l(int c, locale_t loc) { (void)loc; return isxdigit(c); }
int tolower_l(int c, locale_t loc) { (void)loc; return tolower(c); }
int toupper_l(int c, locale_t loc) { (void)loc; return toupper(c); }
int strcoll_l(const char *a, const char *b, locale_t loc) { (void)loc; return strcmp(a, b); }
size_t strxfrm_l(char *dest, const char *src, size_t n, locale_t loc) { (void)loc; return strxfrm(dest, src, n); }
long strtol_l(const char *s, char **end, int base, locale_t loc) { (void)loc; return strtol(s, end, base); }
unsigned long strtoul_l(const char *s, char **end, int base, locale_t loc) { (void)loc; return strtoul(s, end, base); }
long long strtoll_l(const char *s, char **end, int base, locale_t loc) { (void)loc; return strtoll(s, end, base); }
unsigned long long strtoull_l(const char *s, char **end, int base, locale_t loc) { (void)loc; return strtoull(s, end, base); }
double strtod_l(const char *s, char **end, locale_t loc) { (void)loc; return strtod(s, end); }
float strtof_l(const char *s, char **end, locale_t loc) { (void)loc; return strtof(s, end); }
long double strtold_l(const char *s, char **end, locale_t loc) { (void)loc; return strtold(s, end); }
size_t strftime_l(char *s, size_t max, const char *format, const struct tm *tm, locale_t loc) {
    (void)loc;
    return strftime(s, max, format, tm);
}

/* TIME */

/* Days since 1970-01-01 of a date (proleptic Gregorian calendar) */
static int64_t days_from_civil(int64_t y, int m, int d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static void civil_from_days(int64_t z, int64_t *year, int *month, int *day) {
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    *day = (int)(doy - (153 * mp + 2) / 5 + 1);
    *month = (int)(mp < 10 ? mp + 3 : mp - 9);
    *year = yoe + era * 400 + (*month <= 2);
}

/* TIME ZONES: THE POSIX TZ VARIABLE ("EST5EDT,M3.2.0,M11.1.0",
   "<+03>-3"), no tz database. ZDOS's clock is local time; without TZ
   it is taken as UTC. */

typedef struct {
    char kind; /* 'J': day 1-365 without Feb 29; 'D': day 0-365; 'M': month.week.weekday */
    int day, week, month;
    int32_t time; /* local seconds after midnight (may be negative or past a day) */
} tz_rule;

static struct {
    bool parsed;
    char text[64]; /* the TZ it was parsed from */
    char std_name[16], dst_name[16];
    int32_t std_off, dst_off; /* seconds west of UTC, as POSIX counts */
    bool has_dst;
    tz_rule start, end;
} tz;

char *tzname[2] = {"UTC", "UTC"};
long timezone;
int daylight;

// A name: 3 or more letters, or anything but '>' in <...>
static const char *tz_parse_name(const char *p, char *out) {
    size_t n = 0;
    if (*p == '<') {
        for (++p; *p != '>'; ++p) {
            if (*p == '\0' || n + 1 >= 16) {
                return NULL;
            }
            out[n++] = *p;
        }
        ++p;
    } else {
        for (; isalpha((unsigned char)*p); ++p) {
            if (n + 1 >= 16) {
                return NULL;
            }
            out[n++] = *p;
        }
    }
    out[n] = '\0';
    return n >= 3 ? p : NULL;
}

// [+-]hh[:mm[:ss]] in seconds, hours up to max_hours
static const char *tz_parse_time(const char *p, int32_t *out, int max_hours) {
    int sign = 1;
    if (*p == '+' || *p == '-') {
        sign = *p++ == '-' ? -1 : 1;
    }
    int32_t part[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) {
        if (i > 0 && *p != ':') {
            break;
        }
        if (i > 0) {
            ++p;
        }
        if (!isdigit((unsigned char)*p)) {
            return NULL;
        }
        while (isdigit((unsigned char)*p)) {
            part[i] = part[i] * 10 + (*p++ - '0');
            if (part[i] > 999) {
                return NULL;
            }
        }
    }
    if (part[0] > max_hours || part[1] > 59 || part[2] > 59) {
        return NULL;
    }
    *out = sign * (part[0] * 3600 + part[1] * 60 + part[2]);
    return p;
}

static const char *tz_parse_number(const char *p, int *out, int lo, int hi) {
    if (!isdigit((unsigned char)*p)) {
        return NULL;
    }
    int v = 0;
    while (isdigit((unsigned char)*p) && v <= hi) {
        v = v * 10 + (*p++ - '0');
    }
    *out = v;
    return v >= lo && v <= hi ? p : NULL;
}

// Jn, n or Mm.w.d, then /time (default 02:00)
static const char *tz_parse_rule(const char *p, tz_rule *r) {
    r->time = 7200;
    if (*p == 'J') {
        r->kind = 'J';
        p = tz_parse_number(p + 1, &r->day, 1, 365);
    } else if (*p == 'M') {
        r->kind = 'M';
        p = tz_parse_number(p + 1, &r->month, 1, 12);
        if (p == NULL || *p++ != '.' || (p = tz_parse_number(p, &r->week, 1, 5)) == NULL || *p++ != '.') {
            return NULL;
        }
        p = tz_parse_number(p, &r->day, 0, 6);
    } else {
        r->kind = 'D';
        p = tz_parse_number(p, &r->day, 0, 365);
    }
    if (p != NULL && *p == '/') {
        p = tz_parse_time(p + 1, &r->time, 167);
    }
    return p;
}

static bool tz_parse(const char *p) {
    if (*p == ':') {
        ++p; /* a file name on Unix; here only a POSIX string */
    }
    if ((p = tz_parse_name(p, tz.std_name)) == NULL || (p = tz_parse_time(p, &tz.std_off, 24)) == NULL) {
        return false;
    }
    tz.has_dst = *p != '\0';
    if (!tz.has_dst) {
        return true;
    }
    if ((p = tz_parse_name(p, tz.dst_name)) == NULL) {
        return false;
    }
    tz.dst_off = tz.std_off - 3600;
    if (*p != '\0' && *p != ',' && (p = tz_parse_time(p, &tz.dst_off, 24)) == NULL) {
        return false;
    }
    if (*p == '\0') { /* no rules: the US ones, as glibc and musl take */
        tz.start = (tz_rule){'M', 0, 2, 3, 7200};
        tz.end = (tz_rule){'M', 0, 1, 11, 7200};
        return true;
    }
    if (*p != ',' || (p = tz_parse_rule(p + 1, &tz.start)) == NULL || *p != ',' ||
        (p = tz_parse_rule(p + 1, &tz.end)) == NULL) {
        return false;
    }
    return *p == '\0';
}

void tzset(void) {
    const char *v = getenv("TZ");
    if (v == NULL) {
        v = "";
    }
    if (tz.parsed && strcmp(v, tz.text) == 0) {
        return;
    }
    if (*v == '\0' || !tz_parse(v)) { /* none, or not understood: UTC */
        strcpy(tz.std_name, "UTC");
        tz.std_off = 0;
        tz.has_dst = false;
    }
    tz.parsed = strlen(v) < sizeof(tz.text);
    if (tz.parsed) {
        strcpy(tz.text, v);
    }
    tzname[0] = tz.std_name;
    tzname[1] = tz.has_dst ? tz.dst_name : tz.std_name;
    timezone = tz.std_off;
    daylight = tz.has_dst;
}

// Seconds since 1970 (local time) when rule r begins in year
static int64_t tz_rule_time(int64_t year, const tz_rule *r) {
    int64_t day;
    if (r->kind == 'J') {
        bool leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
        day = days_from_civil(year, 1, 1) + r->day - 1 + (leap && r->day >= 60);
    } else if (r->kind == 'D') {
        day = days_from_civil(year, 1, 1) + r->day;
    } else {
        int64_t first = days_from_civil(year, r->month, 1);
        int64_t next = r->month == 12 ? days_from_civil(year + 1, 1, 1) : days_from_civil(year, r->month + 1, 1);
        int wday = (int)(((first % 7) + 11) % 7); /* 1970-01-01 was a Thursday */
        day = first + (r->day - wday + 7) % 7 + (r->week - 1) * 7;
        while (day >= next) { /* week 5: the last one */
            day -= 7;
        }
    }
    return day * 86400 + r->time;
}

// Whether UTC time t is in daylight saving time
static bool tz_is_dst(int64_t t) {
    if (!tz.has_dst) {
        return false;
    }
    int64_t local_days = t - tz.std_off;
    local_days = (local_days >= 0 ? local_days : local_days - 86399) / 86400;
    int64_t year;
    int month, day;
    civil_from_days(local_days, &year, &month, &day);
    int64_t start = tz_rule_time(year, &tz.start) + tz.std_off; /* given in standard time */
    int64_t end = tz_rule_time(year, &tz.end) + tz.dst_off;     /* given in summer time */
    if (start < end) {
        return t >= start && t < end;
    }
    return !(t >= end && t < start); /* southern half: summer across the new year */
}

/* Local seconds since 1970 -> UTC. isdst < 0: found out; a local
   time that happens twice is taken as summer time (as glibc), one
   skipped as the time after. */
static int64_t tz_to_utc(int64_t local, int isdst) {
    if (!tz.has_dst) {
        return local + tz.std_off;
    }
    if (isdst >= 0) {
        return local + (isdst > 0 ? tz.dst_off : tz.std_off);
    }
    int64_t as_std = local + tz.std_off, as_dst = local + tz.dst_off;
    return tz_is_dst(as_dst) ? as_dst : as_std;
}

int64_t zdos_epoch_from_time(const zdos_time *t) {
    int64_t local = days_from_civil(t->year, t->month, t->day) * 86400 + t->hour * 3600 + t->minute * 60 + t->second;
    tzset();
    return tz_to_utc(local, -1);
}

time_t time(time_t *out) {
    time_t now = (time_t)-1;
    if (zdos != NULL && zdos->time->get != NULL) {
        zdos_time t;
        zdos->time->get(&t);
        if (t.year != 0) { /* 0: the platform has no clock */
            now = zdos_epoch_from_time(&t);
        }
    }
    if (out != NULL) {
        *out = now;
    }
    return now;
}

clock_t clock(void) {
    return zdos != NULL && zdos->time->millis != NULL ? (clock_t)zdos->time->millis() : (clock_t)-1;
}

double difftime(time_t end, time_t start) {
    return (double)(end - start);
}

struct tm *gmtime_r(const time_t *t, struct tm *out) {
    int64_t days = *t / 86400;
    int64_t secs = *t % 86400;
    if (secs < 0) {
        secs += 86400;
        --days;
    }
    int64_t year;
    int month, day;
    civil_from_days(days, &year, &month, &day);
    out->tm_sec = (int)(secs % 60);
    out->tm_min = (int)(secs / 60 % 60);
    out->tm_hour = (int)(secs / 3600);
    out->tm_mday = day;
    out->tm_mon = month - 1;
    out->tm_year = (int)(year - 1900);
    out->tm_wday = (int)(((days % 7) + 11) % 7); /* 1970-01-01 was a Thursday */
    out->tm_yday = (int)(days - days_from_civil(year, 1, 1));
    out->tm_isdst = 0;
    out->tm_gmtoff = 0;
    out->tm_zone = "UTC";
    return out;
}

struct tm *localtime_r(const time_t *t, struct tm *out) {
    tzset();
    bool dst = tz_is_dst(*t);
    int32_t west = dst ? tz.dst_off : tz.std_off;
    time_t local = *t - west;
    gmtime_r(&local, out);
    out->tm_isdst = dst;
    out->tm_gmtoff = -west;
    out->tm_zone = dst ? tz.dst_name : tz.std_name;
    return out;
}

struct tm *gmtime(const time_t *t) {
    static struct tm result;
    return gmtime_r(t, &result);
}

struct tm *localtime(const time_t *t) {
    static struct tm result;
    return localtime_r(t, &result);
}

/* "Sun Sep 16 01:03:52 1973\n": 26 bytes with the 0 (years 1000-9999) */
char *asctime_r(const struct tm *tm, char *buf) {
    return strftime(buf, 26, "%a %b %e %H:%M:%S %Y\n", tm) == 25 ? buf : NULL;
}

char *asctime(const struct tm *tm) {
    static char result[26];
    return asctime_r(tm, result);
}

char *ctime_r(const time_t *t, char *buf) {
    struct tm tm;
    return localtime_r(t, &tm) != NULL ? asctime_r(&tm, buf) : NULL;
}

char *ctime(const time_t *t) {
    static char result[26];
    return ctime_r(t, result);
}

/* The fields as seconds since 1970, those out of range carried over (month
   13 is January of the next year ...) */
static int64_t tm_seconds(const struct tm *tm) {
    int64_t year = (int64_t)tm->tm_year + 1900 + tm->tm_mon / 12;
    int mon = tm->tm_mon % 12;
    if (mon < 0) {
        mon += 12;
        --year;
    }
    return (days_from_civil(year, mon + 1, 1) + tm->tm_mday - 1) * 86400 +
        (int64_t)tm->tm_hour * 3600 + (int64_t)tm->tm_min * 60 + tm->tm_sec;
}

time_t timegm(struct tm *tm) {
    time_t t = tm_seconds(tm);
    gmtime_r(&t, tm);
    return t;
}

/* tm (local time) is normalized and gets tm_wday, tm_yday and tm_isdst */
time_t mktime(struct tm *tm) {
    tzset();
    time_t t = tz_to_utc(tm_seconds(tm), tm->tm_isdst);
    localtime_r(&t, tm);
    return t;
}

// Sleeps ms; a signal (metal) ends it early: the milliseconds left then
static uint64_t sleep_ms(uint64_t ms) {
    if (zdos == NULL || zdos->time->nap == NULL) {
        return 0;
    }
    while (ms > 0) {
        uint32_t step = ms > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)ms;
        uint32_t left = zdos->time->nap(step);
        ms -= step;
        if (left != 0) {
            return ms + left;
        }
    }
    return 0;
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
    if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000L) {
        zdos_errno = EINVAL;
        return -1;
    }
    if (zdos != NULL && zdos->time->nap_until != NULL) {
        /* Until a deadline: nanoseconds, to the timer's precision */
        uint64_t ns = (uint64_t)req->tv_sec * 1000000000ULL + (uint64_t)req->tv_nsec;
        uint64_t left_ns = zdos->time->nap_until(zdos->time->nanos() + ns);
        if (rem != NULL) {
            rem->tv_sec = (time_t)(left_ns / 1000000000ULL);
            rem->tv_nsec = (long)(left_ns % 1000000000ULL);
        }
        if (left_ns != 0) {
            errno = EINTR;
            return -1;
        }
        return 0;
    }
    uint64_t left = sleep_ms((uint64_t)req->tv_sec * 1000 + ((uint64_t)req->tv_nsec + 999999) / 1000000);
    if (rem != NULL) {
        rem->tv_sec = (time_t)(left / 1000);
        rem->tv_nsec = (long)(left % 1000) * 1000000L;
    }
    if (left != 0) {
        errno = EINTR;
        return -1;
    }
    return 0;
}

unsigned int sleep(unsigned int seconds) {
    uint64_t left = sleep_ms((uint64_t)seconds * 1000);
    return (unsigned int)((left + 999) / 1000);
}

int usleep(useconds_t usec) {
    struct timespec t = {(time_t)(usec / 1000000), (long)(usec % 1000000) * 1000L};
    if (zdos != NULL && zdos->time->nap_until != NULL) {
        return nanosleep(&t, NULL);
    }
    if (sleep_ms(((uint64_t)usec + 999) / 1000) != 0) {
        errno = EINTR;
        return -1;
    }
    return 0;
}

/* Nanoseconds since ZDOS started: the CPU's counter (time->nanos), or the
   millisecond counter on a ZDOS without it (its resolution slot answers 0) */
static uint64_t mono_nanos(void) {
    if (zdos == NULL) {
        return 0;
    }
    if (zdos->time->resolution() != 0) {
        return zdos->time->nanos();
    }
    return zdos->time->millis() * 1000000ULL;
}

static uint64_t mono_step(void) {
    uint64_t r = zdos != NULL ? zdos->time->resolution() : 0;
    return r != 0 ? r : 1000000ULL;
}

/* The clock's seconds at the first call, then the counter on top of them:
   fractions of a second, and it never runs backwards */
static void realtime(struct timespec *ts) {
    static time_t base_sec;
    static uint64_t base_ns;
    static bool have_base;
    uint64_t now = mono_nanos();
    if (!have_base) {
        base_sec = time(NULL);
        base_ns = now;
        have_base = true;
    }
    uint64_t elapsed = now - base_ns;
    ts->tv_sec = base_sec + (time_t)(elapsed / 1000000000ULL);
    ts->tv_nsec = (long)(elapsed % 1000000000ULL);
}

/* The running task's CPU milliseconds (0 where tasks don't switch) */
uint64_t zdos_own_cpu_ms(void) {
    if (zdos == NULL || zdos->tasks->info == NULL || zdos->tasks->id == NULL) {
        return 0;
    }
    uint32_t me = zdos->tasks->id();
    zdos_task_info info;
    for (uint32_t i = 0; zdos->tasks->info(i, &info); i++) {
        if (info.id == me) {
            return info.cpu_ms;
        }
    }
    return 0;
}

// CLOCK_REALTIME: the date's seconds at the first call plus the counter;
// CLOCK_MONOTONIC (also _RAW, BOOTTIME): since ZDOS started;
// the CPU-time clocks: the running task's (a thread is a task
// of its own), in ms steps
int clock_gettime(clockid_t id, struct timespec *ts) {
    if (id == CLOCK_PROCESS_CPUTIME_ID || id == CLOCK_THREAD_CPUTIME_ID) {
        uint64_t ms = zdos_own_cpu_ms();
        ts->tv_sec = (time_t)(ms / 1000);
        ts->tv_nsec = (long)(ms % 1000 * 1000000);
        return 0;
    }
    if (id == CLOCK_MONOTONIC || id == CLOCK_MONOTONIC_RAW || id == CLOCK_BOOTTIME) {
        uint64_t ns = mono_nanos();
        ts->tv_sec = (time_t)(ns / 1000000000ULL);
        ts->tv_nsec = (long)(ns % 1000000000ULL);
        return 0;
    }
    if (id != CLOCK_REALTIME) {
        errno = EINVAL;
        return -1;
    }
    realtime(ts);
    return 0;
}

int clock_getres(clockid_t id, struct timespec *res) {
    if (id == CLOCK_PROCESS_CPUTIME_ID || id == CLOCK_THREAD_CPUTIME_ID) {
        if (res != NULL) {
            res->tv_sec = 0;
            res->tv_nsec = 1000000;
        }
        return 0;
    }
    if (id != CLOCK_REALTIME && id != CLOCK_MONOTONIC && id != CLOCK_MONOTONIC_RAW && id != CLOCK_BOOTTIME) {
        errno = EINVAL;
        return -1;
    }
    if (res != NULL) {
        uint64_t step = mono_step();
        res->tv_sec = (time_t)(step / 1000000000ULL);
        res->tv_nsec = (long)(step % 1000000000ULL);
    }
    return 0;
}

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    struct timespec ts;
    realtime(&ts);
    tv->tv_sec = ts.tv_sec;
    tv->tv_usec = (suseconds_t)(ts.tv_nsec / 1000);
    return 0;
}

/* strftime in the "C" locale; E and O modifiers ignored. %z and %Z
   from tm_gmtoff and tm_zone (tzname when tm_zone is NULL). 0 also
   for an unknown conversion. */
static const char *const weekday_names[7] = {
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *const month_names[12] = {
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December"};

/* Weeks of an ISO year (52 or 53): 53 when p(y) is 4 (Thursday) or p(y-1)
   is 3 (Wednesday), where p(y) = (y + y/4 - y/100 + y/400) mod 7 */
static int iso_weeks_in_year(int64_t y) {
    int64_t p = (y + y / 4 - y / 100 + y / 400) % 7;
    int64_t q = (y - 1 + (y - 1) / 4 - (y - 1) / 100 + (y - 1) / 400) % 7;
    return p == 4 || q == 3 ? 53 : 52;
}

/* The ISO 8601 year and week number of a date (week 1 has the year's
   first Thursday) */
static void iso_week(const struct tm *tm, int64_t *year, int *week) {
    int64_t y = tm->tm_year + 1900LL;
    int monday_based = (tm->tm_wday + 6) % 7;
    int w = (tm->tm_yday - monday_based + 10) / 7;
    if (w < 1) {
        w = iso_weeks_in_year(y - 1);
        --y;
    } else if (w > iso_weeks_in_year(y)) {
        w = 1;
        ++y;
    }
    *year = y;
    *week = w;
}

static bool put_text(char *s, size_t max, size_t *n, const char *text) {
    for (; *text != '\0'; ++text) {
        if (*n + 1 >= max) {
            return false;
        }
        s[(*n)++] = *text;
    }
    return true;
}

size_t strftime(char *s, size_t max, const char *format, const struct tm *tm) {
    size_t n = 0;
    char part[80];
    int wday = tm->tm_wday;
    int64_t year = tm->tm_year + 1900LL;
    int64_t iso_year;
    int iso_w;
    if (max == 0) {
        return 0;
    }
    iso_week(tm, &iso_year, &iso_w);
    for (const char *f = format; *f != '\0'; ++f) {
        const char *text = NULL;
        size_t len;
        if (*f != '%') {
            if (n + 1 >= max) {
                return 0;
            }
            s[n++] = *f;
            continue;
        }
        ++f;
        while (*f == 'E' || *f == 'O') {
            ++f;
        }
        switch (*f) {
        case '%': text = "%"; break;
        case 'n': text = "\n"; break;
        case 't': text = "\t"; break;
        case 'a': snprintf(part, sizeof part, "%.3s", weekday_names[wday % 7]); text = part; break;
        case 'A': text = weekday_names[wday % 7]; break;
        case 'b': case 'h': snprintf(part, sizeof part, "%.3s", month_names[tm->tm_mon % 12]); text = part; break;
        case 'B': text = month_names[tm->tm_mon % 12]; break;
        case 'c': len = strftime(part, sizeof part, "%a %b %e %H:%M:%S %Y", tm); if (len == 0) return 0; text = part; break;
        case 'x': case 'D': len = strftime(part, sizeof part, "%m/%d/%y", tm); if (len == 0) return 0; text = part; break;
        case 'X': case 'T': len = strftime(part, sizeof part, "%H:%M:%S", tm); if (len == 0) return 0; text = part; break;
        case 'F': len = strftime(part, sizeof part, "%Y-%m-%d", tm); if (len == 0) return 0; text = part; break;
        case 'r': len = strftime(part, sizeof part, "%I:%M:%S %p", tm); if (len == 0) return 0; text = part; break;
        case 'R': len = strftime(part, sizeof part, "%H:%M", tm); if (len == 0) return 0; text = part; break;
        case 'p': text = tm->tm_hour < 12 ? "AM" : "PM"; break;
        case 'C': snprintf(part, sizeof part, "%02d", (int)(year / 100)); text = part; break;
        case 'd': snprintf(part, sizeof part, "%02d", tm->tm_mday); text = part; break;
        case 'e': snprintf(part, sizeof part, "%2d", tm->tm_mday); text = part; break;
        case 'g': snprintf(part, sizeof part, "%02d", (int)(iso_year % 100)); text = part; break;
        case 'G': snprintf(part, sizeof part, "%lld", (long long)iso_year); text = part; break;
        case 'H': snprintf(part, sizeof part, "%02d", tm->tm_hour); text = part; break;
        case 'I': snprintf(part, sizeof part, "%02d", tm->tm_hour % 12 == 0 ? 12 : tm->tm_hour % 12); text = part; break;
        case 'j': snprintf(part, sizeof part, "%03d", tm->tm_yday + 1); text = part; break;
        case 'm': snprintf(part, sizeof part, "%02d", tm->tm_mon + 1); text = part; break;
        case 'M': snprintf(part, sizeof part, "%02d", tm->tm_min); text = part; break;
        case 'S': snprintf(part, sizeof part, "%02d", tm->tm_sec); text = part; break;
        case 'u': snprintf(part, sizeof part, "%d", wday == 0 ? 7 : wday); text = part; break;
        case 'w': snprintf(part, sizeof part, "%d", wday); text = part; break;
        case 'U': snprintf(part, sizeof part, "%02d", (tm->tm_yday + 7 - wday) / 7); text = part; break;
        case 'W': snprintf(part, sizeof part, "%02d", (tm->tm_yday + 7 - (wday + 6) % 7) / 7); text = part; break;
        case 'V': snprintf(part, sizeof part, "%02d", iso_w); text = part; break;
        case 'y': snprintf(part, sizeof part, "%02d", (int)(year % 100)); text = part; break;
        case 'Y': snprintf(part, sizeof part, "%lld", (long long)year); text = part; break;
        case 'z': {
            long off = tm->tm_gmtoff;
            long a = (off < 0 ? -off : off) / 60;
            snprintf(part, sizeof part, "%c%02ld%02ld", off < 0 ? '-' : '+', a / 60, a % 60);
            text = part;
            break;
        }
        case 'Z':
            tzset();
            text = tm->tm_zone != NULL ? tm->tm_zone : tzname[tm->tm_isdst > 0];
            break;
        default:
            return 0;
        }
        if (!put_text(s, max, &n, text)) {
            return 0;
        }
    }
    s[n] = '\0';
    return n;
}

/* strptime in the "C" locale; E and O modifiers and %z are read and ignored. */
static const char *pt_space(const char *s) {
    while (isspace((unsigned char)*s)) {
        ++s;
    }
    return s;
}

static const char *pt_number(const char *s, int width, int min, int max, int *out) {
    s = pt_space(s);
    int value = 0, digits = 0;
    while (digits < width && isdigit((unsigned char)*s)) {
        value = value * 10 + (*s - '0');
        ++s;
        ++digits;
    }
    if (digits == 0 || value < min || value > max) {
        return NULL;
    }
    *out = value;
    return s;
}

/* A day or month name, in full or its first three letters, any case */
static const char *pt_name(const char *s, const char *const names[], int count, int *out) {
    s = pt_space(s);
    for (int i = 0; i < count; i++) {
        size_t n = strlen(names[i]);
        if (strncasecmp(s, names[i], n) == 0) {
            *out = i;
            return s + n;
        }
    }
    for (int i = 0; i < count; i++) {
        if (strncasecmp(s, names[i], 3) == 0) {
            *out = i;
            return s + 3;
        }
    }
    return NULL;
}

char *strptime(const char *s, const char *format, struct tm *tm) {
    int hour12 = -1, pm = -1, century = -1, year2 = -1;
    for (const char *f = format; *f != '\0' && s != NULL; ++f) {
        if (isspace((unsigned char)*f)) {
            s = pt_space(s);
            continue;
        }
        if (*f != '%') {
            if (*s != *f) {
                return NULL;
            }
            ++s;
            continue;
        }
        ++f;
        if (*f == 'E' || *f == 'O') {
            ++f;
        }
        int v;
        switch (*f) {
            case '%':
                s = *s == '%' ? s + 1 : NULL;
                break;
            case 'n':
            case 't':
                s = pt_space(s);
                break;
            case 'a':
            case 'A':
                if ((s = pt_name(s, weekday_names, 7, &v)) != NULL) tm->tm_wday = v;
                break;
            case 'b':
            case 'B':
            case 'h':
                if ((s = pt_name(s, month_names, 12, &v)) != NULL) tm->tm_mon = v;
                break;
            case 'C':
                s = pt_number(s, 2, 0, 99, &century);
                break;
            case 'd':
            case 'e':
                if ((s = pt_number(s, 2, 1, 31, &v)) != NULL) tm->tm_mday = v;
                break;
            case 'D':
                s = strptime(s, "%m/%d/%y", tm);
                break;
            case 'F':
                s = strptime(s, "%Y-%m-%d", tm);
                break;
            case 'H':
                if ((s = pt_number(s, 2, 0, 23, &v)) != NULL) tm->tm_hour = v;
                break;
            case 'I':
                s = pt_number(s, 2, 1, 12, &hour12);
                break;
            case 'j':
                if ((s = pt_number(s, 3, 1, 366, &v)) != NULL) tm->tm_yday = v - 1;
                break;
            case 'm':
                if ((s = pt_number(s, 2, 1, 12, &v)) != NULL) tm->tm_mon = v - 1;
                break;
            case 'M':
                if ((s = pt_number(s, 2, 0, 59, &v)) != NULL) tm->tm_min = v;
                break;
            case 'p':
                s = pt_space(s);
                if (strncasecmp(s, "AM", 2) == 0) {
                    pm = 0;
                    s += 2;
                } else if (strncasecmp(s, "PM", 2) == 0) {
                    pm = 1;
                    s += 2;
                } else {
                    s = NULL;
                }
                break;
            case 'r':
                s = strptime(s, "%I:%M:%S %p", tm);
                break;
            case 'R':
                s = strptime(s, "%H:%M", tm);
                break;
            case 'S':
                if ((s = pt_number(s, 2, 0, 60, &v)) != NULL) tm->tm_sec = v;
                break;
            case 'T':
                s = strptime(s, "%H:%M:%S", tm);
                break;
            case 'u':
                if ((s = pt_number(s, 1, 1, 7, &v)) != NULL) tm->tm_wday = v % 7;
                break;
            case 'w':
                if ((s = pt_number(s, 1, 0, 6, &v)) != NULL) tm->tm_wday = v;
                break;
            case 'y':
                s = pt_number(s, 2, 0, 99, &year2);
                break;
            case 'Y':
                if ((s = pt_number(s, 4, 0, 9999, &v)) != NULL) tm->tm_year = v - 1900;
                break;
            case 'z':
                s = pt_space(s);
                if (*s == 'Z') {
                    ++s;
                } else if (*s == '+' || *s == '-') {
                    int hours, minutes = 0;
                    s = pt_number(s + 1, 2, 0, 23, &hours);
                    if (s != NULL && *s == ':') ++s;
                    if (s != NULL && isdigit((unsigned char)*s)) s = pt_number(s, 2, 0, 59, &minutes);
                } else {
                    s = NULL;
                }
                break;
            default:
                s = NULL;
                break;
        }
    }
    if (s == NULL) {
        return NULL;
    }
    if (hour12 >= 0) {
        tm->tm_hour = hour12 % 12 + (pm == 1 ? 12 : 0);
    }
    if (year2 >= 0) {
        /* without %C: 69-99 are 1969-1999, 00-68 are 2000-2068 (POSIX) */
        tm->tm_year = century >= 0 ? century * 100 + year2 - 1900 : (year2 < 69 ? year2 + 100 : year2);
    } else if (century >= 0) {
        tm->tm_year = century * 100 - 1900;
    }
    return (char *)s;
}

/* FORMATTED OUTPUT */

/* Where formatted text goes: a string (snprintf) or, in pieces, a
   stream (fprintf, printf). count is everything produced, for the
   return value, also what didn't fit. */
typedef struct {
    char *buf;
    size_t size;
    size_t pos;
    FILE *stream;
    char chunk[128];
    size_t chunk_len;
    size_t count;
} fmt_out;

static void out_flush(fmt_out *o) {
    if (o->stream != NULL && o->chunk_len > 0) {
        fwrite(o->chunk, 1, o->chunk_len, o->stream);
    }
    o->chunk_len = 0;
}

static void out_char(fmt_out *o, char c) {
    if (o->stream != NULL) {
        o->chunk[o->chunk_len++] = c;
        if (o->chunk_len == sizeof(o->chunk)) {
            out_flush(o);
        }
    } else if (o->pos + 1 < o->size) {
        o->buf[o->pos++] = c;
    }
    ++o->count;
}

static void out_chars(fmt_out *o, const char *s, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        out_char(o, s[i]);
    }
}

static void out_repeat(fmt_out *o, char c, int n) {
    for (int i = 0; i < n; ++i) {
        out_char(o, c);
    }
}

typedef struct {
    bool minus, plus, space, zero, hash;
    int width;
    int precision; /* -1: none given */
} fmt_spec;

/* prefix (sign, "0x"), then zeros, then body, padded to the width */
static void out_padded(fmt_out *o, const fmt_spec *sp, const char *prefix, size_t prefix_len, int zeros,
    const char *body, size_t body_len, bool zero_pad) {
    int len = (int)(prefix_len + body_len) + zeros;
    int pad = sp->width > len ? sp->width - len : 0;
    if (!sp->minus && !zero_pad) {
        out_repeat(o, ' ', pad);
    }
    out_chars(o, prefix, prefix_len);
    if (!sp->minus && zero_pad) {
        out_repeat(o, '0', pad);
    }
    out_repeat(o, '0', zeros);
    out_chars(o, body, body_len);
    if (sp->minus) {
        out_repeat(o, ' ', pad);
    }
}

static void fmt_integer(fmt_out *o, const fmt_spec *sp, uintmax_t value, bool negative, unsigned base, bool upper) {
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char buf[72];
    size_t n = 0;
    if (!(value == 0 && sp->precision == 0)) {
        do {
            buf[sizeof(buf) - 1 - n++] = digits[value % base];
            value /= base;
        } while (value != 0);
    }
    char prefix[3];
    size_t prefix_len = 0;
    if (negative) {
        prefix[prefix_len++] = '-';
    } else if (sp->plus) {
        prefix[prefix_len++] = '+';
    } else if (sp->space) {
        prefix[prefix_len++] = ' ';
    }
    int zeros = sp->precision > (int)n ? sp->precision - (int)n : 0;
    if (sp->hash && base == 16 && n > 0 && !(n == 1 && buf[sizeof(buf) - 1] == '0')) {
        prefix[prefix_len++] = '0';
        prefix[prefix_len++] = upper ? 'X' : 'x';
    } else if (sp->hash && base == 8 && zeros == 0 && (n == 0 || buf[sizeof(buf) - n] != '0')) {
        zeros = 1; /* octal with #: starts with 0 */
    }
    out_padded(o, sp, prefix, prefix_len, zeros, buf + sizeof(buf) - n, n, sp->zero && sp->precision < 0);
}

/* EXACT DECIMAL DIGITS OF A DOUBLE
   mant * 2^e2 as a big integer (base 10^9 limbs; mant * 5^-e2 for e2 < 0),
   so every digit and every tie is exact (ties to even, as glibc). */

#define BIG_LIMBS 90   /* mant * 5^1074 has 767 digits */
#define MAX_DIGITS 800

typedef struct {
    char d[MAX_DIGITS]; /* significant digits, no leading zeros */
    int n;              /* how many; 0 for the value 0 */
    int exp;            /* decimal exponent of d[0]: value = d.ddd * 10^exp */
} decimal;

static void big_mul(uint32_t *limb, int *count, uint32_t factor) {
    uint64_t carry = 0;
    for (int i = 0; i < *count; ++i) {
        uint64_t x = (uint64_t)limb[i] * factor + carry;
        limb[i] = (uint32_t)(x % 1000000000u);
        carry = x / 1000000000u;
    }
    while (carry != 0 && *count < BIG_LIMBS) {
        limb[(*count)++] = (uint32_t)(carry % 1000000000u);
        carry /= 1000000000u;
    }
}

static void exact_decimal(double v, decimal *out) {
    union {
        double f;
        uint64_t u;
    } bits = { .f = v };
    int biased = (int)((bits.u >> 52) & 0x7FF);
    uint64_t mant = bits.u & ((UINT64_C(1) << 52) - 1);
    int e2;
    if (biased == 0) {
        e2 = -1074;
    } else {
        mant |= UINT64_C(1) << 52;
        e2 = biased - 1075;
    }
    out->n = 0;
    out->exp = 0;
    if (mant == 0) {
        return;
    }
    uint32_t limb[BIG_LIMBS];
    int count = 0;
    while (mant != 0) {
        limb[count++] = (uint32_t)(mant % 1000000000u);
        mant /= 1000000000u;
    }
    int shift10 = 0; /* the big integer is value * 10^shift10 */
    if (e2 >= 0) {
        for (; e2 >= 29; e2 -= 29) {
            big_mul(limb, &count, UINT32_C(1) << 29);
        }
        big_mul(limb, &count, UINT32_C(1) << e2);
    } else {
        int k = -e2;
        shift10 = k;
        for (; k >= 12; k -= 12) {
            big_mul(limb, &count, 244140625u); /* 5^12 */
        }
        uint32_t f = 1;
        while (k-- > 0) {
            f *= 5;
        }
        big_mul(limb, &count, f);
    }
    /* Most significant limb without leading zeros, the others with 9 digits */
    char tmp[12];
    int t = 0;
    uint32_t top = limb[count - 1];
    do {
        tmp[t++] = (char)('0' + top % 10);
        top /= 10;
    } while (top != 0);
    while (t > 0) {
        out->d[out->n++] = tmp[--t];
    }
    for (int i = count - 2; i >= 0; --i) {
        uint32_t x = limb[i];
        for (int j = 8; j >= 0; --j) {
            out->d[out->n + j] = (char)('0' + x % 10);
            x /= 10;
        }
        out->n += 9;
    }
    out->exp = out->n - 1 - shift10;
    while (out->n > 1 && out->d[out->n - 1] == '0') {
        --out->n;
    }
}

/* Keeps keep significant digits, rounded (ties to even); keep <= 0 rounds
   to a 1 at the place before the first digit, or to nothing (value 0) */
static void round_digits(decimal *x, int keep) {
    if (x->n == 0 || keep >= x->n) {
        return;
    }
    if (keep < 0) {
        x->n = 0;
        return;
    }
    int next = x->d[keep] - '0';
    bool more = false;
    for (int i = keep + 1; i < x->n; ++i) {
        if (x->d[i] != '0') {
            more = true;
            break;
        }
    }
    bool prev_odd = keep > 0 && (x->d[keep - 1] - '0') % 2 == 1;
    bool up = next > 5 || (next == 5 && (more || prev_odd));
    x->n = keep;
    if (!up) {
        if (keep == 0) {
            x->n = 0;
        }
        return;
    }
    int i = keep - 1;
    while (i >= 0 && x->d[i] == '9') {
        --i;
    }
    if (i >= 0) {
        ++x->d[i];
        x->n = i + 1;
    } else {
        x->d[0] = '1';
        x->n = 1;
        ++x->exp;
    }
}

static char digit_at(const decimal *x, int k) {
    return k >= 0 && k < x->n ? x->d[k] : '0';
}

/* Builds the text of a number without sign or padding */
typedef struct {
    char text[MAX_DIGITS + 400];
    size_t len;
} num_text;

static void nt_char(num_text *t, char c) {
    if (t->len < sizeof(t->text)) {
        t->text[t->len++] = c;
    }
}

static void nt_exponent(num_text *t, char e_char, int exp) {
    nt_char(t, e_char);
    nt_char(t, exp < 0 ? '-' : '+');
    unsigned u = (unsigned)(exp < 0 ? -exp : exp);
    char d[8];
    int n = 0;
    do {
        d[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u != 0);
    if (n < 2) {
        d[n++] = '0';
    }
    while (n > 0) {
        nt_char(t, d[--n]);
    }
}

/* d.ddde+XX with prec digits after the point */
static void float_e(num_text *t, double v, int prec, bool hash, bool upper) {
    static decimal x;
    exact_decimal(v, &x);
    round_digits(&x, prec + 1);
    int exp = x.n == 0 ? 0 : x.exp;
    nt_char(t, digit_at(&x, 0));
    if (prec > 0 || hash) {
        nt_char(t, '.');
    }
    for (int i = 1; i <= prec; ++i) {
        nt_char(t, digit_at(&x, i));
    }
    nt_exponent(t, upper ? 'E' : 'e', exp);
}

/* ddd.ddd with prec digits after the point */
static void float_f(num_text *t, double v, int prec, bool hash) {
    static decimal x;
    exact_decimal(v, &x);
    if (x.n > 0) {
        round_digits(&x, x.exp + 1 + prec);
    }
    if (x.n == 0 || x.exp < 0) {
        nt_char(t, '0');
    } else {
        for (int k = 0; k <= x.exp; ++k) {
            nt_char(t, digit_at(&x, k));
        }
    }
    if (prec > 0 || hash) {
        nt_char(t, '.');
    }
    for (int i = 1; i <= prec; ++i) {
        nt_char(t, x.n == 0 ? '0' : digit_at(&x, x.exp + i));
    }
}

/* %e or %f by the exponent, prec digits, trailing zeros removed */
static void float_g(num_text *t, double v, int prec, bool hash, bool upper) {
    static decimal x;
    if (prec == 0) {
        prec = 1;
    }
    exact_decimal(v, &x);
    round_digits(&x, prec);
    int exp = x.n == 0 ? 0 : x.exp;
    size_t start = t->len;
    bool use_e = exp < -4 || exp >= prec;
    if (use_e) {
        float_e(t, v, prec - 1, hash, upper);
    } else {
        float_f(t, v, prec - 1 - exp, hash);
    }
    if (hash) {
        return;
    }
    /* Remove trailing zeros of the fraction (before the exponent, for %e) */
    size_t end = t->len;
    size_t exp_at = end;
    if (use_e) {
        for (size_t i = start; i < end; ++i) {
            if (t->text[i] == 'e' || t->text[i] == 'E') {
                exp_at = i;
                break;
            }
        }
    }
    size_t dot = exp_at;
    for (size_t i = start; i < exp_at; ++i) {
        if (t->text[i] == '.') {
            dot = i;
            break;
        }
    }
    if (dot == exp_at) {
        return;
    }
    size_t cut = exp_at;
    while (cut > dot + 1 && t->text[cut - 1] == '0') {
        --cut;
    }
    if (cut == dot + 1) {
        cut = dot;
    }
    memmove(t->text + cut, t->text + exp_at, end - exp_at);
    t->len = cut + (end - exp_at);
}

/* %a: 0x1.hhhp+d, exact */
static void float_a(num_text *t, double v, int prec, bool hash, bool upper) {
    const char *hex = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    union {
        double f;
        uint64_t u;
    } bits = { .f = v };
    int biased = (int)((bits.u >> 52) & 0x7FF);
    uint64_t mant = bits.u & ((UINT64_C(1) << 52) - 1);
    int lead = biased == 0 ? 0 : 1;
    int exp = biased == 0 ? (mant == 0 ? 0 : -1022) : biased - 1023;
    if (prec >= 0 && prec < 13) {
        int shift = (13 - prec) * 4;
        uint64_t rest = mant & ((UINT64_C(1) << shift) - 1);
        uint64_t half = UINT64_C(1) << (shift - 1);
        if (rest > half || (rest == half && ((mant >> shift) & 1))) { /* ties to even */
            mant += UINT64_C(1) << shift;
        }
        if (mant >> 52) {
            mant &= (UINT64_C(1) << 52) - 1;
            ++lead;
        }
        mant >>= shift;
        mant <<= shift;
    }
    int ndig = 13;
    if (prec < 0) {
        while (ndig > 0 && ((mant >> ((13 - ndig) * 4)) & 0xF) == 0) {
            --ndig;
        }
    } else {
        ndig = prec;
    }
    nt_char(t, '0');
    nt_char(t, upper ? 'X' : 'x');
    nt_char(t, (char)('0' + lead));
    if (ndig > 0 || hash) {
        nt_char(t, '.');
    }
    for (int i = 0; i < ndig; ++i) {
        nt_char(t, i < 13 ? hex[(mant >> ((12 - i) * 4)) & 0xF] : '0');
    }
    nt_char(t, upper ? 'P' : 'p');
    nt_char(t, exp < 0 ? '-' : '+');
    unsigned u = (unsigned)(exp < 0 ? -exp : exp);
    char d[8];
    int n = 0;
    do {
        d[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u != 0);
    while (n > 0) {
        nt_char(t, d[--n]);
    }
}

static void fmt_float(fmt_out *o, const fmt_spec *sp, double v, char conv) {
    bool upper = conv == 'F' || conv == 'E' || conv == 'G' || conv == 'A';
    char prefix[2];
    size_t prefix_len = 0;
    if (signbit(v)) {
        prefix[prefix_len++] = '-';
        v = -v;
    } else if (sp->plus) {
        prefix[prefix_len++] = '+';
    } else if (sp->space) {
        prefix[prefix_len++] = ' ';
    }
    if (isnan(v) || isinf(v)) {
        const char *s = isnan(v) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
        out_padded(o, sp, prefix, prefix_len, 0, s, 3, false);
        return;
    }
    static num_text t; /* large; ZDOS programs run one at a time, without threads */
    t.len = 0;
    int prec = sp->precision < 0 ? 6 : sp->precision;
    if (prec > 380) {
        prec = 380;
    }
    switch (conv) {
        case 'e': case 'E': float_e(&t, v, prec, sp->hash, upper); break;
        case 'g': case 'G': float_g(&t, v, prec, sp->hash, upper); break;
        case 'a': case 'A': float_a(&t, v, sp->precision < 0 ? -1 : prec, sp->hash, upper); break;
        default: float_f(&t, v, prec, sp->hash); break;
    }
    out_padded(o, sp, prefix, prefix_len, 0, t.text, t.len, sp->zero);
}

enum { LEN_NONE, LEN_HH, LEN_H, LEN_L, LEN_LL, LEN_J, LEN_Z, LEN_T, LEN_BIG_L };

/* c as UTF-8 into out (up to 4 bytes); the count. Not a character: U+FFFD */
static size_t utf8_put(uint32_t c, char *out) {
    if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) {
        c = 0xFFFD;
    }
    if (c < 0x80) {
        out[0] = (char)c;
        return 1;
    }
    if (c < 0x800) {
        out[0] = (char)(0xC0 | (c >> 6));
        out[1] = (char)(0x80 | (c & 0x3F));
        return 2;
    }
    if (c < 0x10000) {
        out[0] = (char)(0xE0 | (c >> 12));
        out[1] = (char)(0x80 | ((c >> 6) & 0x3F));
        out[2] = (char)(0x80 | (c & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (c >> 18));
    out[1] = (char)(0x80 | ((c >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((c >> 6) & 0x3F));
    out[3] = (char)(0x80 | (c & 0x3F));
    return 4;
}

static void format(fmt_out *o, const char *f, va_list *ap) {
    while (*f != '\0') {
        if (*f != '%') {
            out_char(o, *f++);
            continue;
        }
        const char *start = f++;
        fmt_spec sp = { false, false, false, false, false, 0, -1 };
        for (;; ++f) {
            if (*f == '-') sp.minus = true;
            else if (*f == '+') sp.plus = true;
            else if (*f == ' ') sp.space = true;
            else if (*f == '0') sp.zero = true;
            else if (*f == '#') sp.hash = true;
            else break;
        }
        if (*f == '*') {
            sp.width = va_arg(*ap, int);
            if (sp.width < 0) {
                sp.minus = true;
                sp.width = -sp.width;
            }
            ++f;
        } else {
            while (isdigit((unsigned char)*f)) {
                sp.width = sp.width * 10 + (*f++ - '0');
            }
        }
        if (*f == '.') {
            ++f;
            sp.precision = 0;
            if (*f == '*') {
                sp.precision = va_arg(*ap, int);
                if (sp.precision < 0) {
                    sp.precision = -1;
                }
                ++f;
            } else {
                while (isdigit((unsigned char)*f)) {
                    sp.precision = sp.precision * 10 + (*f++ - '0');
                }
            }
        }
        int len = LEN_NONE;
        switch (*f) {
            case 'h': ++f; if (*f == 'h') { ++f; len = LEN_HH; } else len = LEN_H; break;
            case 'l': ++f; if (*f == 'l') { ++f; len = LEN_LL; } else len = LEN_L; break;
            case 'j': ++f; len = LEN_J; break;
            case 'z': ++f; len = LEN_Z; break;
            case 't': ++f; len = LEN_T; break;
            case 'L': ++f; len = LEN_BIG_L; break;
            default: break;
        }
        char conv = *f;
        if (conv == '\0') {
            out_chars(o, start, (size_t)(f - start));
            break;
        }
        ++f;
        switch (conv) {
            case 'd': case 'i': {
                intmax_t v;
                switch (len) {
                    case LEN_HH: v = (signed char)va_arg(*ap, int); break;
                    case LEN_H: v = (short)va_arg(*ap, int); break;
                    case LEN_L: v = va_arg(*ap, long); break;
                    case LEN_LL: v = va_arg(*ap, long long); break;
                    case LEN_J: v = va_arg(*ap, intmax_t); break;
                    case LEN_Z: v = (intmax_t)(ptrdiff_t)va_arg(*ap, size_t); break;
                    case LEN_T: v = va_arg(*ap, ptrdiff_t); break;
                    default: v = va_arg(*ap, int); break;
                }
                uintmax_t mag = v < 0 ? (uintmax_t)0 - (uintmax_t)v : (uintmax_t)v;
                fmt_integer(o, &sp, mag, v < 0, 10, false);
                break;
            }
            case 'u': case 'o': case 'x': case 'X': {
                uintmax_t v;
                switch (len) {
                    case LEN_HH: v = (unsigned char)va_arg(*ap, unsigned); break;
                    case LEN_H: v = (unsigned short)va_arg(*ap, unsigned); break;
                    case LEN_L: v = va_arg(*ap, unsigned long); break;
                    case LEN_LL: v = va_arg(*ap, unsigned long long); break;
                    case LEN_J: v = va_arg(*ap, uintmax_t); break;
                    case LEN_Z: v = va_arg(*ap, size_t); break;
                    case LEN_T: v = (uintmax_t)va_arg(*ap, ptrdiff_t); break;
                    default: v = va_arg(*ap, unsigned); break;
                }
                sp.plus = sp.space = false;
                fmt_integer(o, &sp, v, false, conv == 'u' ? 10 : conv == 'o' ? 8 : 16, conv == 'X');
                break;
            }
            case 'p': {
                void *p = va_arg(*ap, void *);
                sp.hash = true;
                sp.plus = sp.space = false;
                if (p == NULL) {
                    out_padded(o, &sp, "", 0, 0, "0x0", 3, false);
                } else {
                    fmt_integer(o, &sp, (uintptr_t)p, false, 16, false);
                }
                break;
            }
            case 'c': {
                if (len == LEN_L) { /* %lc: a wide character, as UTF-8 */
                    char u[4];
                    size_t n = utf8_put((uint32_t)va_arg(*ap, wint_t), u);
                    out_padded(o, &sp, "", 0, 0, u, n, false);
                    break;
                }
                char c = (char)va_arg(*ap, int);
                out_padded(o, &sp, "", 0, 0, &c, 1, false);
                break;
            }
            case 's': {
                if (len == LEN_L) { /* %ls: a wide string, as UTF-8; precision in bytes */
                    const wchar_t *w = va_arg(*ap, const wchar_t *);
                    if (w == NULL) {
                        w = L"(null)";
                    }
                    char buf[512];
                    size_t n = 0;
                    for (; *w != 0; ++w) {
                        char u[4];
                        size_t k = utf8_put((uint32_t)*w, u);
                        if (n + k > sizeof(buf) || (sp.precision >= 0 && n + k > (size_t)sp.precision)) {
                            break;
                        }
                        memcpy(buf + n, u, k);
                        n += k;
                    }
                    out_padded(o, &sp, "", 0, 0, buf, n, false);
                    break;
                }
                const char *s = va_arg(*ap, const char *);
                if (s == NULL) {
                    s = "(null)";
                }
                size_t n = sp.precision >= 0 ? strnlen(s, (size_t)sp.precision) : strlen(s);
                out_padded(o, &sp, "", 0, 0, s, n, false);
                break;
            }
            case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A': {
                double v = len == LEN_BIG_L ? (double)va_arg(*ap, long double) : va_arg(*ap, double);
                fmt_float(o, &sp, v, conv);
                break;
            }
            case 'n': {
                void *p = va_arg(*ap, void *);
                switch (len) {
                    case LEN_HH: *(signed char *)p = (signed char)o->count; break;
                    case LEN_H: *(short *)p = (short)o->count; break;
                    case LEN_L: *(long *)p = (long)o->count; break;
                    case LEN_LL: *(long long *)p = (long long)o->count; break;
                    case LEN_J: *(intmax_t *)p = (intmax_t)o->count; break;
                    case LEN_Z: *(size_t *)p = o->count; break;
                    case LEN_T: *(ptrdiff_t *)p = (ptrdiff_t)o->count; break;
                    default: *(int *)p = (int)o->count; break;
                }
                break;
            }
            case '%':
                out_char(o, '%');
                break;
            default: /* unknown: shown as written */
                out_chars(o, start, (size_t)(f - start));
                break;
        }
    }
}

int vsnprintf(char *str, size_t size, const char *format_str, va_list ap) {
    fmt_out o;
    memset(&o, 0, sizeof(o));
    o.buf = str;
    o.size = size;
    va_list args;
    va_copy(args, ap);
    format(&o, format_str, &args);
    va_end(args);
    if (size > 0) {
        str[o.pos] = '\0';
    }
    return (int)o.count;
}

int snprintf(char *str, size_t size, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vsnprintf(str, size, format_str, ap);
    va_end(ap);
    return result;
}

/* The text in new memory from malloc (*out, free it); its length, or -1 */
int vasprintf(char **out, const char *format_str, va_list ap) {
    va_list count_ap;
    va_copy(count_ap, ap);
    int n = vsnprintf(NULL, 0, format_str, count_ap);
    va_end(count_ap);
    *out = NULL;
    if (n < 0) {
        return -1;
    }
    char *s = malloc((size_t)n + 1);
    if (s == NULL) {
        errno = ENOMEM;
        return -1;
    }
    vsnprintf(s, (size_t)n + 1, format_str, ap);
    *out = s;
    return n;
}

int asprintf(char **out, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vasprintf(out, format_str, ap);
    va_end(ap);
    return result;
}

int vsprintf(char *str, const char *format_str, va_list ap) {
    return vsnprintf(str, SIZE_MAX, format_str, ap);
}

int sprintf(char *str, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vsnprintf(str, SIZE_MAX, format_str, ap);
    va_end(ap);
    return result;
}

int vfprintf(FILE *stream, const char *format_str, va_list ap) {
    fmt_out o;
    memset(&o, 0, sizeof(o));
    o.stream = stream;
    va_list args;
    va_copy(args, ap);
    flockfile(stream);
    format(&o, format_str, &args);
    va_end(args);
    out_flush(&o);
    funlockfile(stream);
    return ferror(stream) ? -1 : (int)o.count;
}

int fprintf(FILE *stream, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vfprintf(stream, format_str, ap);
    va_end(ap);
    return result;
}

int vprintf(const char *format_str, va_list ap) {
    return vfprintf(stdout, format_str, ap);
}

int printf(const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vfprintf(stdout, format_str, ap);
    va_end(ap);
    return result;
}

int putchar(int c) {
    return fputc(c, stdout);
}

int puts(const char *s) {
    flockfile(stdout);
    int result = fputs_unlocked(s, stdout) == EOF || fputc_unlocked('\n', stdout) == EOF ? EOF : 0;
    funlockfile(stdout);
    return result;
}

int getchar(void) {
    return fgetc(stdin);
}

void perror(const char *s) {
    if (s != NULL && s[0] != '\0') {
        fprintf(stderr, "%s: %s\n", s, strerror(zdos_errno));
    } else {
        fprintf(stderr, "%s\n", strerror(zdos_errno));
    }
}

/* FORMATTED INPUT Numbers are collected as text, then converted by strtoll /
   strtoull / strtod. A stream gives back only one character, so a number cut
   short ("0x", "1e+") keeps what was read, as with glibc. */

typedef struct {
    const char *str;
    FILE *stream;
    int count; /* characters read, for %n */
} scan_in;

static int in_get(scan_in *in) {
    int c;
    if (in->stream != NULL) {
        c = fgetc(in->stream);
    } else {
        c = *in->str != '\0' ? (unsigned char)*in->str++ : EOF;
    }
    if (c != EOF) {
        ++in->count;
    }
    return c;
}

static void in_unget(scan_in *in, int c) {
    if (c == EOF) {
        return;
    }
    --in->count;
    if (in->stream != NULL) {
        ungetc(c, in->stream);
    } else {
        --in->str;
    }
}

// Skips white space; false at the end of the input
static bool in_skip_space(scan_in *in) {
    int c;
    do {
        c = in_get(in);
    } while (c != EOF && isspace(c));
    in_unget(in, c);
    return c != EOF;
}

// Collects a number's text, at most width characters (0: any)
typedef struct {
    char buf[512];
    int len;
    int left;
} scan_text;

static bool st_add(scan_text *t, int c) {
    if (t->left == 0 || t->len + 1 >= (int)sizeof(t->buf)) {
        return false;
    }
    t->buf[t->len++] = (char)c;
    t->buf[t->len] = '\0';
    --t->left;
    return true;
}

// The text of an integer in base (0: as C, 0x... hex, 0... octal); the
// base to convert it with, or 0 if no digits came
static int scan_integer(scan_in *in, scan_text *t, int base) {
    int c = in_get(in);
    if ((c == '+' || c == '-') && st_add(t, c)) {
        c = in_get(in);
    }
    bool digits = false;
    if ((base == 0 || base == 16) && c == '0' && st_add(t, c)) {
        digits = true;
        c = in_get(in);
        if ((c == 'x' || c == 'X') && st_add(t, c)) {
            base = 16;
            c = in_get(in);
        } else if (base == 0) {
            base = 8;
        }
    } else if (base == 0) {
        base = 10;
    }
    while (c != EOF && digit_value((char)c) >= 0 && digit_value((char)c) < base && st_add(t, c)) {
        digits = true;
        c = in_get(in);
    }
    in_unget(in, c);
    return digits ? base : 0;
}

// Adds c if it is one of the two letters; the next character then
static bool scan_letter(scan_in *in, scan_text *t, int *c, char lower) {
    if ((*c | 0x20) == lower && st_add(t, *c)) {
        *c = in_get(in);
        return true;
    }
    return false;
}

// The text of a floating point number (strtod's forms); false if none came
static bool scan_float(scan_in *in, scan_text *t) {
    int c = in_get(in);
    if ((c == '+' || c == '-') && st_add(t, c)) {
        c = in_get(in);
    }
    if ((c | 0x20) == 'i' || (c | 0x20) == 'n') {
        const char *word = (c | 0x20) == 'i' ? "infinity" : "nan";
        int n = 0;
        while (word[n] != '\0' && scan_letter(in, t, &c, word[n])) {
            ++n;
        }
        if (word[0] == 'n' && n == 3 && c == '(' && st_add(t, c)) {
            c = in_get(in);
            while ((c != EOF && (isalnum(c) || c == '_')) && st_add(t, c)) {
                c = in_get(in);
            }
            if (c == ')' && st_add(t, c)) {
                c = in_get(in);
            }
        }
        in_unget(in, c);
        return n >= 3;
    }
    bool hex = false;
    bool digits = false;
    if (c == '0' && st_add(t, c)) {
        digits = true;
        c = in_get(in);
        if ((c == 'x' || c == 'X') && st_add(t, c)) {
            hex = true;
            digits = false;
            c = in_get(in);
        }
    }
    int base = hex ? 16 : 10;
    while (c != EOF && digit_value((char)c) >= 0 && digit_value((char)c) < base && st_add(t, c)) {
        digits = true;
        c = in_get(in);
    }
    if (c == '.' && st_add(t, c)) {
        c = in_get(in);
        while (c != EOF && digit_value((char)c) >= 0 && digit_value((char)c) < base && st_add(t, c)) {
            digits = true;
            c = in_get(in);
        }
    }
    if (digits && (c | 0x20) == (hex ? 'p' : 'e') && st_add(t, c)) {
        c = in_get(in);
        if ((c == '+' || c == '-') && st_add(t, c)) {
            c = in_get(in);
        }
        while (c != EOF && isdigit(c) && st_add(t, c)) {
            c = in_get(in);
        }
    }
    in_unget(in, c);
    return digits;
}

static void store_signed(void *p, int len, long long v) {
    switch (len) {
        case LEN_HH: *(signed char *)p = (signed char)v; break;
        case LEN_H: *(short *)p = (short)v; break;
        case LEN_L: *(long *)p = (long)v; break;
        case LEN_LL: case LEN_BIG_L: *(long long *)p = v; break;
        case LEN_J: *(intmax_t *)p = v; break;
        case LEN_Z: *(ssize_t *)p = (ssize_t)v; break;
        case LEN_T: *(ptrdiff_t *)p = (ptrdiff_t)v; break;
        default: *(int *)p = (int)v; break;
    }
}

static void store_unsigned(void *p, int len, unsigned long long v) {
    switch (len) {
        case LEN_HH: *(unsigned char *)p = (unsigned char)v; break;
        case LEN_H: *(unsigned short *)p = (unsigned short)v; break;
        case LEN_L: *(unsigned long *)p = (unsigned long)v; break;
        case LEN_LL: case LEN_BIG_L: *(unsigned long long *)p = v; break;
        case LEN_J: *(uintmax_t *)p = v; break;
        case LEN_Z: *(size_t *)p = (size_t)v; break;
        case LEN_T: *(ptrdiff_t *)p = (ptrdiff_t)v; break;
        default: *(unsigned int *)p = (unsigned int)v; break;
    }
}

// A %[...] set: which characters match; f points after '['
static const char *scan_set(const char *f, bool set[256]) {
    bool invert = false;
    if (*f == '^') {
        invert = true;
        ++f;
    }
    memset(set, 0, 256 * sizeof(bool));
    if (*f == ']') { /* first: a member, not the end */
        set[']'] = true;
        ++f;
    }
    while (*f != '\0' && *f != ']') {
        unsigned char lo = (unsigned char)*f;
        if (f[1] == '-' && f[2] != ']' && f[2] != '\0') {
            unsigned char hi = (unsigned char)f[2];
            for (unsigned c = lo; c <= hi; ++c) {
                set[c] = true;
            }
            f += 3;
        } else {
            set[lo] = true;
            ++f;
        }
    }
    if (*f == ']') {
        ++f;
    }
    if (invert) {
        for (int c = 0; c < 256; ++c) {
            set[c] = !set[c];
        }
    }
    return f;
}

// The number of assignments made; EOF if the input ended before the first
// conversion
static int scan(scan_in *in, const char *f, va_list *ap) {
    int assigned = 0;
    int converted = 0;
    while (*f != '\0') {
        if (isspace((unsigned char)*f)) {
            while (isspace((unsigned char)*f)) {
                ++f;
            }
            in_skip_space(in);
            continue;
        }
        if (*f != '%' || f[1] == '%') {
            if (*f == '%') {
                ++f;
                in_skip_space(in);
            }
            int c = in_get(in);
            if (c != (unsigned char)*f) {
                in_unget(in, c);
                return c == EOF && converted == 0 ? EOF : assigned;
            }
            ++f;
            continue;
        }
        ++f;
        bool suppress = *f == '*';
        if (suppress) {
            ++f;
        }
        int width = 0;
        while (isdigit((unsigned char)*f)) {
            width = width * 10 + (*f++ - '0');
        }
        int len = LEN_NONE;
        if (f[0] == 'h' && f[1] == 'h') { len = LEN_HH; f += 2; }
        else if (f[0] == 'l' && f[1] == 'l') { len = LEN_LL; f += 2; }
        else if (*f == 'h') { len = LEN_H; ++f; }
        else if (*f == 'l') { len = LEN_L; ++f; }
        else if (*f == 'j') { len = LEN_J; ++f; }
        else if (*f == 'z') { len = LEN_Z; ++f; }
        else if (*f == 't') { len = LEN_T; ++f; }
        else if (*f == 'L') { len = LEN_BIG_L; ++f; }
        char conv = *f++;
        if (conv == '\0') {
            break;
        }
        if (conv == 'n') {
            if (!suppress) {
                store_signed(va_arg(*ap, void *), len, in->count);
            }
            continue;
        }
        if (conv != 'c' && conv != '[' && !in_skip_space(in)) {
            return converted == 0 ? EOF : assigned; /* the input ended */
        }
        if (conv == 'c' || conv == 's' || conv == '[') {
            bool set[256];
            if (conv == '[') {
                f = scan_set(f, set);
            }
            char *out = suppress ? NULL : va_arg(*ap, char *);
            int limit = width > 0 ? width : conv == 'c' ? 1 : INT_MAX;
            int n = 0;
            int c = EOF;
            while (n < limit) {
                c = in_get(in);
                if (c == EOF || (conv == 's' && isspace(c)) || (conv == '[' && !set[c])) {
                    break;
                }
                if (out != NULL) {
                    out[n] = (char)c;
                }
                ++n;
                c = EOF;
            }
            in_unget(in, c);
            if (n == 0 || (conv == 'c' && n < limit)) {
                return c == EOF && converted == 0 ? EOF : assigned;
            }
            if (out != NULL && conv != 'c') {
                out[n] = '\0';
            }
        } else if (conv == 'd' || conv == 'i' || conv == 'u' || conv == 'o' || conv == 'x' || conv == 'X' ||
            conv == 'p') {
            scan_text t = { { 0 }, 0, width > 0 ? width : -1 };
            int base = conv == 'd' || conv == 'u' ? 10 : conv == 'i' ? 0 : conv == 'o' ? 8 : 16;
            base = scan_integer(in, &t, base);
            if (base == 0) {
                return assigned;
            }
            if (!suppress) {
                void *p = va_arg(*ap, void *);
                if (conv == 'p') {
                    *(void **)p = (void *)(uintptr_t)strtoull(t.buf, NULL, base);
                } else if (conv == 'd' || conv == 'i') {
                    store_signed(p, len, strtoll(t.buf, NULL, base));
                } else {
                    store_unsigned(p, len, strtoull(t.buf, NULL, base));
                }
            }
        } else if (conv == 'f' || conv == 'F' || conv == 'e' || conv == 'E' || conv == 'g' || conv == 'G' ||
            conv == 'a' || conv == 'A') {
            scan_text t = { { 0 }, 0, width > 0 ? width : -1 };
            char *end;
            if (!scan_float(in, &t)) {
                return assigned;
            }
            double v = strtod(t.buf, &end);
            if (end == t.buf) {
                return assigned;
            }
            if (!suppress) {
                void *p = va_arg(*ap, void *);
                if (len == LEN_L) {
                    *(double *)p = v;
                } else if (len == LEN_BIG_L) {
                    *(long double *)p = v;
                } else {
                    *(float *)p = (float)v;
                }
            }
        } else {
            return assigned; /* not a conversion */
        }
        ++converted;
        if (!suppress) {
            ++assigned;
        }
    }
    return assigned;
}

int vsscanf(const char *str, const char *format_str, va_list ap) {
    scan_in in = { str, NULL, 0 };
    va_list args;
    va_copy(args, ap);
    int result = scan(&in, format_str, &args);
    va_end(args);
    return result;
}

int sscanf(const char *str, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vsscanf(str, format_str, ap);
    va_end(ap);
    return result;
}

int vfscanf(FILE *stream, const char *format_str, va_list ap) {
    scan_in in = { NULL, stream, 0 };
    va_list args;
    va_copy(args, ap);
    flockfile(stream);
    int result = scan(&in, format_str, &args);
    funlockfile(stream);
    va_end(args);
    return result;
}

int fscanf(FILE *stream, const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vfscanf(stream, format_str, ap);
    va_end(ap);
    return result;
}

int vscanf(const char *format_str, va_list ap) {
    return vfscanf(stdin, format_str, ap);
}

int scanf(const char *format_str, ...) {
    va_list ap;
    va_start(ap, format_str);
    int result = vfscanf(stdin, format_str, ap);
    va_end(ap);
    return result;
}

/* MATH HELPERS */

/* copysign, nan and the rest of math.h: src/libm (NetBSD), src/libml (long
   double), the compiler's runtime and zdos_mathl.c */

/* COMMAND-LINE OPTIONS (getopt.h)
   getopt as POSIX; getopt_long as GNU (non-options moved behind the options,
   '+' and '-' at the start of optstring). optind = 0 starts over. */
char *optarg;
int optind = 1;
int opterr = 1;
int optopt;
static int optpos; /* the next letter in a group like -abc; 0: none */

static void opt_error(const char *const argv[], const char *text, const char *what, int c) {
    if (what != NULL) {
        fprintf(stderr, "%s: %s '%s'\n", argv[0], text, what);
    } else {
        fprintf(stderr, "%s: %s -- '%c'\n", argv[0], text, c);
    }
}

static const char *opt_flags(const char *optstring, bool *colon) {
    if (*optstring == '+' || *optstring == '-') {
        ++optstring;
    }
    *colon = *optstring == ':';
    return *colon ? optstring + 1 : optstring;
}

int getopt(int argc, char *const argv[], const char *optstring) {
    if (optind == 0) {
        optind = 1;
        optpos = 0;
    }
    optarg = NULL;
    if (optind >= argc || argv[optind] == NULL) {
        return -1;
    }
    const char *arg = argv[optind];
    if (optpos == 0) {
        if (arg[0] != '-' || arg[1] == '\0') {
            if (optstring[0] == '-') {
                optarg = (char *)arg;
                ++optind;
                return 1;
            }
            return -1;
        }
        if (arg[1] == '-' && arg[2] == '\0') {
            ++optind;
            return -1;
        }
        optpos = 1;
    }
    bool colon;
    const char *opts = opt_flags(optstring, &colon);
    int c = (unsigned char)arg[optpos++];
    const char *spec = c != ':' ? strchr(opts, c) : NULL;
    bool group_done = arg[optpos] == '\0';
    if (spec == NULL) {
        optopt = c;
        if (group_done) {
            ++optind;
            optpos = 0;
        }
        if (opterr && !colon) {
            opt_error((const char *const *)argv, "invalid option", NULL, c);
        }
        return '?';
    }
    if (spec[1] != ':') {
        if (group_done) {
            ++optind;
            optpos = 0;
        }
        return c;
    }
    /* It takes an argument: the rest of this one ("-ofile"),
       else the next ("-o file"); an optional one ("o::") only
       as the rest of this one */
    const char *rest = arg + optpos;
    ++optind;
    optpos = 0;
    if (!group_done) {
        optarg = (char *)rest;
    } else if (spec[2] != ':') {
        if (optind >= argc) {
            optopt = c;
            if (opterr && !colon) {
                opt_error((const char *const *)argv, "option requires an argument", NULL, c);
            }
            return colon ? ':' : '?';
        }
        optarg = argv[optind++];
    }
    return c;
}

/* argv[src] moved to argv[dest] (dest < src), the ones between moved up */
static void opt_permute(char *const *argv, int dest, int src) {
    char **av = (char **)argv;
    char *moved = av[src];
    for (int i = src; i > dest; --i) {
        av[i] = av[i - 1];
    }
    av[dest] = moved;
}

static int opt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts,
                    int *longindex, bool longonly) {
    if (optind >= argc || argv[optind] == NULL) {
        return -1;
    }
    const char *arg = argv[optind];
    bool is_long = optpos == 0 && arg[0] == '-' && arg[1] != '\0' &&
                   ((arg[1] == '-' && arg[2] != '\0') || (longonly && arg[1] != '-'));
    if (!is_long) {
        return getopt(argc, argv, optstring);
    }
    bool colon;
    opt_flags(optstring, &colon);
    const char *name = arg + (arg[1] == '-' ? 2 : 1);
    size_t name_len = strcspn(name, "=");
    int match = -1;
    bool ambiguous = false;
    for (int i = 0; longopts[i].name != NULL; i++) {
        if (strncmp(longopts[i].name, name, name_len) != 0) {
            continue;
        }
        if (longopts[i].name[name_len] == '\0') { /* the whole name */
            match = i;
            ambiguous = false;
            break;
        }
        if (match < 0) {
            match = i;
        } else if (longopts[i].has_arg != longopts[match].has_arg || longopts[i].flag != longopts[match].flag ||
                   longopts[i].val != longopts[match].val) {
            ambiguous = true;
        }
    }
    if (match < 0 && longonly && arg[1] != '-' && strchr(opt_flags(optstring, &colon), arg[1]) != NULL) {
        return getopt(argc, argv, optstring); /* -abc as short options */
    }
    ++optind;
    optarg = NULL;
    if (match < 0 || ambiguous) {
        optopt = 0;
        if (opterr && !colon) {
            opt_error((const char *const *)argv, ambiguous ? "ambiguous option" : "unrecognized option", arg, 0);
        }
        return '?';
    }
    const struct option *o = &longopts[match];
    if (name[name_len] == '=') {
        if (o->has_arg == no_argument) {
            optopt = o->val;
            if (opterr && !colon) {
                opt_error((const char *const *)argv, "option doesn't allow an argument", arg, 0);
            }
            return '?';
        }
        optarg = (char *)name + name_len + 1;
    } else if (o->has_arg == required_argument) {
        if (optind >= argc) {
            optopt = o->val;
            if (opterr && !colon) {
                opt_error((const char *const *)argv, "option requires an argument", arg, 0);
            }
            return colon ? ':' : '?';
        }
        optarg = argv[optind++];
    }
    if (longindex != NULL) {
        *longindex = match;
    }
    if (o->flag != NULL) {
        *o->flag = o->val;
        return 0;
    }
    return o->val;
}

/* GNU's order: the options first. The arguments that aren't options are
   skipped, the option found is handled, and then it (and its argument) is
   moved before the skipped ones, so they gather at the end. */
static int opt_long_permute(int argc, char *const argv[], const char *optstring, const struct option *longopts,
                            int *longindex, bool longonly) {
    if (optind == 0) {
        optind = 1;
        optpos = 0;
    }
    if (optind >= argc || argv[optind] == NULL) {
        return -1;
    }
    int skipped = optind;
    if (optstring[0] != '+' && optstring[0] != '-') {
        int i = optind;
        while (i < argc && argv[i] != NULL && (argv[i][0] != '-' || argv[i][1] == '\0')) {
            ++i;
        }
        if (i >= argc || argv[i] == NULL) {
            return -1;
        }
        optind = i;
    }
    int resumed = optind;
    int result = opt_long(argc, argv, optstring, longopts, longindex, longonly);
    if (resumed > skipped) {
        int used = optind - resumed;
        for (int i = 0; i < used; i++) {
            opt_permute(argv, skipped, optind - 1);
        }
        optind = skipped + used;
    }
    return result;
}

int getopt_long(int argc, char *const argv[], const char *optstring, const struct option *longopts, int *longindex) {
    return opt_long_permute(argc, argv, optstring, longopts, longindex, false);
}

/* As getopt_long, and -name works too (when it isn't a short option) */
int getopt_long_only(int argc, char *const argv[], const char *optstring, const struct option *longopts,
                     int *longindex) {
    return opt_long_permute(argc, argv, optstring, longopts, longindex, true);
}

/* NAME PATTERNS (fnmatch.h)
   * ? and [...] (ranges, ! or ^ to negate); \ escapes unless FNM_NOESCAPE.
   FNM_PATHNAME: / is matched only by a /. FNM_PERIOD: a leading . (of the
   name, or after a / with FNM_PATHNAME) only by a written one.
   FNM_CASEFOLD: letters in either case (ZDOS's file names are like that). */
static bool fnm_same(int a, int b, int flags) {
    return a == b || ((flags & FNM_CASEFOLD) && tolower(a) == tolower(b));
}

/* p at a '['. 1: c is in the set, 0: not, -1: no closing ']' (a plain '[') */
static int fnm_set(const char **pp, int c, int flags) {
    const char *p = *pp + 1;
    bool negate = *p == '!' || *p == '^';
    if (negate) {
        ++p;
    }
    bool found = false;
    bool first = true;
    while (*p != ']' || first) {
        if (*p == '\0') {
            return -1;
        }
        first = false;
        int lo = (unsigned char)*p;
        if (lo == '\\' && !(flags & FNM_NOESCAPE) && p[1] != '\0') {
            lo = (unsigned char)*++p;
        }
        ++p;
        int hi = lo;
        if (*p == '-' && p[1] != ']' && p[1] != '\0') {
            ++p;
            hi = (unsigned char)*p;
            if (hi == '\\' && !(flags & FNM_NOESCAPE) && p[1] != '\0') {
                hi = (unsigned char)*++p;
            }
            ++p;
        }
        if ((c >= lo && c <= hi) ||
            ((flags & FNM_CASEFOLD) && ((tolower(c) >= lo && tolower(c) <= hi) || (toupper(c) >= lo && toupper(c) <= hi)))) {
            found = true;
        }
    }
    *pp = p + 1;
    return found != negate;
}

static bool fnm(const char *p, const char *s, const char *start, int flags) {
    for (;;) {
        bool leading = (flags & FNM_PERIOD) && *s == '.' &&
                       (s == start || ((flags & FNM_PATHNAME) && s[-1] == '/'));
        bool slash = (flags & FNM_PATHNAME) && *s == '/';
        switch (*p) {
            case '\0':
                return *s == '\0';
            case '?':
                if (*s == '\0' || slash || leading) {
                    return false;
                }
                ++p;
                ++s;
                break;
            case '*': {
                while (*p == '*') {
                    ++p;
                }
                if (leading) {
                    return fnm(p, s, start, flags); /* only as nothing */
                }
                if (*p == '\0') {
                    return !(flags & FNM_PATHNAME) || strchr(s, '/') == NULL;
                }
                for (const char *t = s;; ++t) {
                    if (fnm(p, t, start, flags)) {
                        return true;
                    }
                    if (*t == '\0' || ((flags & FNM_PATHNAME) && *t == '/')) {
                        return false;
                    }
                }
            }
            case '[': {
                if (*s == '\0' || slash || leading) {
                    return false;
                }
                const char *q = p;
                int in = fnm_set(&q, (unsigned char)*s, flags);
                if (in < 0) { /* no ']': a plain '[' */
                    if (*s != '[') {
                        return false;
                    }
                    ++p;
                } else if (in == 0) {
                    return false;
                } else {
                    p = q;
                }
                ++s;
                break;
            }
            default: {
                int pc = (unsigned char)*p;
                if (pc == '\\' && !(flags & FNM_NOESCAPE) && p[1] != '\0') {
                    pc = (unsigned char)*++p;
                }
                if (*s == '\0' || !fnm_same(pc, (unsigned char)*s, flags)) {
                    return false;
                }
                ++p;
                ++s;
                break;
            }
        }
    }
}

int fnmatch(const char *pattern, const char *string, int flags) {
    return fnm(pattern, string, string, flags) ? 0 : FNM_NOMATCH;
}

/* THE SYSTEM AND ITS USER (sys/utsname.h, pwd.h)
   ZDOS has one user and no host name: the variables USER, HOME and
   HOSTNAME give them if set. */
static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return v != NULL && v[0] != '\0' ? v : fallback;
}

static void copy_field(char *dest, const char *src, size_t size) {
    size_t n = strlen(src);
    if (n >= size) {
        n = size - 1;
    }
    memcpy(dest, src, n);
    dest[n] = '\0';
}

int uname(struct utsname *u) {
    memset(u, 0, sizeof(*u));
    copy_field(u->sysname, "ZDOS", sizeof(u->sysname));
    copy_field(u->nodename, env_or("HOSTNAME", "zdos"), sizeof(u->nodename));
    copy_field(u->release, "1", sizeof(u->release)); /* the program interface's version */
    copy_field(u->version, "1", sizeof(u->version));
#if defined(__x86_64__)
    copy_field(u->machine, "x86_64", sizeof(u->machine));
#elif defined(__aarch64__)
    copy_field(u->machine, "aarch64", sizeof(u->machine));
#else
    copy_field(u->machine, "i686", sizeof(u->machine));
#endif
    return 0;
}

int gethostname(char *name, size_t len) {
    const char *host = env_or("HOSTNAME", "zdos");
    if (strlen(host) >= len) {
        errno = ENAMETOOLONG;
        return -1;
    }
    strcpy(name, host);
    return 0;
}

/* Users: \CONF\USERS.CFG on the boot drive (the drive of COMSPEC), lines
   "name:uid:password:shell" (apps/zdos/users.zig writes them). Read anew
   for each lookup, as programs may change it. */
#define PW_MAX_USERS 64

static char pw_text[16 * 1024];
static struct passwd pw_users[PW_MAX_USERS];
static char pw_homes[PW_MAX_USERS][48];
static int pw_count;
static int pw_next; /* getpwent's */

static char boot_drive(void) {
    const char *spec = getenv("COMSPEC");
    return spec != NULL && spec[0] != '\0' && spec[1] == ':' ? spec[0] : 'C';
}

static void pw_load(void) {
    pw_count = 0;
    char path[] = "C:\\CONF\\USERS.CFG";
    path[0] = boot_drive();
    FILE *f = fopen(path, "r");
    size_t len = 0;
    if (f != NULL) {
        len = fread(pw_text, 1, sizeof(pw_text) - 1, f);
        fclose(f);
    }
    pw_text[len] = '\0';
    bool have_root = false;
    char *line = pw_text;
    while (line != NULL && *line != '\0' && pw_count < PW_MAX_USERS) {
        char *next = strchr(line, '\n');
        if (next != NULL) {
            *next++ = '\0';
        }
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\r' || line[n - 1] == ' ')) {
            line[--n] = '\0';
        }
        // name:uid:password:shell; the shell, last, may hold "C:"
        char *fields[4] = {line, NULL, NULL, NULL};
        for (int i = 1; i < 4; i++) {
            char *colon = strchr(fields[i - 1], ':');
            if (colon == NULL) {
                break;
            }
            *colon = '\0';
            fields[i] = colon + 1;
        }
        if (line[0] != '#' && line[0] != '\0' && fields[1] != NULL) {
            struct passwd *p = &pw_users[pw_count];
            p->pw_name = fields[0];
            p->pw_uid = (uid_t)strtoul(fields[1], NULL, 10);
            p->pw_gid = p->pw_uid;
            p->pw_passwd = (char *)"x"; /* as /etc/shadow keeps them on Unix */
            p->pw_gecos = fields[0];
            p->pw_shell = fields[3] != NULL && fields[3][0] != '\0' ? fields[3] : (char *)env_or("COMSPEC", "C:\\APPS\\COMMAND.APP");
            snprintf(pw_homes[pw_count], sizeof(pw_homes[0]), "%c:\\USERS\\%s", boot_drive(), fields[0]);
            p->pw_dir = pw_homes[pw_count];
            have_root |= strcasecmp(fields[0], "root") == 0;
            pw_count++;
        }
        line = next;
    }
    if (!have_root && pw_count < PW_MAX_USERS) {
        struct passwd *p = &pw_users[pw_count];
        p->pw_name = (char *)"ROOT";
        p->pw_uid = p->pw_gid = 0;
        p->pw_passwd = (char *)"x";
        p->pw_gecos = p->pw_name;
        p->pw_shell = (char *)env_or("COMSPEC", "C:\\APPS\\COMMAND.APP");
        snprintf(pw_homes[pw_count], sizeof(pw_homes[0]), "%c:\\USERS\\ROOT", boot_drive());
        p->pw_dir = pw_homes[pw_count];
        pw_count++;
    }
}

static zdos_ids ids_now(void);

// The current user's own HOME, if set, is its home
static struct passwd *pw_result(struct passwd *p) {
    if (p != NULL && p->pw_uid == ids_now().uid && getenv("HOME") != NULL) {
        p->pw_dir = getenv("HOME");
    }
    return p;
}

struct passwd *getpwnam(const char *name) {
    pw_load();
    for (int i = 0; name != NULL && i < pw_count; i++) {
        if (strcasecmp(pw_users[i].pw_name, name) == 0) {
            return pw_result(&pw_users[i]);
        }
    }
    return NULL;
}

struct passwd *getpwuid(uid_t uid) {
    pw_load();
    for (int i = 0; i < pw_count; i++) {
        if (pw_users[i].pw_uid == uid) {
            return pw_result(&pw_users[i]);
        }
    }
    return NULL;
}

void setpwent(void) {
    pw_next = 0;
    pw_count = 0;
}

void endpwent(void) {
    setpwent();
}

struct passwd *getpwent(void) {
    if (pw_next == 0) {
        pw_load();
    }
    return pw_next < pw_count ? pw_result(&pw_users[pw_next++]) : NULL;
}

static zdos_ids ids_now(void) {
    zdos_ids ids = {0};
    if (zdos != NULL && zdos->programs->get_ids != NULL) {
        zdos->programs->get_ids(&ids);
    }
    return ids;
}

uid_t getuid(void) { return ids_now().real; }
uid_t geteuid(void) { return ids_now().uid; }
gid_t getgid(void) { return ids_now().gid; }
gid_t getegid(void) { return ids_now().gid; }

int getgroups(int size, gid_t list[]) {
    zdos_ids ids = ids_now();
    int n = (int)ids.group_count;
    if (size == 0) {
        return n;
    }
    if (size < n) {
        errno = EINVAL;
        return -1;
    }
    for (int i = 0; i < n; i++) {
        list[i] = ids.groups[i];
    }
    return n;
}

static int set_ids(uint32_t real, uint32_t uid, uint32_t saved, uint32_t gid, uint32_t count, const gid_t *groups) {
    zdos_ids ids = {real, uid, saved, gid, count, {0}};
    if (count != ZDOS_KEEP_GROUPS) {
        if (count > 16) {
            errno = EINVAL;
            return -1;
        }
        for (uint32_t i = 0; i < count; i++) {
            ids.groups[i] = groups[i];
        }
    }
    if (zdos == NULL || zdos->programs->set_ids == NULL) {
        errno = ENOSYS;
        return -1;
    }
    if (!zdos->programs->set_ids(&ids)) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

#define KEEP ZDOS_KEEP_ID

int setgroups(size_t size, const gid_t *list) {
    return set_ids(KEEP, KEEP, KEEP, KEEP, (uint32_t)size, list);
}

/* POSIX: root sets all three, others only the effective one */
int setuid(uid_t uid) {
    return geteuid() == 0 ? set_ids(uid, uid, uid, KEEP, ZDOS_KEEP_GROUPS, NULL) : set_ids(KEEP, uid, KEEP, KEEP, ZDOS_KEEP_GROUPS, NULL);
}

int seteuid(uid_t uid) {
    return set_ids(KEEP, uid, KEEP, KEEP, ZDOS_KEEP_GROUPS, NULL);
}

int setreuid(uid_t real, uid_t effective) {
    return set_ids(real == (uid_t)-1 ? KEEP : real, effective == (uid_t)-1 ? KEEP : effective, KEEP, KEEP, ZDOS_KEEP_GROUPS, NULL);
}

int setresuid(uid_t real, uid_t effective, uid_t saved) {
    return set_ids(real == (uid_t)-1 ? KEEP : real, effective == (uid_t)-1 ? KEEP : effective, saved == (uid_t)-1 ? KEEP : saved,
                   KEEP, ZDOS_KEEP_GROUPS, NULL);
}

int getresuid(uid_t *real, uid_t *effective, uid_t *saved) {
    zdos_ids ids = ids_now();
    *real = ids.real;
    *effective = ids.uid;
    *saved = ids.saved;
    return 0;
}

/* One group id (the real and effective alike); root only, unless unchanged */
int setgid(gid_t gid) {
    if (gid == getgid()) {
        return 0;
    }
    return set_ids(KEEP, KEEP, KEEP, gid, ZDOS_KEEP_GROUPS, NULL);
}

int setegid(gid_t gid) {
    return setgid(gid);
}

/* The login name: of the real user, else USER */
char *getlogin(void) {
    struct passwd *p = getpwuid(getuid());
    return p != NULL ? p->pw_name : (char *)env_or("USER", "ROOT");
}
