#pragma once
#ifndef _ZDOS_LIBGEN_H_
#define _ZDOS_LIBGEN_H_

#ifdef __cplusplus
extern "C" {
#endif

/* POSIX: the last part of a path, and the folder part ("C:\\A\\B.TXT"
   -> "B.TXT", "C:\\A"; "/" and "\\" both separate). Both may change
   path and return it or static text. (zdos_unix.c) */
char *basename(char *path);
char *dirname(char *path);

#ifdef __cplusplus
}
#endif
#endif
