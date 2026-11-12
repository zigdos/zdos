#pragma once
#ifndef _ZDOS_FTW_H_
#define _ZDOS_FTW_H_

#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What fn is told about each path */
#define FTW_F 0   /* a file */
#define FTW_D 1   /* a folder (before its contents) */
#define FTW_DNR 2 /* a folder that can't be read */
#define FTW_NS 3  /* stat failed */
#define FTW_SL 4  /* never: FAT has no links */
#define FTW_DP 5  /* a folder, after its contents (FTW_DEPTH) */
#define FTW_SLN 6 /* never */

/* nftw's flags. FTW_PHYS and FTW_MOUNT change nothing on ZDOS;
   FTW_CHDIR is not done. */
#define FTW_PHYS 0x01
#define FTW_MOUNT 0x02
#define FTW_DEPTH 0x04
#define FTW_CHDIR 0x08

struct FTW {
    int base;  /* where the name starts in the path */
    int level; /* 0 for the path given */
};

int ftw(const char *path, int (*fn)(const char *path, const struct stat *st, int type), int nopenfd);
int nftw(const char *path, int (*fn)(const char *path, const struct stat *st, int type, struct FTW *ftw),
         int nopenfd, int flags);

#ifdef __cplusplus
}
#endif

#endif
