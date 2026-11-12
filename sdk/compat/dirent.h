#pragma once
#ifndef _ZDOS_DIRENT_H_
#define _ZDOS_DIRENT_H_

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DT_UNKNOWN 0
#define DT_DIR 4
#define DT_REG 8

/* Subdirectories list "." and ".." too, as on ZDOS itself */
struct dirent {
    ino_t d_ino; /* the inode number on ext2, 0 on FAT */
    unsigned char d_type; /* DT_DIR or DT_REG */
    char d_name[769]; /* up to 768 bytes of UTF-8 (FAT's 255 characters) and the 0 */
};

typedef struct zdos_dir DIR;

DIR *opendir(const char *path); /* "" or "." is the current directory */
DIR *fdopendir(int fd); /* a directory descriptor's (openat with O_DIRECTORY) */
int dirfd(DIR *dir);    /* a directory descriptor for the *at functions */
struct dirent *readdir(DIR *dir); /* NULL at the end (errno 0) or on an error */
void rewinddir(DIR *dir);
int closedir(DIR *dir);

/* As POSIX: free each entry of *namelist, then the list. */
int scandir(const char *dir, struct dirent ***namelist, int (*filter)(const struct dirent *),
            int (*compar)(const struct dirent **, const struct dirent **));
int alphasort(const struct dirent **a, const struct dirent **b);

#ifdef __cplusplus
}
#endif

#endif
