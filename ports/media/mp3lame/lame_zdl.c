/* MP3LAME.ZDL's export table, from libmp3lame.sym; declared here, as
 * only their addresses are taken */
#include "libmp3lame/version.h"

/* The version for ZDOS: libmp3lame/version.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(LAME_MAJOR_VERSION, LAME_MINOR_VERSION, LAME_PATCH_VERSION);

#define ZDOS_EXPORTS "exports.def"
#define ZDOS_EXPORTS_DECLARE 1
#include "zdos_exports.h"
