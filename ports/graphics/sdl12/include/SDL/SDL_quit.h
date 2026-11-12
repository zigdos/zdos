/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12) */
#ifndef _SDL_quit_h
#define _SDL_quit_h
#include "SDL_events.h"
#define SDL_QuitRequested() (SDL_PumpEvents(), SDL_PeepEvents(NULL, 0, SDL_PEEKEVENT, SDL_QUITMASK))
#endif
