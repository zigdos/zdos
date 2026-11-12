/* The small C++ runtime for programs without libc++ (-fno-exceptions -fno-rtti;
 * zdos-c++ links libc++abi's instead): operator new / delete over malloc,
 * static-local guards, pure virtual calls. Written in C under the Itanium ABI's
 * names (__cxa_atexit is in zdos_libc.c, with atexit). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "zdos.h"
#include "zdos_internal.h"

/* size_t in mangled names: unsigned long (m) on 64 bits, unsigned
   int (j) on 32 */
#if __SIZEOF_SIZE_T__ == 8
#define SZ "m"
#else
#define SZ "j"
#endif
#define NOTHROW "RKSt9nothrow_t"
#define ALIGN "St11align_val_t"

static void out_of_memory(void) {
    fputs("Out of memory (operator new)\n", stderr);
    abort(); /* no exceptions to throw std::bad_alloc with */
}

static void *new_plain(size_t size) {
    void *p = malloc(size != 0 ? size : 1);
    if (p == NULL) {
        out_of_memory();
    }
    return p;
}

static void *new_aligned(size_t size, size_t align) {
    void *p = NULL;
    if (align < sizeof(void *)) {
        align = sizeof(void *);
    }
    if (posix_memalign(&p, align, size != 0 ? size : 1) != 0) {
        return NULL;
    }
    return p;
}

static void *new_aligned_or_die(size_t size, size_t align) {
    void *p = new_aligned(size, align);
    if (p == NULL) {
        out_of_memory();
    }
    return p;
}

/* std::nothrow */
const struct { char unused; } zdos_cxx_nothrow __asm__("_ZSt7nothrow") = {0};

/* operator new(size_t), new[](size_t) and their nothrow forms */
void *zdos_cxx_new(size_t size) __asm__("_Znw" SZ);
void *zdos_cxx_new_array(size_t size) __asm__("_Zna" SZ);
void *zdos_cxx_new_nothrow(size_t size, const void *tag) __asm__("_Znw" SZ NOTHROW);
void *zdos_cxx_new_array_nothrow(size_t size, const void *tag) __asm__("_Zna" SZ NOTHROW);
void *zdos_cxx_new(size_t size) { return new_plain(size); }
void *zdos_cxx_new_array(size_t size) { return new_plain(size); }
void *zdos_cxx_new_nothrow(size_t size, const void *tag) { (void)tag; return malloc(size != 0 ? size : 1); }
void *zdos_cxx_new_array_nothrow(size_t size, const void *tag) { (void)tag; return malloc(size != 0 ? size : 1); }

/* C++17 aligned forms: operator new(size_t, align_val_t) ... */
void *zdos_cxx_new_al(size_t size, size_t align) __asm__("_Znw" SZ ALIGN);
void *zdos_cxx_new_array_al(size_t size, size_t align) __asm__("_Zna" SZ ALIGN);
void *zdos_cxx_new_al_nothrow(size_t size, size_t align, const void *tag) __asm__("_Znw" SZ ALIGN NOTHROW);
void *zdos_cxx_new_array_al_nothrow(size_t size, size_t align, const void *tag) __asm__("_Zna" SZ ALIGN NOTHROW);
void *zdos_cxx_new_al(size_t size, size_t align) { return new_aligned_or_die(size, align); }
void *zdos_cxx_new_array_al(size_t size, size_t align) { return new_aligned_or_die(size, align); }
void *zdos_cxx_new_al_nothrow(size_t size, size_t align, const void *tag) { (void)tag; return new_aligned(size, align); }
void *zdos_cxx_new_array_al_nothrow(size_t size, size_t align, const void *tag) { (void)tag; return new_aligned(size, align); }

