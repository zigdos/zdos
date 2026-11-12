/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): time and timers (the
   timers' callbacks run on one thread of their own) */
#ifndef _SDL_timer_h
#define _SDL_timer_h

#include "SDL_stdinc.h"
#include "SDL_error.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SDL_TIMESLICE 10
#define TIMER_RESOLUTION 10

Uint32 SDL_GetTicks(void);
void SDL_Delay(Uint32 ms);

typedef Uint32 (*SDL_TimerCallback)(Uint32 interval);
int SDL_SetTimer(Uint32 interval, SDL_TimerCallback callback);

typedef Uint32 (*SDL_NewTimerCallback)(Uint32 interval, void *param);
typedef struct _SDL_TimerID *SDL_TimerID;
SDL_TimerID SDL_AddTimer(Uint32 interval, SDL_NewTimerCallback callback, void *param);
SDL_bool SDL_RemoveTimer(SDL_TimerID t);

#ifdef __cplusplus
}
#endif

#endif
