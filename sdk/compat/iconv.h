#pragma once
#ifndef _ZDOS_ICONV_H_
#define _ZDOS_ICONV_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Between UTF-8, ASCII, ISO-8859-1 (LATIN1), CP437 and UTF-16/32 (LE, BE,
   or with a byte order mark), any case; others fail with EINVAL
   (zdos_unix.c) */
typedef void *iconv_t;

iconv_t iconv_open(const char *to, const char *from);
size_t iconv(iconv_t cd, char **in, size_t *in_left, char **out, size_t *out_left);
int iconv_close(iconv_t cd);

#ifdef __cplusplus
}
#endif
#endif
