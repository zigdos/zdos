/* What lwIP uses of stdlib.h: atoi (netif_find) */
#ifndef ZDOS_LWIP_STDLIB_H
#define ZDOS_LWIP_STDLIB_H

static inline int zdos_lwip_atoi(const char *s) {
    int n = 0;
    while (*s >= '0' && *s <= '9') n = n * 10 + (*s++ - '0');
    return n;
}

#define atoi zdos_lwip_atoi
#endif
