/* HARFBUZZ.ZDL's export table: HarfBuzz's functions in the order of
 * exports.def (the import stubs, libharfbuzz.a, follow it). */
#include <hb.h>
#include <hb-ot.h>
#include <hb-ft.h>

/* The version for ZDOS: hb-version.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(HB_VERSION_MAJOR, HB_VERSION_MINOR, HB_VERSION_MICRO);

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
