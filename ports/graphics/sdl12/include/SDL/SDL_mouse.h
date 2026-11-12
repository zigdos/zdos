/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): the mouse (ZDOS draws no
   pointer: an arrow is drawn into the picture while it is shown) */
#ifndef _SDL_mouse_h
#define _SDL_mouse_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_video.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WMcursor WMcursor;
typedef struct SDL_Cursor {
    SDL_Rect area;
    Sint16 hot_x, hot_y;
    Uint8 *data;
    Uint8 *mask;
    Uint8 *save[2];
    WMcursor *wm_cursor;
} SDL_Cursor;

Uint8 SDL_GetMouseState(int *x, int *y);
Uint8 SDL_GetRelativeMouseState(int *x, int *y);
void SDL_WarpMouse(Uint16 x, Uint16 y);
SDL_Cursor *SDL_CreateCursor(Uint8 *data, Uint8 *mask, int w, int h, int hot_x, int hot_y);
void SDL_SetCursor(SDL_Cursor *cursor);
SDL_Cursor *SDL_GetCursor(void);
void SDL_FreeCursor(SDL_Cursor *cursor);
int SDL_ShowCursor(int toggle);

#define SDL_BUTTON(X) (1 << ((X) - 1))
#define SDL_BUTTON_LEFT 1
#define SDL_BUTTON_MIDDLE 2
#define SDL_BUTTON_RIGHT 3
#define SDL_BUTTON_WHEELUP 4
#define SDL_BUTTON_WHEELDOWN 5
#define SDL_BUTTON_X1 6
#define SDL_BUTTON_X2 7
#define SDL_BUTTON_LMASK SDL_BUTTON(SDL_BUTTON_LEFT)
#define SDL_BUTTON_MMASK SDL_BUTTON(SDL_BUTTON_MIDDLE)
#define SDL_BUTTON_RMASK SDL_BUTTON(SDL_BUTTON_RIGHT)
#define SDL_BUTTON_X1MASK SDL_BUTTON(SDL_BUTTON_X1)
#define SDL_BUTTON_X2MASK SDL_BUTTON(SDL_BUTTON_X2)

#ifdef __cplusplus
}
#endif

#endif
