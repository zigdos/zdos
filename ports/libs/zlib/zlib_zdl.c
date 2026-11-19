/* ZLIB.ZDL's export table: zlib's functions in the order of exports.def
 * (the import stubs, libz.a, follow it). A copy per program: gz* use the C
 * library linked into the library (its descriptors). */
#include "zlib.h"

/* zlib.h declares these only for large-file systems; zlib has them always */
#ifndef Z_LARGE64
ZEXTERN gzFile ZEXPORT gzopen64(const char *, const char *);
ZEXTERN z_off64_t ZEXPORT gzseek64(gzFile, z_off64_t, int);
ZEXTERN z_off64_t ZEXPORT gztell64(gzFile);
ZEXTERN z_off64_t ZEXPORT gzoffset64(gzFile);
ZEXTERN uLong ZEXPORT adler32_combine64(uLong, uLong, z_off64_t);
ZEXTERN uLong ZEXPORT crc32_combine64(uLong, uLong, z_off64_t);
ZEXTERN uLong ZEXPORT crc32_combine_gen64(z_off64_t);
#endif

/* The version for ZDOS: zlib.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(ZLIB_VER_MAJOR, ZLIB_VER_MINOR, ZLIB_VER_REVISION);

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
