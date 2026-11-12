#pragma once
#ifndef _ZDOS_SYS_STATVFS_H_
#define _ZDOS_SYS_STATVFS_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t fsblkcnt_t;
typedef uint64_t fsfilcnt_t;

/* Size and free space of the drive a path is on, in 512-byte blocks. FAT has
   no table of files, so the file counts are 0. f_fsid is the volume serial
   number (or the drive letter if there is none). */
struct statvfs {
    unsigned long f_bsize;   /* 512 */
    unsigned long f_frsize;  /* 512 */
    fsblkcnt_t f_blocks;
    fsblkcnt_t f_bfree;
    fsblkcnt_t f_bavail;
    fsfilcnt_t f_files;
    fsfilcnt_t f_ffree;
    fsfilcnt_t f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;    /* 0 */
    unsigned long f_namemax; /* 768 (bytes; FAT's 255 characters) */
};

#define ST_RDONLY 1
#define ST_NOSUID 2

int statvfs(const char *path, struct statvfs *buf);
int fstatvfs(int fd, struct statvfs *buf);

#ifdef __cplusplus
}
#endif

#endif
