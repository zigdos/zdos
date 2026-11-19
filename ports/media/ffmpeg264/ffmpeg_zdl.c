/* FFMPEG9.ZDL's export table, in the order of exports.def; declared
 * here, as only their addresses are taken */
#include <stdint.h>
#include "x264.h"

/* Imports cover functions, not data: FFmpeg reads this x264 table
 * directly, so it comes from x264's source. */
#include "x264_levels.inc"

/* The version for ZDOS: RELEASE's (build.sh), expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(ZDOS_FFMPEG_MAJOR, ZDOS_FFMPEG_MINOR, ZDOS_FFMPEG_PATCH);

#define ZDOS_EXPORTS "exports.def"
#define ZDOS_EXPORTS_DECLARE 1
#include "zdos_exports.h"
