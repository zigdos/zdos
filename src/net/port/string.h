/* What lwIP uses of string.h: the mem* functions come with the
   compiler's runtime, the str* ones are here */
#ifndef ZDOS_LWIP_STRING_H
#define ZDOS_LWIP_STRING_H
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);

static inline size_t zdos_lwip_strlen(const char *s) {
    size_t n = 0;
    while (s[n] != 0) n++;
    return n;
}

static inline int zdos_lwip_strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i] || a[i] == 0) return (unsigned char)a[i] - (unsigned char)b[i];
    }
    return 0;
}

static inline int zdos_lwip_strcmp(const char *a, const char *b) {
    return zdos_lwip_strncmp(a, b, (size_t)-1);
}

#define strlen zdos_lwip_strlen
#define strncmp zdos_lwip_strncmp
#define strcmp zdos_lwip_strcmp
#endif
