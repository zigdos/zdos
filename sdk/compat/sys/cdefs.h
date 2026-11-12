#pragma once
#ifndef _ZDOS_SYS_CDEFS_H_
#define _ZDOS_SYS_CDEFS_H_

/* What glibc and the BSDs put here, for code that includes it */
#ifdef __cplusplus
#define __BEGIN_DECLS extern "C" {
#define __END_DECLS }
#else
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#define __P(args) args
#define __PMT(args) args
#define __CONCAT(x, y) x##y
#define __STRING(x) #x
#define __THROW
#define __wur
#define __restrict restrict
#define __restrict_arr
#define __inline inline
#define __attribute_pure__ __attribute__((pure))
#define __attribute_const__ __attribute__((const))
#define __attribute_malloc__ __attribute__((malloc))
#define __attribute_deprecated__ __attribute__((deprecated))
#define __nonnull(params) __attribute__((nonnull params))
#define __dead2 __attribute__((noreturn))
#define __pure2 __attribute__((const))
#define __unused __attribute__((unused))
#define __used __attribute__((used))
#define __packed __attribute__((packed))
#define __aligned(x) __attribute__((aligned(x)))
#define __printflike(f, a) __attribute__((format(printf, f, a)))
#define __scanflike(f, a) __attribute__((format(scanf, f, a)))
#define __predict_true(e) __builtin_expect((e) != 0, 1)
#define __predict_false(e) __builtin_expect((e) != 0, 0)
#define __glibc_likely(e) __builtin_expect((e) != 0, 1)
#define __glibc_unlikely(e) __builtin_expect((e) != 0, 0)
#define __GNUC_PREREQ(maj, min) ((__GNUC__ << 16) + __GNUC_MINOR__ >= ((maj) << 16) + (min))
#define __glibc_has_attribute(a) __has_attribute(a)
#define __FBSDID(s)
#define __RCSID(s)
#define __KERNEL_RCSID(n, s)
/* Other names for a function (BSD sources); the names as written, not
   macro-expanded (NetBSD's namespace.h renames functions with macros) */
#define __strong_alias(alias, sym) __asm__(".globl " #alias "\n.set " #alias ", " #sym);
#define __weak_alias(alias, sym) __asm__(".weak " #alias "\n.set " #alias ", " #sym);
#define __weak_reference(sym, alias) __weak_alias(alias, sym)
#define __COPYRIGHT(s)

#endif
