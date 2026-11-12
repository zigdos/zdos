/* A library's export table (docs/ZDL.md)
 * from a list of X(function) lines, in slot order (only ever
 * add at the end): #define ZDOS_EXPORTS "exports.def"
 * #include "zdos_exports.h" gives zdos_library: the slot
 * count, then the functions. The list is looked for on the
 * include path (-I its folder). ZDOS_EXPORTS_DECLARE:
 * each declared as void f(void) first, when no header of the
 * library is included (only the addresses are taken).
 * zdos-stubs makes the import stubs from the same list. */
#include <stdint.h>

#ifdef ZDOS_EXPORTS_DECLARE
#define X(f) extern void f(void);
#include ZDOS_EXPORTS
#undef X
#endif

#define X(f) +1
enum { zdos_exports_count_ = 0
#include ZDOS_EXPORTS
};
#undef X

#define X(f) (const void *)f,
const void *const zdos_library[] = {
    (const void *)(uintptr_t)zdos_exports_count_,
#include ZDOS_EXPORTS
};
#undef X
