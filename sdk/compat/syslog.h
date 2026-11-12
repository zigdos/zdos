#pragma once
#ifndef _ZDOS_SYSLOG_H_
#define _ZDOS_SYSLOG_H_

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/* No system log: messages go to stderr, "ident: message" (zdos_unix.c) */
#define LOG_EMERG 0
#define LOG_ALERT 1
#define LOG_CRIT 2
#define LOG_ERR 3
#define LOG_WARNING 4
#define LOG_NOTICE 5
#define LOG_INFO 6
#define LOG_DEBUG 7
#define LOG_PID 0x01
#define LOG_CONS 0x02
#define LOG_NDELAY 0x08
#define LOG_USER (1 << 3)
#define LOG_DAEMON (3 << 3)
#define LOG_LOCAL0 (16 << 3)
#define LOG_MASK(p) (1 << (p))
#define LOG_UPTO(p) ((1 << ((p) + 1)) - 1)

void openlog(const char *ident, int option, int facility);
void syslog(int priority, const char *format, ...) __attribute__((format(printf, 2, 3)));
void vsyslog(int priority, const char *format, va_list ap);
void closelog(void);
int setlogmask(int mask);

#ifdef __cplusplus
}
#endif
#endif
