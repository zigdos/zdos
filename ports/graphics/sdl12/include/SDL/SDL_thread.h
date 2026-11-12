/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): threads, as pthreads
   (preemptive on the metal editions, cooperative on UEFI and BIOS) */
#ifndef _SDL_thread_h
#define _SDL_thread_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_mutex.h"

#ifdef __cplusplus
extern "C" {
#endif

struct SDL_Thread;
typedef struct SDL_Thread SDL_Thread;

SDL_Thread *SDL_CreateThread(int (*fn)(void *), void *data);
Uint32 SDL_ThreadID(void);
Uint32 SDL_GetThreadID(SDL_Thread *thread);
void SDL_WaitThread(SDL_Thread *thread, int *status);
/* Not supported (no cancellation): waits for it instead */
void SDL_KillThread(SDL_Thread *thread);

#ifdef __cplusplus
}
#endif

#endif
