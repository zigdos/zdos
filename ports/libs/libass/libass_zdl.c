/* LIBASS.ZDL's export table: libass's functions in the order of
 * exports.def (the import stubs, libass.a, follow it). */
#include <ass.h>

/* LIBASS_VERSION's digits, 0x01705000 for 0.17.5 */
#define ASS_DIGITS(x) ((((x) >> 4) & 15) * 10 + ((x) & 15))
/* The version for ZDOS: ass.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF((LIBASS_VERSION >> 28), ASS_DIGITS(LIBASS_VERSION >> 20), ASS_DIGITS(LIBASS_VERSION >> 12));

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
