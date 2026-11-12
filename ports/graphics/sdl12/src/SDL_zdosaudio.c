/* The partial SDL 1.2's audio: the callback fills zdos_media.h's sound
   buffer on its thread; formats the card doesn't take (it takes 8-bit
   unsigned and 16-bit signed little-endian) are converted in place */
#include "sdl12_internal.h"

#include "zdos.h"
#include "zdos_media.h"

static struct {
    int open, paused;
    SDL_AudioSpec spec;
} au;

static void fill(void *user, uint8_t *buf, size_t len)
{
    (void)user;
    if (au.paused) {
        memset(buf, au.spec.format == AUDIO_U8 || au.spec.format == AUDIO_S8 ? 0x80 : 0, len);
        return;
    }
    memset(buf, au.spec.silence, len);
    au.spec.callback(au.spec.userdata, buf, (int)len);
    switch (au.spec.format) {
    case AUDIO_S8:
        for (size_t i = 0; i < len; i++) buf[i] ^= 0x80;
        break;
    case AUDIO_U16LSB:
        for (size_t i = 1; i < len; i += 2) buf[i] ^= 0x80;
        break;
    case AUDIO_S16MSB:
    case AUDIO_U16MSB:
        for (size_t i = 0; i + 1 < len; i += 2) {
            uint8_t t = buf[i];
            buf[i] = buf[i + 1];
            buf[i + 1] = (uint8_t)(au.spec.format == AUDIO_U16MSB ? t ^ 0x80 : t);
        }
        break;
    }
}

int SDL_AudioInit(const char *driver_name)
{
    (void)driver_name;
    return 0;
}

void SDL_AudioQuit(void) { SDL_CloseAudio(); }
void SDL12_AudioQuit(void) { SDL_CloseAudio(); }

char *SDL_AudioDriverName(char *namebuf, int maxlen)
{
    if (namebuf == NULL || maxlen <= 0) return NULL;
    SDL_strlcpy(namebuf, "zdos", (size_t)maxlen);
    return namebuf;
}

int SDL_OpenAudio(SDL_AudioSpec *desired, SDL_AudioSpec *obtained)
{
    if (au.open) {
        SDL_SetError("Audio device is already opened");
        return -1;
    }
    if (desired == NULL || desired->callback == NULL) {
        SDL_SetError("SDL_OpenAudio() passed a NULL callback");
        return -1;
    }
    SDL_AudioSpec s = *desired;
    if (s.freq <= 0) s.freq = 22050;
    if (s.channels == 0) s.channels = 2;
    if (s.channels > 2) {
        SDL_SetError("%d channels not supported", s.channels);
        return -1;
    }
    unsigned bits;
    switch (s.format) {
    case AUDIO_U8:
    case AUDIO_S8: bits = 8; break;
    case AUDIO_S16LSB:
    case AUDIO_U16LSB:
    case AUDIO_S16MSB:
    case AUDIO_U16MSB: bits = 16; break;
    default:
        SDL_SetError("Unsupported audio format");
        return -1;
    }
    if (s.samples == 0) {
        /* as SDL 1.2: about 46 ms, a power of two */
        int want = s.freq / 1000 * 46, p = 1;
        while (p < want) p *= 2;
        s.samples = (Uint16)p;
    }
    s.silence = s.format == AUDIO_U8 ? 0x80 : 0x00;
    s.size = (Uint32)s.samples * s.channels * (bits / 8);
    au.spec = s;
    au.paused = 1; /* as SDL 1.2: SDL_PauseAudio(0) starts it */
    /* the card's driver converts the rate; else another rate, if the
       program takes what it gets */
    static const int rates[] = {0, 48000, 44100, 22050, 11025};
    for (unsigned i = 0; i < (obtained ? sizeof(rates) / sizeof(rates[0]) : 1); i++) {
        if (i > 0) {
            if (rates[i] == s.freq) continue;
            au.spec.freq = rates[i];
        }
        if (zdos_audio_start((uint32_t)au.spec.freq, s.channels, bits, s.samples, fill, NULL)) {
            au.open = 1;
            if (obtained) *obtained = au.spec;
            return 0;
        }
        if (zdos->programs->last_error() != ZDOS_ERROR_INVALID_ARGUMENT) break;
    }
    SDL_SetError("Can't open the sound card (error %u)", (unsigned)zdos->programs->last_error());
    return -1;
}

SDL_audiostatus SDL_GetAudioStatus(void)
{
    return !au.open ? SDL_AUDIO_STOPPED : au.paused ? SDL_AUDIO_PAUSED : SDL_AUDIO_PLAYING;
}

void SDL_PauseAudio(int pause_on)
{
    zdos_audio_lock();
    au.paused = pause_on != 0;
    zdos_audio_unlock();
}

void SDL_LockAudio(void) { zdos_audio_lock(); }
void SDL_UnlockAudio(void) { zdos_audio_unlock(); }

void SDL_CloseAudio(void)
{
    if (!au.open) return;
    zdos_audio_stop();
    au.open = 0;
}

void SDL_MixAudio(Uint8 *dst, const Uint8 *src, Uint32 len, int volume)
{
    if (volume <= 0) return;
    if (volume > SDL_MIX_MAXVOLUME) volume = SDL_MIX_MAXVOLUME;
    switch (au.open ? au.spec.format : AUDIO_S16LSB) {
    case AUDIO_U8:
        for (Uint32 i = 0; i < len; i++) {
            int v = (dst[i] - 128) + (src[i] - 128) * volume / SDL_MIX_MAXVOLUME;
            dst[i] = (Uint8)((v < -128 ? -128 : v > 127 ? 127 : v) + 128);
        }
        break;
    case AUDIO_S8:
        for (Uint32 i = 0; i < len; i++) {
            int v = (Sint8)dst[i] + (Sint8)src[i] * volume / SDL_MIX_MAXVOLUME;
            dst[i] = (Uint8)(Sint8)(v < -128 ? -128 : v > 127 ? 127 : v);
        }
        break;
    default: /* 16 bits, mixed as signed little-endian */
        for (Uint32 i = 0; i + 1 < len; i += 2) {
            int v = (Sint16)(dst[i] | dst[i + 1] << 8) + (Sint16)(src[i] | src[i + 1] << 8) * volume / SDL_MIX_MAXVOLUME;
            v = v < -32768 ? -32768 : v > 32767 ? 32767 : v;
            dst[i] = (Uint8)v, dst[i + 1] = (Uint8)(v >> 8);
        }
        break;
    }
}
