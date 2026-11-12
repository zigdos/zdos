/* Shared by the partial SDL 1.2's sources */
#ifndef SDL12_INTERNAL_H
#define SDL12_INTERNAL_H

#include "SDL.h"

void SDL12_VideoQuit(void);
void SDL12_AudioQuit(void);
void SDL12_TimerQuit(void);
/* The pointer's place and whether it is drawn, for SDL_Flip */
void SDL12_MouseCursor(int *x, int *y, int *shown);

#endif
