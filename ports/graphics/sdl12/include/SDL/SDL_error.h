/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): errors */
#ifndef _SDL_error_h
#define _SDL_error_h

#include "SDL_stdinc.h"

#ifdef __cplusplus
extern "C" {
#endif

void SDL_SetError(const char *fmt, ...);
char *SDL_GetError(void);
void SDL_ClearError(void);

typedef enum { SDL_ENOMEM, SDL_EFREAD, SDL_EFWRITE, SDL_EFSEEK, SDL_UNSUPPORTED, SDL_LASTERROR } SDL_errorcode;
void SDL_Error(SDL_errorcode code);
#define SDL_OutOfMemory() SDL_Error(SDL_ENOMEM)
#define SDL_Unsupported() SDL_Error(SDL_UNSUPPORTED)

#ifdef __cplusplus
}
#endif

#endif
