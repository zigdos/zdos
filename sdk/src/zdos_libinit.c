/* Start-up of C libraries (.ZDL, sdk/linkers/lib-*.ld), in
 * place of zdos_crt0.c: zdos_library_init sets zdos, loads the
 * libraries this one imports and runs its global constructors.
 * Run once per load. A program's C runtime found in
 * threads->local() becomes this library's host, unless the
 * library is shared: that one copy serves every program. */
#include <stdbool.h>
#include <stdint.h>
#include "zdos.h"
#include "zdos_internal.h"

typedef void (*zdos_init_fn)(void);
extern zdos_init_fn __init_array_start[];
extern zdos_init_fn __init_array_end[];
/* The library's header: flags at byte 64, 1 shared */
extern const unsigned char __zdos_header[];

ZDOS_CALL bool zdos_library_init(const zdos_start *start) {
    zdos_init(start);
    zdos_library_one_copy = (__zdos_header[64] & 1) != 0;
    // The loading program's C runtime, if it offers one: threads, keys and
    // errno are then its (zdos_internal.h);
    // libraries this one imports get it too
    uintptr_t host = zdos->threads->local();
    if (!zdos_library_one_copy && host != 0 && *(const uint64_t *)host == ZDOS_RUNTIME_MAGIC) {
        zdos_runtime_host = (const zdos_runtime *)host;
        zdos_threads_started = true; /* the program's threads call in */
    }
    if (!zdos_load_imports_offering(zdos_runtime_host != NULL ? NULL : zdos_imports_runtime())) return false;
    for (zdos_init_fn *f = __init_array_start; f < __init_array_end; ++f) {
        (*f)();
    }
    return true;
}
