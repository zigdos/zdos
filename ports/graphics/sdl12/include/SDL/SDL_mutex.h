/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): mutexes (recursive),
   semaphores and conditions, on the C library's pthreads */
#ifndef _SDL_mutex_h
#define _SDL_mutex_h

#include "SDL_stdinc.h"
#include "SDL_error.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SDL_MUTEX_TIMEDOUT 1
#define SDL_MUTEX_MAXWAIT (~(Uint32)0)

struct SDL_mutex;
typedef struct SDL_mutex SDL_mutex;
SDL_mutex *SDL_CreateMutex(void);
#define SDL_LockMutex(m) SDL_mutexP(m)
int SDL_mutexP(SDL_mutex *mutex);
#define SDL_UnlockMutex(m) SDL_mutexV(m)
int SDL_mutexV(SDL_mutex *mutex);
void SDL_DestroyMutex(SDL_mutex *mutex);

struct SDL_semaphore;
typedef struct SDL_semaphore SDL_sem;
SDL_sem *SDL_CreateSemaphore(Uint32 initial_value);
void SDL_DestroySemaphore(SDL_sem *sem);
int SDL_SemWait(SDL_sem *sem);
int SDL_SemTryWait(SDL_sem *sem);
int SDL_SemWaitTimeout(SDL_sem *sem, Uint32 ms);
int SDL_SemPost(SDL_sem *sem);
Uint32 SDL_SemValue(SDL_sem *sem);

struct SDL_cond;
typedef struct SDL_cond SDL_cond;
SDL_cond *SDL_CreateCond(void);
void SDL_DestroyCond(SDL_cond *cond);
int SDL_CondSignal(SDL_cond *cond);
int SDL_CondBroadcast(SDL_cond *cond);
int SDL_CondWait(SDL_cond *cond, SDL_mutex *mut);
int SDL_CondWaitTimeout(SDL_cond *cond, SDL_mutex *mutex, Uint32 ms);

#ifdef __cplusplus
}
#endif

#endif
