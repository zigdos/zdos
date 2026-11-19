/* libass's config.h for ZDOS (its meson.build's checks, answered): C
 * only, no fontconfig, iconv or libpng; fonts by ass_zdosfonts.c, line
 * breaking by linebreak.zig (libunibreak's interface) */
#define HAVE_STRDUP 1
#define HAVE_STRNDUP 1
#define HAVE_FSTAT 1
#define CONFIG_LARGE_TILES 0
#define CONFIG_SOURCEVERSION "ZDOS port"
#define CONFIG_UNIBREAK 1
#define CONFIG_ZDOS_FONTS 1 /* ass_zdosfonts.c: C:\SYSTEM\TTF (libass-zdos.patch) */
