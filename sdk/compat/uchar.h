#pragma once
#ifndef _ZDOS_UCHAR_H_
#define _ZDOS_UCHAR_H_

#include <wchar.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __cplusplus
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
#endif

/* UTF-8 to and from UTF-32 and UTF-16 (zdos_wchar.c) */
size_t mbrtoc32(char32_t *out, const char *s, size_t n, mbstate_t *st);
size_t c32rtomb(char *out, char32_t c, mbstate_t *st);
size_t mbrtoc16(char16_t *out, const char *s, size_t n, mbstate_t *st);
size_t c16rtomb(char *out, char16_t c, mbstate_t *st);

#ifdef __cplusplus
}
#endif

#endif
