/*
  Simple DirectMedia Layer: the ZDOS audio backend, on the API's group sound
  (a sound card's driver, HDA.SYS ...). SDL's audio thread mixes into a
  buffer and writes it with sound->write, then sleeps to its next period
  (a buffer's time, absolute deadlines, as WASAPI's events), keeping the
  card's queue TARGET deep, as the SDK's audio does. Uneven
  reads by the card (QEMU's AC'97) and late callbacks (a player decoding)
  stay in that queue. 8-bit unsigned or 16-bit signed, mono or stereo,
  8000-192000 Hz; SDL converts the rest.

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

/* The queue kept: 2 buffers (what players such as ffplay take SDL's
   latency to be), at least TARGET_MS */
#define TARGET_BUFFERS 2
#define TARGET_MS 60

struct SDL_PrivateAudioData
{
    int handle;
    Uint8 *mixbuf;
    Uint64 period; /* nanoseconds */
    Uint64 next;   /* the next period's deadline */
    size_t target; /* bytes queued at the card */
};

static void ZDOSAUDIO_PlayDevice(SDL_AudioDevice *_this);

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
    h->period = (Uint64)_this->spec.samples * 1000000000u / (Uint64)_this->spec.freq;
    {
        const size_t frame = (size_t)_this->spec.channels * (size_t)(bits / 8);
        const size_t floor = (size_t)_this->spec.freq * TARGET_MS / 1000 * frame;
        const size_t buffers = (size_t)TARGET_BUFFERS * _this->spec.size;
        h->target = buffers > floor ? buffers : floor;
    }
    /* Silence to TARGET: the queue the periods then keep */
    while (SDL_AtomicGet(&_this->enabled) && zdos->sound->queued(h->handle) < h->target) {
        ZDOSAUDIO_PlayDevice(_this); /* a failed write disables the device */
    }
    h->next = zdos->time->nanos();
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

static SDL_bool ZDOSAUDIO_Running(SDL_AudioDevice *_this)
{
    return SDL_AtomicGet(&_this->enabled) && !SDL_AtomicGet(&_this->shutdown);
}

static void ZDOSAUDIO_WaitDevice(SDL_AudioDevice *_this)
{
    struct SDL_PrivateAudioData *h = _this->hidden;
    int extra;

    /* A period at a time; a buffer is written after one unless the
       card's queue is deep already (its clock slower than ours). A card
       that stops playing: no longer than 8 periods */
    for (extra = 0; ZDOSAUDIO_Running(_this) && extra < 8; extra++) {
        const size_t q = zdos->sound->queued(h->handle);
        Uint64 now;

        /* Below TARGET (the card's clock faster than ours): the next
           period an eighth sooner, so the queue stays at TARGET; below
           half (a stall), twice the pace, never in a burst */
        h->next += q < h->target / 2 ? h->period / 2 : q < h->target ? h->period - h->period / 8 : h->period;
        now = zdos->time->nanos();
        if (h->next + h->period < now) {
            h->next = now; /* late by more than a period: on from now */
        }
        while (ZDOSAUDIO_Running(_this) && zdos->time->nanos() < h->next) {
            zdos->time->nap_until(h->next);
        }
        if (zdos->sound->queued(h->handle) < h->target + _this->spec.size) {
            return;
        }
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
