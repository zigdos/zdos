#pragma once
#ifndef _ZDOS_SYS_MMAN_H_
#define _ZDOS_SYS_MMAN_H_

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One address space: mappings are heap memory, all of it committed. A file
   is read in at mmap; MAP_SHARED writes go back at msync, munmap and exit.
   MAP_FIXED only inside an existing mapping. mprotect, madvise and mlock
   change nothing (but MADV_DONTNEED zeroes anonymous pages). */

#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4

#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_SHARED_VALIDATE 0x03
#define MAP_TYPE 0x0f
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS
#define MAP_NORESERVE 0x4000
#define MAP_POPULATE 0x8000
#define MAP_NONBLOCK 0x10000
#define MAP_STACK 0x20000
#define MAP_FIXED_NOREPLACE 0x100000
#define MAP_FILE 0

#define MAP_FAILED ((void *)-1)

#define MS_ASYNC 1
#define MS_INVALIDATE 2
#define MS_SYNC 4

#define MADV_NORMAL 0
#define MADV_RANDOM 1
#define MADV_SEQUENTIAL 2
#define MADV_WILLNEED 3
#define MADV_DONTNEED 4
#define MADV_FREE 8
#define POSIX_MADV_NORMAL 0
#define POSIX_MADV_RANDOM 1
#define POSIX_MADV_SEQUENTIAL 2
#define POSIX_MADV_WILLNEED 3
#define POSIX_MADV_DONTNEED 4

#define MCL_CURRENT 1
#define MCL_FUTURE 2

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void *addr, size_t length);
int mprotect(void *addr, size_t length, int prot);
int msync(void *addr, size_t length, int flags);
int madvise(void *addr, size_t length, int advice);
int posix_madvise(void *addr, size_t length, int advice);
int mlock(const void *addr, size_t length);
int munlock(const void *addr, size_t length);
int mlockall(int flags);
int munlockall(void);

/* Anonymous mappings grow by moving (MREMAP_MAYMOVE: a new mapping, the
   contents copied) and shrink in place; file mappings can't be resized */
#define MREMAP_MAYMOVE 1
#define MREMAP_FIXED 2
void *mremap(void *old_address, size_t old_size, size_t new_size, int flags, ...);

#ifdef __cplusplus
}
#endif

#endif
