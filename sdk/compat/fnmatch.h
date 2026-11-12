#pragma once
#ifndef _ZDOS_FNMATCH_H_
#define _ZDOS_FNMATCH_H_

#ifdef __cplusplus
extern "C" {
#endif

#define FNM_NOMATCH 1

#define FNM_NOESCAPE 0x01 /* \ is an ordinary character */
#define FNM_PATHNAME 0x02 /* / only matched by a / */
#define FNM_PERIOD 0x04   /* a leading . only matched by a . */
#define FNM_CASEFOLD 0x10 /* letters in either case */
#define FNM_IGNORECASE FNM_CASEFOLD

/* 0 if string matches pattern (* ? [...]), else FNM_NOMATCH */
int fnmatch(const char *pattern, const char *string, int flags);

#ifdef __cplusplus
}
#endif

#endif
