/* WEBP.ZDL's export table, in the order of exports.def; declared
 * here, as only their addresses are taken */

/* The version for ZDOS: src/dec/vp8i_dec.h's (build.sh; the header
 * declares what exports.def does), expanded before ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(ZDOS_WEBP_MAJOR, ZDOS_WEBP_MINOR, ZDOS_WEBP_PATCH);

/* One copy for every program: its state is in what callers make
 * (decoders, pictures), its tables the same for all */
const unsigned char zdos_library_shared = 1;

#define ZDOS_EXPORTS "exports.def"
#define ZDOS_EXPORTS_DECLARE 1
#include "zdos_exports.h"
