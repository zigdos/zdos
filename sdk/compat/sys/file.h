#pragma once
#ifndef _ZDOS_SYS_FILE_H_
#define _ZDOS_SYS_FILE_H_

#include <fcntl.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LOCK_SH 1
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8

/* Locks are kept in the program only: other programs don't see them
   (zdos_unix.c) */
int flock(int fd, int operation);

#ifdef __cplusplus
}
#endif
#endif
