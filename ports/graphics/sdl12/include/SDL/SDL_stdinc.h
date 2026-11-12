/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12, not SDL itself): basic types
   and the C library under SDL's names */
#ifndef _SDL_stdinc_h
#define _SDL_stdinc_h

#include <ctype.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define DECLSPEC
#define SDLCALL
#ifndef SDL_INLINE_OKAY
#define SDL_INLINE_OKAY
#endif

typedef enum { SDL_FALSE = 0, SDL_TRUE = 1 } SDL_bool;
typedef int8_t Sint8;
typedef uint8_t Uint8;
typedef int16_t Sint16;
typedef uint16_t Uint16;
typedef int32_t Sint32;
typedef uint32_t Uint32;
typedef int64_t Sint64;
typedef uint64_t Uint64;
#define SDL_HAS_64BIT_TYPE 1

#define SDL_arraysize(array) (sizeof(array) / sizeof(array[0]))
#define SDL_TABLESIZE(table) SDL_arraysize(table)

#define SDL_malloc malloc
#define SDL_calloc calloc
#define SDL_realloc realloc
#define SDL_free free
#define SDL_getenv getenv
#define SDL_putenv putenv
#define SDL_qsort qsort
#define SDL_abs abs
#define SDL_min(x, y) (((x) < (y)) ? (x) : (y))
#define SDL_max(x, y) (((x) > (y)) ? (x) : (y))
#define SDL_isdigit(X) isdigit(X)
#define SDL_isspace(X) isspace(X)
#define SDL_toupper(X) toupper(X)
#define SDL_tolower(X) tolower(X)
#define SDL_memset memset
#define SDL_memcpy memcpy
#define SDL_memmove memmove
#define SDL_memcmp memcmp
#define SDL_strlen strlen
#define SDL_strdup strdup
#define SDL_strchr strchr
#define SDL_strrchr strrchr
#define SDL_strstr strstr
#define SDL_strtol strtol
#define SDL_strtoul strtoul
#define SDL_strtod strtod
#define SDL_atoi atoi
#define SDL_atof atof
#define SDL_strcmp strcmp
#define SDL_strncmp strncmp
#define SDL_strcasecmp strcasecmp
#define SDL_strncasecmp strncasecmp
#define SDL_sscanf sscanf
#define SDL_snprintf snprintf
#define SDL_vsnprintf vsnprintf
#define SDL_stack_alloc(type, count) (type *)malloc(sizeof(type) * (count))
#define SDL_stack_free(data) free(data)
#define SDL_memset4(dst, val, len) \
    do { Uint32 *_p = (Uint32 *)(dst); size_t _n = (len); while (_n--) *_p++ = (val); } while (0)

static inline size_t SDL_strlcpy(char *dst, const char *src, size_t maxlen)
{
    size_t n = strlen(src);
    if (maxlen > 0) {
        size_t k = n < maxlen - 1 ? n : maxlen - 1;
        memcpy(dst, src, k);
        dst[k] = '\0';
    }
    return n;
}

static inline size_t SDL_strlcat(char *dst, const char *src, size_t maxlen)
{
    size_t d = strnlen(dst, maxlen);
    return d + SDL_strlcpy(dst + d, src, maxlen - d);
}

#endif
