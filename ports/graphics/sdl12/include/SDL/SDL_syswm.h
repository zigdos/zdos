/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): no window system to tell
   about; SDL_GetWMInfo returns 0 */
#ifndef _SDL_syswm_h
#define _SDL_syswm_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_version.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SDL_SysWMinfo {
    SDL_version version;
    int data;
} SDL_SysWMinfo;

int SDL_GetWMInfo(SDL_SysWMinfo *info);

#ifdef __cplusplus
}
#endif

#endif
