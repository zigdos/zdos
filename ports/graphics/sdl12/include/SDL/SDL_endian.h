/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): byte order (ZDOS's CPUs
   are little-endian) */
#ifndef _SDL_endian_h
#define _SDL_endian_h

#include "SDL_stdinc.h"

#define SDL_LIL_ENDIAN 1234
#define SDL_BIG_ENDIAN 4321
#define SDL_BYTEORDER SDL_LIL_ENDIAN

static inline Uint16 SDL_Swap16(Uint16 x) { return (Uint16)(x << 8 | x >> 8); }
static inline Uint32 SDL_Swap32(Uint32 x) { return __builtin_bswap32(x); }
static inline Uint64 SDL_Swap64(Uint64 x) { return __builtin_bswap64(x); }

#define SDL_SwapLE16(X) (X)
#define SDL_SwapLE32(X) (X)
#define SDL_SwapLE64(X) (X)
#define SDL_SwapBE16(X) SDL_Swap16(X)
#define SDL_SwapBE32(X) SDL_Swap32(X)
#define SDL_SwapBE64(X) SDL_Swap64(X)

#endif
