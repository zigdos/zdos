/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): the keyboard */
#ifndef _SDL_keyboard_h
#define _SDL_keyboard_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_keysym.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SDL_keysym {
    Uint8 scancode; /* the USB HID usage on ZDOS */
    SDLKey sym;
    SDLMod mod;
    Uint16 unicode; /* with SDL_EnableUNICODE(1) */
} SDL_keysym;

#define SDL_ALL_HOTKEYS 0xFFFFFFFF

int SDL_EnableUNICODE(int enable);

#define SDL_DEFAULT_REPEAT_DELAY 500
#define SDL_DEFAULT_REPEAT_INTERVAL 30
/* ZDOS repeats keys at the keyboard's rate: delay 0 turns repeats off,
   anything else on */
int SDL_EnableKeyRepeat(int delay, int interval);
void SDL_GetKeyRepeat(int *delay, int *interval);

Uint8 *SDL_GetKeyState(int *numkeys);
SDLMod SDL_GetModState(void);
void SDL_SetModState(SDLMod modstate);
char *SDL_GetKeyName(SDLKey key);

#ifdef __cplusplus
}
#endif

#endif
