/* ZDOS's partial SDL 1.2 (ports/graphics/sdl12): audio, on zdos_media.h's
   sound thread (the callback runs there) */
#ifndef _SDL_audio_h
#define _SDL_audio_h

#include "SDL_stdinc.h"
#include "SDL_error.h"
#include "SDL_endian.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SDL_AudioSpec {
    int freq;
    Uint16 format;
    Uint8 channels;
    Uint8 silence;
    Uint16 samples;
    Uint16 padding;
    Uint32 size;
    void (*callback)(void *userdata, Uint8 *stream, int len);
    void *userdata;
} SDL_AudioSpec;

#define AUDIO_U8 0x0008
#define AUDIO_S8 0x8008
#define AUDIO_U16LSB 0x0010
#define AUDIO_S16LSB 0x8010
#define AUDIO_U16MSB 0x1010
#define AUDIO_S16MSB 0x9010
#define AUDIO_U16 AUDIO_U16LSB
#define AUDIO_S16 AUDIO_S16LSB
#define AUDIO_U16SYS AUDIO_U16LSB
#define AUDIO_S16SYS AUDIO_S16LSB

int SDL_AudioInit(const char *driver_name);
void SDL_AudioQuit(void);
char *SDL_AudioDriverName(char *namebuf, int maxlen);
/* Starts paused (SDL_PauseAudio(0) plays). The rate is the card's driver's
   to convert; obtained NULL: the formats above are converted to what the
   card takes (8-bit unsigned, 16-bit signed) */
int SDL_OpenAudio(SDL_AudioSpec *desired, SDL_AudioSpec *obtained);

typedef enum {
    SDL_AUDIO_STOPPED = 0,
    SDL_AUDIO_PLAYING,
    SDL_AUDIO_PAUSED
} SDL_audiostatus;
SDL_audiostatus SDL_GetAudioStatus(void);
void SDL_PauseAudio(int pause_on);

#define SDL_MIX_MAXVOLUME 128
void SDL_MixAudio(Uint8 *dst, const Uint8 *src, Uint32 len, int volume);

void SDL_LockAudio(void);
void SDL_UnlockAudio(void);
void SDL_CloseAudio(void);

#ifdef __cplusplus
}
#endif

#endif
