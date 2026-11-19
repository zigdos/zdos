/* X264.ZDL's export table, in the order of exports.def */
#include <stdint.h>
#include "x264.h"

/* The version for ZDOS: x264.h's X264_BUILD (x264 0.165), expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(0, X264_BUILD, 0);

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
