/* SHNBIDI.ZDL's export table: the functions of fribidi_sheen.c in the
 * order of exports.def (the import stubs, libsheenbidi.a, follow it). */
#include "fribidi.h"
#include <SheenBidi/SBVersion.h>

/* The version for ZDOS: SheenBidi's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(SHEENBIDI_VERSION_MAJOR, SHEENBIDI_VERSION_MINOR, SHEENBIDI_VERSION_PATCH);

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
