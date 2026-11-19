/* FREETYPE.ZDL's export table: FreeType's functions in the order of
 * exports.def (the import stubs, libfreetype.a, follow it).
 * One copy for every program: FreeType keeps its state in what
 * callers make (FT_Library, FT_Face), and ftsystem-zdos.c opens
 * files with their handles. */
#include <ft2build.h>
#include FT_FREETYPE_H
#include <freetype/ftadvanc.h>
#include <freetype/ftbbox.h>
#include <freetype/ftbdf.h>
#include <freetype/ftbitmap.h>
#include <freetype/ftbzip2.h>
#include <freetype/ftcache.h>
#include <freetype/ftcid.h>
#include <freetype/ftcolor.h>
#include <freetype/ftdriver.h>
#include <freetype/ftfntfmt.h>
#include <freetype/ftgasp.h>
#include <freetype/ftglyph.h>
#include <freetype/ftgxval.h>
#include <freetype/ftgzip.h>
#include <freetype/ftincrem.h>
#include <freetype/ftlcdfil.h>
#include <freetype/ftlist.h>
#include <freetype/ftlogging.h>
#include <freetype/ftlzw.h>
#include <freetype/ftmm.h>
#include <freetype/ftmodapi.h>
#include <freetype/ftotval.h>
#include <freetype/ftoutln.h>
#include <freetype/ftparams.h>
#include <freetype/ftpfr.h>
#include <freetype/ftrender.h>
#include <freetype/ftsizes.h>
#include <freetype/ftsnames.h>
#include <freetype/ftstroke.h>
#include <freetype/ftsynth.h>
#include <freetype/ftsystem.h>
#include <freetype/fttrigon.h>
#include <freetype/ftwinfnt.h>
#include <freetype/otsvg.h>
#include <freetype/t1tables.h>
#include <freetype/ttnameid.h>
#include <freetype/tttables.h>

/* The version for ZDOS: freetype.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(FREETYPE_MAJOR, FREETYPE_MINOR, FREETYPE_PATCH);

const unsigned char zdos_library_shared = 1;

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
