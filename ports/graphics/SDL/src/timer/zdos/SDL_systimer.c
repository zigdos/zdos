/*
  Simple DirectMedia Layer: time on ZDOS, from its millisecond clock. SDL_Delay
  is time->sleep, which Ctrl+C ends (nanosleep doesn't), so a program that
  only waits and plays sound can still be stopped.

  This software is provided 'as-is', under the zlib license (LICENSE.txt in
  SDL's sources).
*/
#include "../../SDL_internal.h"

#ifdef SDL_TIMER_ZDOS

#include "SDL_timer.h"

#include "zdos.h"

static SDL_bool ticks_started = SDL_FALSE;
static Uint64 start;

void SDL_TicksInit(void)
{
    if (ticks_started) {
        return;
    }
    ticks_started = SDL_TRUE;
    start = zdos->time->millis();
}

void SDL_TicksQuit(void)
{
    ticks_started = SDL_FALSE;
}

Uint64 SDL_GetTicks64(void)
{
    if (!ticks_started) {
        SDL_TicksInit();
    }
    return zdos->time->millis() - start;
}

Uint64 SDL_GetPerformanceCounter(void)
{
    return zdos->time->millis();
}

Uint64 SDL_GetPerformanceFrequency(void)
{
    return 1000;
}

void SDL_Delay(Uint32 ms)
{
    zdos->time->sleep(ms);
}

#endif /* SDL_TIMER_ZDOS */
