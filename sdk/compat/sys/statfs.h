#pragma once
#ifndef _ZDOS_SYS_STATFS_H_
#define _ZDOS_SYS_STATFS_H_

#include <sys/statvfs.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Linux's statfs, laid out as musl's (Rust's libc passes this one): the
   drive's size as statvfs gives it; f_type is the file system's Linux magic
   number (FAT 0x4d44, ext2 0xef53, Minix V3 0x4d5a; 0 for others). */
typedef struct {
    int __val[2];
} fsid_t;

struct statfs {
    unsigned long f_type, f_bsize;
    fsblkcnt_t f_blocks, f_bfree, f_bavail;
    fsfilcnt_t f_files, f_ffree;
    fsid_t f_fsid;
    unsigned long f_namelen, f_frsize, f_flags, f_spare[4];
};

int statfs(const char *path, struct statfs *buf);
int fstatfs(int fd, struct statfs *buf);

#ifdef __cplusplus
}
#endif

#endif
