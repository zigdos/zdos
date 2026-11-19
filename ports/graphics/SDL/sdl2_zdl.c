/* SDL2.ZDL's export table: the slot count, then SDL's functions in the order
 * of its dynamic API (src/dynapi/SDL_dynapi_procs.h, which only grows at its
 * end), as ZDOS's configuration selects them; build.sh makes the import stubs
 * (libSDL2.a) from the same list. A copy per program. */
#include <stdint.h>
#include "SDL.h"
#include "SDL_syswm.h"
#include "SDL_vulkan.h"

/* The version for ZDOS: SDL_version.h's, expanded before
 * ZDOS_FILE_VERSION's # */
#include "zdos.h"
#define ZDL_VERSION(a, b, c) ZDOS_FILE_VERSION(a, b, c, 0)
#define ZDL_VERSION_OF(a, b, c) ZDL_VERSION(a, b, c)
ZDL_VERSION_OF(SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);

#define SDL_DYNAPI_PROC(rc, fn, params, args, ret) +1
enum { zdos_sdl2_count = 0
#include "dynapi/SDL_dynapi_procs.h"
};
#undef SDL_DYNAPI_PROC

#define SDL_DYNAPI_PROC(rc, fn, params, args, ret) (const void *)fn,
const void *const zdos_library[] = {
    (const void *)(uintptr_t)zdos_sdl2_count,
#include "dynapi/SDL_dynapi_procs.h"
};
#undef SDL_DYNAPI_PROC
