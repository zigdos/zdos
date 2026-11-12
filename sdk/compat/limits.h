#pragma once
#ifndef _ZDOS_LIMITS_H_
#define _ZDOS_LIMITS_H_

#ifndef CHAR_BIT
#define CHAR_BIT __CHAR_BIT__
#endif
#ifndef INT_MAX
#define INT_MAX __INT_MAX__
#define INT_MIN (-INT_MAX - 1)
#endif
#ifndef UINT_MAX
#define UINT_MAX (__INT_MAX__ * 2U + 1U)
#endif
#ifndef SHRT_MAX
#define SHRT_MAX __SHRT_MAX__
#define SHRT_MIN (-SHRT_MAX - 1)
#endif
#ifndef USHRT_MAX
#define USHRT_MAX (__SHRT_MAX__ * 2U + 1U)
#endif
#ifndef UCHAR_MAX
#define UCHAR_MAX (__SCHAR_MAX__ * 2U + 1U)
#endif
#ifndef SCHAR_MAX
#define SCHAR_MAX __SCHAR_MAX__
#define SCHAR_MIN (-SCHAR_MAX - 1)
#endif
#ifndef LLONG_MAX
#define LLONG_MAX __LONG_LONG_MAX__
#define LLONG_MIN (-LLONG_MAX - 1LL)
#endif
#ifndef ULLONG_MAX
#define ULLONG_MAX (__LONG_LONG_MAX__ * 2ULL + 1ULL)
#endif
#ifndef LONG_MAX
#define LONG_MAX __LONG_MAX__
#define LONG_MIN (-LONG_MAX - 1L)
#endif
#ifndef ULONG_MAX
#define ULONG_MAX (__LONG_MAX__ * 2UL + 1UL)
#endif
#ifndef SIZE_MAX
#define SIZE_MAX __SIZE_MAX__
#endif
#ifndef CHAR_MIN
#ifdef __CHAR_UNSIGNED__
#define CHAR_MIN 0
#define CHAR_MAX UCHAR_MAX
#else
#define CHAR_MIN SCHAR_MIN
#define CHAR_MAX SCHAR_MAX
#endif
#endif
#ifndef SSIZE_MAX
#define SSIZE_MAX __PTRDIFF_MAX__
#endif
#ifndef MB_LEN_MAX
#define MB_LEN_MAX 4 /* UTF-8 */
#endif
/* ZDOS paths: "C:" and up to 1024 bytes of UTF-8, then the terminating 0 */
#ifndef PATH_MAX
#define PATH_MAX 1028
#endif
/* One name: FAT's 255 characters are up to 768 bytes of UTF-8 */
#ifndef NAME_MAX
#define NAME_MAX 768
#endif

#endif
