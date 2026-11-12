#pragma once
#ifndef _ZDOS_ASSERT_H_
#define _ZDOS_ASSERT_H_

#if !defined(__cplusplus) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L && __STDC_VERSION__ < 202311L
#define static_assert _Static_assert
#endif

#ifdef NDEBUG
#define assert(expression) ((void)0)
#else
#define assert(expression) \
    ((void)((expression) ? (void)0 : __assert_fail(#expression, __FILE__, __LINE__)))

#ifdef __cplusplus
extern "C" {
#endif

void __assert_fail(const char *expr, const char *file, int line);

#ifdef __cplusplus
}
#endif

#endif

#endif
