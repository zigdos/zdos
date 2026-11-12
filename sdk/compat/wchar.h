#pragma once
#ifndef _ZDOS_WCHAR_H_
#define _ZDOS_WCHAR_H_

#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Wide characters are Unicode code points (wchar_t: 32 bits); multibyte
   text is UTF-8, whatever setlocale says. Implemented in zdos_wchar.c. */
#ifndef _WINT_T_DEFINED
#define _WINT_T_DEFINED
typedef unsigned int wint_t;
#endif
#define WEOF ((wint_t)0xFFFFFFFFu)
#ifndef WCHAR_MIN
#define WCHAR_MIN __WCHAR_MIN__
#define WCHAR_MAX __WCHAR_MAX__
#endif

/* Where a conversion stopped inside a UTF-8 sequence */
typedef struct {
    unsigned int pending; /* bits so far */
    unsigned char need; /* continuation bytes still to come */
    unsigned char seen;
    unsigned char pad[2];
} mbstate_t;

int mbsinit(const mbstate_t *st);
size_t mbrtowc(wchar_t *out, const char *s, size_t n, mbstate_t *st);
size_t mbrlen(const char *s, size_t n, mbstate_t *st);
size_t wcrtomb(char *out, wchar_t c, mbstate_t *st);
size_t mbsrtowcs(wchar_t *out, const char **src, size_t n, mbstate_t *st);
size_t wcsrtombs(char *out, const wchar_t **src, size_t n, mbstate_t *st);
size_t mbsnrtowcs(wchar_t *out, const char **src, size_t nms, size_t n, mbstate_t *st);
size_t wcsnrtombs(char *out, const wchar_t **src, size_t nwc, size_t n, mbstate_t *st);
wint_t btowc(int c);
int wctob(wint_t c);

size_t wcslen(const wchar_t *s);
size_t wcsnlen(const wchar_t *s, size_t max);
wchar_t *wcscpy(wchar_t *dest, const wchar_t *src);
wchar_t *wcsncpy(wchar_t *dest, const wchar_t *src, size_t n);
wchar_t *wcscat(wchar_t *dest, const wchar_t *src);
wchar_t *wcsncat(wchar_t *dest, const wchar_t *src, size_t n);
int wcscmp(const wchar_t *a, const wchar_t *b);
int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n);
int wcscasecmp(const wchar_t *a, const wchar_t *b);
int wcsncasecmp(const wchar_t *a, const wchar_t *b, size_t n);
int wcscoll(const wchar_t *a, const wchar_t *b); /* as wcscmp */
size_t wcsxfrm(wchar_t *dest, const wchar_t *src, size_t n);
#ifndef _LOCALE_T_DEFINED
#define _LOCALE_T_DEFINED
typedef struct zdos_locale *locale_t;
#endif
int wcscoll_l(const wchar_t *a, const wchar_t *b, locale_t loc);
size_t wcsxfrm_l(wchar_t *dest, const wchar_t *src, size_t n, locale_t loc);
wchar_t *wcschr(const wchar_t *s, wchar_t c);
wchar_t *wcsrchr(const wchar_t *s, wchar_t c);
wchar_t *wcsstr(const wchar_t *hay, const wchar_t *needle);
wchar_t *wcspbrk(const wchar_t *s, const wchar_t *set);
size_t wcsspn(const wchar_t *s, const wchar_t *set);
size_t wcscspn(const wchar_t *s, const wchar_t *set);
wchar_t *wcstok(wchar_t *s, const wchar_t *delim, wchar_t **save);
wchar_t *wcsdup(const wchar_t *s);
wchar_t *wmemcpy(wchar_t *dest, const wchar_t *src, size_t n);
wchar_t *wmemmove(wchar_t *dest, const wchar_t *src, size_t n);
wchar_t *wmemset(wchar_t *dest, wchar_t c, size_t n);
int wmemcmp(const wchar_t *a, const wchar_t *b, size_t n);
wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n);

long wcstol(const wchar_t *s, wchar_t **end, int base);
unsigned long wcstoul(const wchar_t *s, wchar_t **end, int base);
long long wcstoll(const wchar_t *s, wchar_t **end, int base);
unsigned long long wcstoull(const wchar_t *s, wchar_t **end, int base);
double wcstod(const wchar_t *s, wchar_t **end);
float wcstof(const wchar_t *s, wchar_t **end);
long double wcstold(const wchar_t *s, wchar_t **end);

/* Columns a character takes on a terminal: 0 (combining marks), 2 (East
   Asian wide, emoji), -1 (control characters), else 1 */
int wcwidth(wchar_t c);
int wcswidth(const wchar_t *s, size_t n);

/* Streams read and write UTF-8 */
wint_t fgetwc(FILE *f);
wint_t fgetwc_unlocked(FILE *f);
wint_t getwc(FILE *f);
wint_t getwchar(void);
wint_t fputwc(wchar_t c, FILE *f);
wint_t putwc(wchar_t c, FILE *f);
wint_t putwchar(wchar_t c);
wint_t ungetwc(wint_t c, FILE *f);
wchar_t *fgetws(wchar_t *s, int n, FILE *f);
int fputws(const wchar_t *s, FILE *f);
int fwide(FILE *f, int mode);

/* Formats are wide; %s and %c take narrow (UTF-8) arguments, %ls and %lc
   wide ones, as in C. Results longer than 4 KB are cut. */
int swprintf(wchar_t *out, size_t n, const wchar_t *format, ...);
int vswprintf(wchar_t *out, size_t n, const wchar_t *format, va_list ap);
int fwprintf(FILE *f, const wchar_t *format, ...);
int vfwprintf(FILE *f, const wchar_t *format, va_list ap);
int wprintf(const wchar_t *format, ...);
int vwprintf(const wchar_t *format, va_list ap);
size_t wcsftime(wchar_t *out, size_t n, const wchar_t *format, const struct tm *tm);

#ifdef __cplusplus
}
#endif

#endif
