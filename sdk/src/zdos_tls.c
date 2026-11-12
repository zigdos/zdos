/* thread_local: each thread's block made from the template the
 * linker scripts place (.tdata, then .tbss zeroed), where the
 * compiler finds it from the thread pointer: x86 just below it, the
 * word at it pointing to itself; ARM64 after a 16-byte header
 * (padded to the 64-byte alignment). */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "zdos.h"
#include "zdos_internal.h"

extern char __tdata_start[], __tdata_end[], __tbss_end[];

#define TLS_ALIGN 64 /* the linker scripts' alignment of .tdata and .tbss */

static size_t tls_size(void) {
    return (size_t)(__tbss_end - __tdata_start);
}

static size_t block_size(void) {
    return (tls_size() + TLS_ALIGN - 1) & ~(size_t)(TLS_ALIGN - 1);
}

/* A new thread's block: its thread pointer, or NULL (no thread_local data,
   no memory) */
void *zdos_tls_create(void) {
    size_t size = tls_size();
    if (size == 0) return NULL;
    size_t init = (size_t)(__tdata_end - __tdata_start);
    size_t block = block_size();
    char *m = aligned_alloc(TLS_ALIGN, block + TLS_ALIGN);
    if (m == NULL) return NULL;
#if defined(__aarch64__)
    memset(m, 0, TLS_ALIGN);
    memcpy(m + TLS_ALIGN, __tdata_start, init);
    memset(m + TLS_ALIGN + init, 0, size - init);
    return m;
#else
    memcpy(m, __tdata_start, init);
    memset(m + init, 0, block - init);
    void **self = (void **)(m + block);
    self[0] = self;
    return self;
#endif
}

void zdos_tls_free(void *tp) {
    if (tp == NULL) return;
#if defined(__aarch64__)
    free(tp);
#else
    free((char *)tp - block_size());
#endif
}

/* The calling thread's block, made and set (start-up and new threads) */
void *zdos_tls_start(void) {
    void *tp = zdos_tls_create();
    if (tp != NULL) zdos->threads->set_thread_pointer((uintptr_t)tp);
    return tp;
}
