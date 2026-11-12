/* FFMPEG9.ZDL's export table, in the order of exports.def; declared
 * here, as only their addresses are taken */
#include <stdint.h>
#include "x264.h"

/* Imports cover functions, not data: FFmpeg reads this x264 table
 * directly, so it comes from x264's source. */
#include "x264_levels.inc"

#define ZDOS_EXPORTS "exports.def"
#define ZDOS_EXPORTS_DECLARE 1
#include "zdos_exports.h"
