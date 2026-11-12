/* DGen/SDL's configuration for ZDOS, instead of its configure script's
   -D flags (given to every source with -include): the C cores (Musashi,
   CZ80), sound, threads, the scale2x and "Crap TV" filters; no assembler,
   OpenGL, joysticks, libarchive or debugger, and no hqx (its 64 MB lookup
   table is static) */
#define PACKAGE "dgen-sdl"
#define VERSION "1.33"
#define NDEBUG 1
#define HAVE_FTELLO 1
#define HAVE_GLOB_H 1
#define HAVE_SDL_WM_TOGGLEFULLSCREEN 1
#define WITH_MUSA 1
#define WITH_CZ80 1
#define WITH_THREADS 1
#define WITH_CTV 1
#define WITH_SCALE2X 1
/* glibc's string.h declares strcasecmp and strncasecmp; here strings.h */
#include <strings.h>
