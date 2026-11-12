#pragma once
#ifndef _ZDOS_STDLIB_H_
#define _ZDOS_STDLIB_H_

#include <stddef.h>
#include <alloca.h> /* alloca, as glibc's stdlib.h has it */

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NULL
#define NULL ((void*)0)
#endif

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff

typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
typedef struct { long long quot, rem; } lldiv_t;

void *malloc(size_t size);
/* Aligned blocks (alignment a power of two), freed with free */
void *aligned_alloc(size_t alignment, size_t size);
int posix_memalign(void **out, size_t alignment, size_t size);

/* Multibyte text is UTF-8 (wide characters: wchar.h) */
#define MB_CUR_MAX 4
int mblen(const char *s, size_t n);
int mbtowc(wchar_t *out, const char *s, size_t n);
int wctomb(char *out, wchar_t c);
size_t mbstowcs(wchar_t *out, const char *s, size_t n);
size_t wcstombs(char *out, const wchar_t *s, size_t n);
void free(void *ptr);
void *realloc(void *ptr, size_t size);
void *calloc(size_t nmemb, size_t size);

/* exit runs the atexit functions and ends the program with status & 255;
   abort ends it with 3, as on DOS */
void abort(void) __attribute__((noreturn));
void exit(int status) __attribute__((noreturn));
void _Exit(int status) __attribute__((noreturn));
int atexit(void (*func)(void));

int atoi(const char *nptr);
long atol(const char *nptr);
long long atoll(const char *nptr);
long strtol(const char *nptr, char **endptr, int base);
unsigned long strtoul(const char *nptr, char **endptr, int base);
long long strtoll(const char *nptr, char **endptr, int base);
unsigned long long strtoull(const char *nptr, char **endptr, int base);
/* Correctly rounded, as glibc. strtold gives only a double's precision. */
double strtod(const char *nptr, char **endptr);
float strtof(const char *nptr, char **endptr);
long double strtold(const char *nptr, char **endptr);
double atof(const char *nptr);
#ifndef _LOCALE_T_DEFINED
#define _LOCALE_T_DEFINED
typedef struct zdos_locale *locale_t;
#endif
long strtol_l(const char *nptr, char **endptr, int base, locale_t loc);
unsigned long strtoul_l(const char *nptr, char **endptr, int base, locale_t loc);
long long strtoll_l(const char *nptr, char **endptr, int base, locale_t loc);
unsigned long long strtoull_l(const char *nptr, char **endptr, int base, locale_t loc);
double strtod_l(const char *nptr, char **endptr, locale_t loc);
float strtof_l(const char *nptr, char **endptr, locale_t loc);
long double strtold_l(const char *nptr, char **endptr, locale_t loc);

int abs(int x);
long labs(long x);
long long llabs(long long x);
div_t div(int num, int den);
ldiv_t ldiv(long num, long den);
lldiv_t lldiv(long long num, long long den);

void qsort(void *base, size_t count, size_t size, int (*compare)(const void *, const void *));
/* qsort passing arg on to compare (GNU's and POSIX 2024's order) */
void qsort_r(void *base, size_t count, size_t size, int (*compare)(const void *, const void *, void *), void *arg);
void *bsearch(const void *key, const void *base, size_t count, size_t size, int (*compare)(const void *, const void *));
int rand(void);
void srand(unsigned int seed);
/* Random numbers from getentropy (sys/random.h) */
__UINT32_TYPE__ arc4random(void);
void arc4random_buf(void *buf, size_t n);
__UINT32_TYPE__ arc4random_uniform(__UINT32_TYPE__ bound);

/* The full path of an existing file or folder, in
   ZDOS form ("C:\NOTES\Report.txt":
   drive, no "." or "..", the on-disk spelling). resolved: at least PATH_MAX
   bytes, or NULL to get one from malloc. */
char *realpath(const char *path, char *resolved);

/* A variable (SET, PATH ...) as seen where the program was started; the
   string stays valid until the program ends */
char *getenv(const char *name);
/* Runs a command line as if typed at the prompt (built-in commands
   too) and returns ERRORLEVEL afterwards; system(NULL) is 1:
   a command processor exists */
int system(const char *command);
/* Change the program's own variables, which the programs it starts see too
   (as on POSIX; the variables where it was started don't change, and the
   changes end with the program). ZDOS has no empty variables: setenv with ""
   removes the variable for the program. putenv copies the text. */
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int putenv(char *string); /* "NAME=value"; "NAME" removes */

/* The template's last six characters, XXXXXX, become letters and digits */
int mkstemp(char *template_name);
char *mkdtemp(char *template_name);

#ifdef __cplusplus
}
#endif

#endif
