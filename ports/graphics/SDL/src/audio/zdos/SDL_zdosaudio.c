/*
  Simple DirectMedia Layer: the ZDOS audio backend, on the API's group sound
  (a sound card's driver, HDA.SYS ...). SDL's audio thread mixes into a
  buffer and writes it with sound->write, then waits until at most one such
  buffer is queued: the card's queue holds about a third of a second, and
  players (ffplay) take SDL's latency to be about two buffers. 8-bit unsigned
  or 16-bit signed, mono or stereo, 8000-192000 Hz; SDL converts the rest.

  This software is provided 'as-is', under the zlib license (LICENSE.txt in
  SDL's sources).
*/
#include "../../SDL_internal.h"

#ifdef SDL_AUDIO_DRIVER_ZDOS

#include "SDL_audio.h"
#include "SDL_timer.h"
#include "../SDL_audio_c.h"
#include "../SDL_sysaudio.h"

#include "zdos.h"

struct SDL_PrivateAudioData
{
    int handle;
    Uint8 *mixbuf;
};

static int ZDOSAUDIO_OpenDevice(SDL_AudioDevice *_this, const char *devname)
{
    struct SDL_PrivateAudioData *h;
    int bits;

    h = (struct SDL_PrivateAudioData *)SDL_calloc(1, sizeof(*h));
    if (!h) {
        return SDL_OutOfMemory();
    }
    _this->hidden = h;
    if (SDL_AUDIO_BITSIZE(_this->spec.format) == 8) {
        _this->spec.format = AUDIO_U8;
        bits = 8;
    } else {
        _this->spec.format = AUDIO_S16LSB;
        bits = 16;
    }
    if (_this->spec.channels > 2) {
        _this->spec.channels = 2;
    }
    if (_this->spec.freq < 8000) {
        _this->spec.freq = 8000;
    } else if (_this->spec.freq > 192000) {
        _this->spec.freq = 192000;
    }
    h->handle = zdos->sound->open((uint32_t)_this->spec.freq, _this->spec.channels, (uint32_t)bits);
    if (h->handle < 0) {
        return SDL_SetError("No sound: %s", zdos_error_message(zdos->programs->last_error()));
    }
    SDL_CalculateAudioSpec(&_this->spec);
    h->mixbuf = (Uint8 *)SDL_malloc(_this->spec.size);
    if (!h->mixbuf) {
        return SDL_OutOfMemory();
    }
    SDL_memset(h->mixbuf, _this->spec.silence, _this->spec.size);
    return 0;
}

static void ZDOSAUDIO_PlayDevice(SDL_AudioDevice *_this)
{
    struct SDL_PrivateAudioData *h = _this->hidden;
    Uint32 done = 0;

    while (done < _this->spec.size) {
        intptr_t n = zdos->sound->write(h->handle, h->mixbuf + done, _this->spec.size - done);
        if (n < 0) {
            SDL_OpenedAudioDeviceDisconnected(_this);
            return;
        }
        done += (Uint32)n;
    }
}

static void ZDOSAUDIO_WaitDevice(SDL_AudioDevice *_this)
{
    struct SDL_PrivateAudioData *h = _this->hidden;
    const Uint32 start = SDL_GetTicks();

    /* a card that stops playing: no longer than the queue lasts */
    while (SDL_AtomicGet(&_this->enabled) && !SDL_AtomicGet(&_this->shutdown) &&
           zdos->sound->queued(h->handle) > _this->spec.size && SDL_GetTicks() - start < 500) {
        SDL_Delay(1);
    }
}

static Uint8 *ZDOSAUDIO_GetDeviceBuf(SDL_AudioDevice *_this)
{
    return _this->hidden->mixbuf;
}

static void ZDOSAUDIO_CloseDevice(SDL_AudioDevice *_this)
{
    struct SDL_PrivateAudioData *h = _this->hidden;

    if (h->handle >= 0) {
        zdos->sound->close(h->handle, SDL_TRUE);
    }
    SDL_free(h->mixbuf);
    SDL_free(h);
}

static int ZDOSAUDIO_GetDefaultAudioInfo(char **name, SDL_AudioSpec *spec, int iscapture)
{
    if (iscapture) {
        return SDL_Unsupported();
    }
    if (name) {
        *name = SDL_strdup("ZDOS sound");
    }
    SDL_zerop(spec);
    spec->freq = 48000; /* what the cards play; other rates are resampled */
    spec->format = AUDIO_S16LSB;
    spec->channels = 2;
    return 0;
}

static SDL_bool ZDOSAUDIO_Init(SDL_AudioDriverImpl *impl)
{
    /* Without a card's driver: not available, SDL takes the next driver */
    int32_t v = zdos->sound->volume();
    if (v < 0) {
        SDL_SetError("No sound card");
        return SDL_FALSE;
    }
    impl->OpenDevice = ZDOSAUDIO_OpenDevice;
    impl->PlayDevice = ZDOSAUDIO_PlayDevice;
    impl->WaitDevice = ZDOSAUDIO_WaitDevice;
    impl->GetDeviceBuf = ZDOSAUDIO_GetDeviceBuf;
    impl->CloseDevice = ZDOSAUDIO_CloseDevice;
    impl->GetDefaultAudioInfo = ZDOSAUDIO_GetDefaultAudioInfo;
    impl->OnlyHasDefaultOutputDevice = SDL_TRUE;
    impl->SupportsNonPow2Samples = SDL_TRUE;
    return SDL_TRUE;
}

AudioBootStrap ZDOSAUDIO_bootstrap = {
    "zdos", "ZDOS sound", ZDOSAUDIO_Init, SDL_FALSE
};

#endif /* SDL_AUDIO_DRIVER_ZDOS */