/* operator delete and delete[]: plain, sized, nothrow, aligned (all free) */
void zdos_cxx_delete(void *p) __asm__("_ZdlPv");
void zdos_cxx_delete_array(void *p) __asm__("_ZdaPv");
void zdos_cxx_delete_sized(void *p, size_t size) __asm__("_ZdlPv" SZ);
void zdos_cxx_delete_array_sized(void *p, size_t size) __asm__("_ZdaPv" SZ);
void zdos_cxx_delete_nothrow(void *p, const void *tag) __asm__("_ZdlPv" NOTHROW);
void zdos_cxx_delete_array_nothrow(void *p, const void *tag) __asm__("_ZdaPv" NOTHROW);
void zdos_cxx_delete_al(void *p, size_t align) __asm__("_ZdlPv" ALIGN);
void zdos_cxx_delete_array_al(void *p, size_t align) __asm__("_ZdaPv" ALIGN);
void zdos_cxx_delete_sized_al(void *p, size_t size, size_t align) __asm__("_ZdlPv" SZ ALIGN);
void zdos_cxx_delete_array_sized_al(void *p, size_t size, size_t align) __asm__("_ZdaPv" SZ ALIGN);
void zdos_cxx_delete_al_nothrow(void *p, size_t align, const void *tag) __asm__("_ZdlPv" ALIGN NOTHROW);
void zdos_cxx_delete_array_al_nothrow(void *p, size_t align, const void *tag) __asm__("_ZdaPv" ALIGN NOTHROW);
void zdos_cxx_delete(void *p) { free(p); }
void zdos_cxx_delete_array(void *p) { free(p); }
void zdos_cxx_delete_sized(void *p, size_t size) { (void)size; free(p); }
void zdos_cxx_delete_array_sized(void *p, size_t size) { (void)size; free(p); }
void zdos_cxx_delete_nothrow(void *p, const void *tag) { (void)tag; free(p); }
void zdos_cxx_delete_array_nothrow(void *p, const void *tag) { (void)tag; free(p); }
void zdos_cxx_delete_al(void *p, size_t align) { (void)align; free(p); }
void zdos_cxx_delete_array_al(void *p, size_t align) { (void)align; free(p); }
void zdos_cxx_delete_sized_al(void *p, size_t size, size_t align) { (void)size; (void)align; free(p); }
void zdos_cxx_delete_array_sized_al(void *p, size_t size, size_t align) { (void)size; (void)align; free(p); }
void zdos_cxx_delete_al_nothrow(void *p, size_t align, const void *tag) { (void)align; (void)tag; free(p); }
void zdos_cxx_delete_array_al_nothrow(void *p, size_t align, const void *tag) { (void)align; (void)tag; free(p); }

/* Static locals: guard byte 0 is "done" (bit 0 as ARM64 tests it),
   byte 1 "being made". One recursive lock, held while a constructor
   runs, so one that makes other static locals works. */

static zdos_rlock guard_lock;

int __cxa_guard_acquire(uint64_t *guard) {
    volatile uint8_t *g = (volatile uint8_t *)guard;
    if (__atomic_load_n(&g[0], __ATOMIC_ACQUIRE) != 0) {
        return 0;
    }
    zdos_rlock_take(&guard_lock, false);
    if (g[0] != 0) {
        zdos_rlock_give(&guard_lock);
        return 0;
    }
    if (g[1] != 0) { /* only this thread can be making it: its own constructor */
        fputs("Recursive initialization of a static local\n", stderr);
        abort();
    }
    g[1] = 1;
    return 1;
}

void __cxa_guard_release(uint64_t *guard) {
    volatile uint8_t *g = (volatile uint8_t *)guard;
    g[1] = 0;
    __atomic_store_n(&g[0], 1, __ATOMIC_RELEASE);
    zdos_rlock_give(&guard_lock);
}

void __cxa_guard_abort(uint64_t *guard) {
    ((volatile uint8_t *)guard)[1] = 0;
    zdos_rlock_give(&guard_lock);
}

void __cxa_pure_virtual(void) {
    fputs("Pure virtual function called\n", stderr);
    abort();
}

void __cxa_deleted_virtual(void) {
    fputs("Deleted virtual function called\n", stderr);
    abort();
}
