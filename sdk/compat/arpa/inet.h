#pragma once
#ifndef _ZDOS_ARPA_INET_H_
#define _ZDOS_ARPA_INET_H_

#include <netinet/in.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Address text, real (zdos_unix.c) */
in_addr_t inet_addr(const char *text);
int inet_aton(const char *text, struct in_addr *out);
char *inet_ntoa(struct in_addr addr);
int inet_pton(int family, const char *text, void *out);
const char *inet_ntop(int family, const void *addr, char *out, socklen_t size);

#ifdef __cplusplus
}
#endif
#endif
