#pragma once
#ifndef _ZDOS_FCNTL_H_
#define _ZDOS_FCNTL_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_ACCMODE 0003
#define O_CREAT 0100
#define O_EXCL 0200
#define O_TRUNC 01000
#define O_APPEND 02000
#define O_NONBLOCK 04000 /* pipes: read fails with EAGAIN instead of waiting */
#define O_CLOEXEC 02000000 /* accepted; descriptors are never inherited anyway */
/* DOS compilers' text / binary flags: ZDOS files are always binary (no
   CR LF translation), so both are accepted and do nothing */
#define O_BINARY 0
#define O_TEXT 0

/* mode is ignored: ZDOS files have only a read-only attribute (see chmod) */
int open(const char *pathname, int flags, ...);

/* openat: O_DIRECTORY gives a directory descriptor (for the *at
   functions and fdopendir); O_NOFOLLOW is accepted (no links to follow) */
#define O_DIRECTORY 0200000
#define O_NOFOLLOW 0400000
/* The current directory for the *at functions (Linux's values) */
#define AT_FDCWD (-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_REMOVEDIR 0x200
#define AT_SYMLINK_FOLLOW 0x400
#define AT_EMPTY_PATH 0x1000 /* fstatat with "": the descriptor itself */
int openat(int dirfd, const char *path, int flags, ...);
int creat(const char *pathname, mode_t mode);

/* F_DUPFD: dup to the lowest free descriptor >= arg;
   F_GETFL / F_SETFL: O_APPEND and O_NONBLOCK; F_GETFD /
   F_SETFD accepted (FD_CLOEXEC changes nothing:
   programs started get only the standard streams) */
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define F_DUPFD_CLOEXEC 1030
#define FD_CLOEXEC 1
int fcntl(int fd, int cmd, ...);

#ifdef __cplusplus
}
#endif

#endif
