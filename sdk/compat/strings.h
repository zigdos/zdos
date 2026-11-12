#pragma once
#ifndef _ZDOS_STRINGS_H_
#define _ZDOS_STRINGS_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int strcasecmp(const char *s1, const char *s2);   /* ASCII letters */
int strncasecmp(const char *s1, const char *s2, size_t n);
void bzero(void *s, size_t n);
int bcmp(const void *a, const void *b, size_t n);

#ifdef __cplusplus
}
#endif

#endif
