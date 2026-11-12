#pragma once
#ifndef _ZDOS_SYS_TYPES_H_
#define _ZDOS_SYS_TYPES_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The same widths on every zdos (x86, x86-64, ARM64): file offsets and times
   are 64-bit, so FAT's 4 GB files and dates after 2038 fit everywhere */
#ifndef _SSIZE_T_DEFINED
#define _SSIZE_T_DEFINED
typedef __PTRDIFF_TYPE__ ssize_t;
#endif
#ifndef _OFF_T_DEFINED
#define _OFF_T_DEFINED
typedef int64_t off_t;
#endif
#ifndef _TIME_T_DEFINED
#define _TIME_T_DEFINED
typedef int64_t time_t;
#endif
#ifndef _CLOCK_T_DEFINED
#define _CLOCK_T_DEFINED
typedef long clock_t;
#endif

typedef uint32_t mode_t;
typedef uint32_t dev_t;
typedef uint64_t ino_t;
typedef uint32_t nlink_t;
typedef uint32_t uid_t;
typedef uint32_t gid_t;
typedef int pid_t;
typedef uint32_t id_t;
/* BSD names */
typedef uint8_t u_int8_t;
typedef uint16_t u_int16_t;
typedef uint32_t u_int32_t;
typedef uint64_t u_int64_t;
typedef unsigned char u_char;
typedef unsigned short u_short;
typedef unsigned int u_int;
typedef unsigned long u_long;
typedef int32_t blksize_t;
typedef int64_t blkcnt_t;
typedef long suseconds_t;
typedef uint32_t useconds_t;

#ifdef __cplusplus
}
#endif

/* fd_set and select too, as glibc's sys/types.h has them */
#include <sys/select.h>

#endif
