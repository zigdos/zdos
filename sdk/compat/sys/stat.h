#pragma once
#ifndef _ZDOS_SYS_STAT_H_
#define _ZDOS_SYS_STAT_H_

#include <sys/types.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What ZDOS knows about a file: kind, size, permissions, owner, inode
   number, links and blocks (Unix ones on ext2; on FAT the mode is made up
   from read-only, owner and inode 0, one link); st_dev is the drive
   letter, st_rdev 0. st_ctime: the last status change on ext2, the
   creation time on FAT. Times are local time, as ZDOS has no time zone. */
struct stat {
    dev_t st_dev;
    ino_t st_ino;
    mode_t st_mode;
    nlink_t st_nlink;
    uid_t st_uid;
    gid_t st_gid;
    dev_t st_rdev;
    off_t st_size;
    blksize_t st_blksize;
    blkcnt_t st_blocks;
    struct timespec st_atim; /* whole seconds (FAT: 2 seconds, atime a date) */
    struct timespec st_mtim;
    struct timespec st_ctim;
};
#define st_atime st_atim.tv_sec
#define st_mtime st_mtim.tv_sec
#define st_ctime st_ctim.tv_sec

#define S_IFMT   0170000
#define S_IFDIR  0040000
#define S_IFCHR  0020000
#define S_IFREG  0100000
#define S_IFIFO  0010000
#define S_IFLNK  0120000 /* never on ZDOS: FAT has no links */
#define S_IFBLK  0060000 /* never on ZDOS */
#define S_IFSOCK 0140000

#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISFIFO(m) (((m) & S_IFMT) == S_IFIFO)
#define S_ISLNK(m) (((m) & S_IFMT) == S_IFLNK)
#define S_ISBLK(m) (((m) & S_IFMT) == S_IFBLK)
#define S_ISSOCK(m) (((m) & S_IFMT) == S_IFSOCK)

#define S_IRWXU 0700
#define S_IRUSR 0400
#define S_IWUSR 0200
#define S_IXUSR 0100
#define S_IRWXG 0070
#define S_IRGRP 0040
#define S_IWGRP 0020
#define S_IXGRP 0010
#define S_IRWXO 0007
#define S_IROTH 0004
#define S_IWOTH 0002
#define S_IXOTH 0001

int stat(const char *path, struct stat *st);
int fstat(int fd, struct stat *st);
int lstat(const char *path, struct stat *st); /* the same as stat: FAT has no links */
int mkdir(const char *path, mode_t mode); /* mode is ignored */
/* All of 07777 on ext2; on FAT without any write bit (S_IWUSR ...) the file
   becomes read-only, with one writable again */
int chmod(const char *path, mode_t mode);
int fchmod(int fd, mode_t mode); /* accepted, changes nothing: ZDOS sets modes by path */

/* The modification time of an open file to times[1] (NULL or UTIME_NOW:
   now; UTIME_OMIT: unchanged); times[0], the access time, is not kept.
   ENOSYS on a ZDOS without files->fset_time. */
#define UTIME_NOW 0x3fffffff
#define UTIME_OMIT 0x3ffffffe
int futimens(int fd, const struct timespec times[2]);
/* The *at forms (fcntl.h): relative to a directory descriptor or AT_FDCWD */
int fstatat(int dirfd, const char *path, struct stat *st, int flags);
int mkdirat(int dirfd, const char *path, mode_t mode);
int fchmodat(int dirfd, const char *path, mode_t mode, int flags);
int mkfifo(const char *path, mode_t mode); /* no FIFOs: EPERM */
/* The same by path (dirfd AT_FDCWD or a directory descriptor; flags ignored) */
int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags);

#ifdef __cplusplus
}
#endif

#endif
