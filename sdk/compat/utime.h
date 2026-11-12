#pragma once
#ifndef _ZDOS_UTIME_H_
#define _ZDOS_UTIME_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

struct utimbuf {
    time_t actime;  /* not kept: FAT records only the date of the last access */
    time_t modtime;
};

/* Sets the modification time (NULL: now), to 2 seconds as FAT keeps it */
int utime(const char *path, const struct utimbuf *times);

#ifdef __cplusplus
}
#endif

#endif
