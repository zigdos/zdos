/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): the application's state */
#ifndef _SDL_active_h
#define _SDL_active_h

#include "SDL_stdinc.h"

#define SDL_APPMOUSEFOCUS 0x01
#define SDL_APPINPUTFOCUS 0x02
#define SDL_APPACTIVE 0x04

#ifdef __cplusplus
extern "C" {
#endif
Uint8 SDL_GetAppState(void);
#ifdef __cplusplus
}
#endif

#endif
