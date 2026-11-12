#pragma once
#ifndef _ZDOS_GLOB_H_
#define _ZDOS_GLOB_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    size_t gl_pathc; /* the names found */
    char **gl_pathv; /* gl_offs NULLs, the names, then NULL */
    size_t gl_offs;  /* with GLOB_DOOFFS */
} glob_t;

#define GLOB_ERR 0x01      /* stop at a folder that can't be read */
#define GLOB_MARK 0x02     /* a / after each folder */
#define GLOB_NOSORT 0x04
#define GLOB_DOOFFS 0x08
#define GLOB_NOCHECK 0x10  /* no match: the pattern itself */
#define GLOB_APPEND 0x20
#define GLOB_NOESCAPE 0x40 /* always so on ZDOS: \ separates folders */

#define GLOB_NOSPACE 1
#define GLOB_ABORTED 2
#define GLOB_NOMATCH 3

/* The names matching pattern, sorted. * ? [...] in any part between / or \;
   letters match in either case, as ZDOS names do. */
int glob(const char *pattern, int flags, int (*errfunc)(const char *path, int err), glob_t *pglob);
void globfree(glob_t *pglob);

#ifdef __cplusplus
}
#endif

#endif
