#pragma once
#ifndef _ZDOS_STRING_H_
#define _ZDOS_STRING_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NULL
#define NULL ((void*)0)
#endif

void *memcpy(void *dest, const void *src, size_t n);
void *memset(void *s, int c, size_t n);
void *memmove(void *dest, const void *src, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t maxlen);
int strcmp(const char *s1, const char *s2);
int strncmp(const char *s1, const char *s2, size_t n);
int strcoll(const char *s1, const char *s2); /* "C" locale: strcmp */
size_t strxfrm(char *dest, const char *src, size_t n); /* "C" locale: a copy */
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
char *strpbrk(const char *s, const char *accept);
size_t strspn(const char *s, const char *accept);
size_t strcspn(const char *s, const char *reject);
char *strcpy(char *dest, const char *src);
char *strncpy(char *dest, const char *src, size_t n);
char *strcat(char *dest, const char *src);
char *strncat(char *dest, const char *src, size_t n);
char *strdup(const char *s);
char *strndup(const char *s, size_t n);
char *strtok(char *s, const char *delim);
char *strtok_r(char *s, const char *delim, char **save);
char *strerror(int errnum);
int strerror_r(int errnum, char *buf, size_t size); /* POSIX form: 0 or ERANGE */
char *strsignal(int sig);
void *memmem(const void *haystack, size_t haystack_len, const void *needle, size_t needle_len);
char *strcasestr(const char *haystack, const char *needle); /* letters in either case */

#ifndef _LOCALE_T_DEFINED
#define _LOCALE_T_DEFINED
typedef struct zdos_locale *locale_t;
#endif
int strcoll_l(const char *s1, const char *s2, locale_t loc);
size_t strxfrm_l(char *dest, const char *src, size_t n, locale_t loc);

#ifdef __cplusplus
}
#endif

/* strcasecmp, bzero ... too, as glibc's string.h has them */
#include <strings.h>

#endif
