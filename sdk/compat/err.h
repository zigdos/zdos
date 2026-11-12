#pragma once
#ifndef _ZDOS_ERR_H_
#define _ZDOS_ERR_H_

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/* BSD: "PROGRAM: message: strerror(errno)" on stderr (the x forms without
   errno), then err exits with the code (zdos_unix.c) */
void err(int code, const char *format, ...) __attribute__((noreturn, format(printf, 2, 3)));
void errx(int code, const char *format, ...) __attribute__((noreturn, format(printf, 2, 3)));
void warn(const char *format, ...) __attribute__((format(printf, 1, 2)));
void warnx(const char *format, ...) __attribute__((format(printf, 1, 2)));
void verr(int code, const char *format, va_list ap) __attribute__((noreturn));
void verrx(int code, const char *format, va_list ap) __attribute__((noreturn));
void vwarn(const char *format, va_list ap);
void vwarnx(const char *format, va_list ap);
/* The program's name as err prints it (from its path, without .APP) */
const char *getprogname(void);
void setprogname(const char *name);

#ifdef __cplusplus
}
#endif
#endif
