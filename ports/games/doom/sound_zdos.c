// Doom's sound on ZDOS, the DG_sound_module and DG_music_module
// i_sound.c takes with FEATURE_SOUND: the effects (DMX lumps, 8-bit
// at their own rate) mixed on zdos_media.h's audio thread, 16-bit
// stereo at snd_samplerate; the music, MUS made MIDI (mus2mid.c),
// played by MIDI.ZDL into the same buffer.

#include <stdlib.h>
#include <string.h>

#include <midi.h>
#include "zdos.h"
#include "zdos_media.h"

#include "doomtype.h"
#include "i_sound.h"
#include "memio.h"
#include "mus2mid.h"
#include "m_misc.h"
#include "w_wad.h"
#include "z_zone.h"
#include "deh_str.h"

// i_sound.c binds them (libsamplerate's, which isn't here):
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

enum { VOICES = 16, FRAMES = 512 };

// OUTPUT: one audio thread for both modules

static int out_rate;
static bool output_on;
static int mixbuf[2 * FRAMES];

// An effect: its samples as 16-bit, played at step (16.16) a frame
typedef struct
{
    int16_t *pcm;
    uint32_t frames;
    uint32_t step;
} sample;

static struct voice
{
    sample *s;
    uint64_t pos; // 16.16
    int left, right; // 0-255
} voices[VOICES];

static boolean sfx_on;
static midi *synth;
static bool music_on, music_paused;

static void mix(void *user, uint8_t *buf, size_t len)
{
    (void)user;
    int16_t *out = (int16_t *)buf;
    int frames = (int)(len / 4);
    memset(mixbuf, 0, sizeof(int) * 2 * frames);
    for (int v = 0; v < VOICES; v++)
    {
        struct voice *p = &voices[v];
        if (p->s == NULL)
            continue;
        for (int i = 0; i < frames; i++)
        {
            uint32_t n = (uint32_t)(p->pos >> 16);
            if (n >= p->s->frames)
            {
                p->s = NULL;
                break;
            }
            // Between this sample and the next:
            int a = p->s->pcm[n];
            int b = n + 1 < p->s->frames ? p->s->pcm[n + 1] : a;
            int s = a + (((b - a) * (int)(p->pos & 0xFFFF)) >> 16);
            mixbuf[2 * i] += (s * p->left) >> 8;
            mixbuf[2 * i + 1] += (s * p->right) >> 8;
            p->pos += p->s->step;
        }
    }
    for (int i = 0; i < 2 * frames; i++)
    {
        int s = mixbuf[i];
        out[i] = (int16_t)(s < -32768 ? -32768 : s > 32767 ? 32767 : s);
    }
    if (music_on && !music_paused)
        midi_render(synth, out, frames, 1);
}

static bool start_output(void)
{
    if (output_on)
        return true;
    out_rate = snd_samplerate >= 8000 && snd_samplerate <= 96000 ? snd_samplerate : 44100;
    output_on = zdos_audio_start((uint32_t)out_rate, 2, 16, FRAMES, mix, NULL);
    return output_on;
}

// When neither effects nor music are on:
static void stop_output(void)
{
    if (output_on && !sfx_on && synth == NULL)
    {
        zdos_audio_stop();
        output_on = false;
    }
}

// EFFECTS

static boolean use_prefix;

static boolean Sound_Init(boolean use_sfx_prefix)
{
    use_prefix = use_sfx_prefix;
    if (!start_output())
        return false;
    sfx_on = true;
    return true;
}

static void Sound_Shutdown(void)
{
    zdos_audio_lock();
    memset(voices, 0, sizeof(voices));
    sfx_on = false;
    zdos_audio_unlock();
    stop_output();
}

static int Sound_GetSfxLumpNum(sfxinfo_t *sfx)
{
    char name[9];
    if (sfx->link != NULL)
        sfx = sfx->link;
    if (use_prefix)
        M_snprintf(name, sizeof(name), "ds%s", DEH_String(sfx->name));
    else
        M_StringCopy(name, DEH_String(sfx->name), sizeof(name));
    return W_GetNumForName(name);
}

// A DMX lump (format 3: rate, length, 16 bytes of padding at both
// ends of the samples, skipped as DMX does) as a sample; NULL if not
static sample *load(sfxinfo_t *sfx)
{
    const byte *d = W_CacheLumpNum(sfx->lumpnum, PU_STATIC);
    unsigned size = W_LumpLength(sfx->lumpnum);
    sample *s = NULL;
    if (size >= 8 && d[0] == 3 && d[1] == 0)
    {
        unsigned rate = d[2] | d[3] << 8;
        unsigned len = d[4] | d[5] << 8 | d[6] << 16 | (unsigned)d[7] << 24;
        if (len <= size - 8 && len > 48 && rate > 0)
        {
            len -= 32;
            s = malloc(sizeof(sample));
            if (s != NULL && (s->pcm = malloc(sizeof(int16_t) * len)) != NULL)
            {
                for (unsigned i = 0; i < len; i++)
                    s->pcm[i] = (int16_t)((d[8 + 16 + i] - 128) << 8);
                s->frames = len;
                s->step = (uint32_t)(((uint64_t)rate << 16) / (uint32_t)out_rate);
            }
            else
            {
                free(s);
                s = NULL;
            }
        }
    }
    W_ReleaseLumpNum(sfx->lumpnum);
    return s;
}

// vol 0-127; sep 0 left, 128 the middle, 254 right
static void set_params(struct voice *v, int vol, int sep)
{
    int left = (254 - sep) * vol / 127;
    int right = sep * vol / 127;
    v->left = left < 0 ? 0 : left > 255 ? 255 : left;
    v->right = right < 0 ? 0 : right > 255 ? 255 : right;
}

static void Sound_UpdateSoundParams(int channel, int vol, int sep)
{
    if (!sfx_on || channel < 0 || channel >= VOICES)
        return;
    zdos_audio_lock();
    set_params(&voices[channel], vol, sep);
    zdos_audio_unlock();
}

static int Sound_StartSound(sfxinfo_t *sfx, int channel, int vol, int sep)
{
    if (!sfx_on || channel < 0 || channel >= VOICES)
        return -1;
    if (sfx->driver_data == NULL)
        sfx->driver_data = load(sfx);
    if (sfx->driver_data == NULL)
        return -1;
    zdos_audio_lock();
    voices[channel].s = sfx->driver_data;
    voices[channel].pos = 0;
    set_params(&voices[channel], vol, sep);
    zdos_audio_unlock();
    return channel;
}

static void Sound_StopSound(int channel)
{
    if (!sfx_on || channel < 0 || channel >= VOICES)
        return;
    zdos_audio_lock();
    voices[channel].s = NULL;
    zdos_audio_unlock();
}

static boolean Sound_SoundIsPlaying(int channel)
{
    if (!sfx_on || channel < 0 || channel >= VOICES)
        return false;
    zdos_audio_lock();
    boolean on = voices[channel].s != NULL;
    zdos_audio_unlock();
    return on;
}

static void Sound_Update(void)
{
}

// Loaded when first played:
static void Sound_CacheSounds(sfxinfo_t *sounds, int num_sounds)
{
    (void)sounds, (void)num_sounds;
}

static snddevice_t sound_devices[] = {
    SNDDEVICE_SB, SNDDEVICE_PAS, SNDDEVICE_GUS,
    SNDDEVICE_WAVEBLASTER, SNDDEVICE_SOUNDCANVAS, SNDDEVICE_AWE32,
};

sound_module_t DG_sound_module = {
    sound_devices,
    arrlen(sound_devices),
    Sound_Init,
    Sound_Shutdown,
    Sound_GetSfxLumpNum,
    Sound_Update,
    Sound_UpdateSoundParams,
    Sound_StartSound,
    Sound_StopSound,
    Sound_SoundIsPlaying,
    Sound_CacheSounds,
};

// MUSIC: a song is its MIDI file; one plays at a time

typedef struct
{
    void *data;
    size_t len;
} song;

static song *playing;

static boolean Music_Init(void)
{
    if (!start_output())
        return false;
    // MIDISYNTH chooses FM or the SoundFont:
    midi *m = midi_open(MIDI_DEFAULT, NULL);
    if (m == NULL)
        return false;
    if (midi_set_output(m, out_rate, 2) != 0)
    {
        midi_close(m);
        return false;
    }
    zdos_audio_lock();
    synth = m;
    zdos_audio_unlock();
    return true;
}

static void Music_Shutdown(void)
{
    if (synth == NULL)
        return;
    zdos_audio_lock();
    music_on = false;
    playing = NULL;
    midi *m = synth;
    synth = NULL;
    zdos_audio_unlock();
    midi_close(m);
    stop_output();
}

// 0-127
static void Music_SetMusicVolume(int volume)
{
    if (synth == NULL)
        return;
    zdos_audio_lock();
    midi_set_volume(synth, volume * 100 / 127);
    zdos_audio_unlock();
}

static void Music_PauseMusic(void)
{
    zdos_audio_lock();
    music_paused = true;
    zdos_audio_unlock();
}

static void Music_ResumeMusic(void)
{
    zdos_audio_lock();
    music_paused = false;
    zdos_audio_unlock();
}

// A MUS lump as MIDI, or a MIDI one as it is
static void *Music_RegisterSong(void *data, int len)
{
    if (synth == NULL || len < 4)
        return NULL;
    song *s = malloc(sizeof(song));
    if (s == NULL)
        return NULL;
    s->data = NULL;
    if (memcmp(data, "MThd", 4) == 0)
    {
        if ((s->data = malloc((size_t)len)) != NULL)
        {
            memcpy(s->data, data, (size_t)len);
            s->len = (size_t)len;
        }
    }
    else
    {
        MEMFILE *in = mem_fopen_read(data, (size_t)len);
        MEMFILE *out = mem_fopen_write();
        if (!mus2mid(in, out))
        {
            void *buf;
            size_t n;
            mem_get_buf(out, &buf, &n);
            if ((s->data = malloc(n)) != NULL)
            {
                memcpy(s->data, buf, n);
                s->len = n;
            }
        }
        mem_fclose(in);
        mem_fclose(out);
    }
    if (s->data == NULL)
    {
        free(s);
        return NULL;
    }
    return s;
}

static void Music_StopSong(void)
{
    if (synth == NULL)
        return;
    zdos_audio_lock();
    midi_stop(synth);
    music_on = false;
    playing = NULL;
    zdos_audio_unlock();
}

static void Music_UnRegisterSong(void *handle)
{
    song *s = handle;
    if (s == NULL)
        return;
    if (playing == s)
        Music_StopSong();
    free(s->data);
    free(s);
}

static void Music_PlaySong(void *handle, boolean looping)
{
    song *s = handle;
    if (synth == NULL || s == NULL)
        return;
    zdos_audio_lock();
    if (midi_load_memory(synth, s->data, (int)s->len) == 0)
    {
        midi_set_loop(synth, looping);
        music_on = true;
        playing = s;
    }
    else
    {
        music_on = false;
        playing = NULL;
    }
    zdos_audio_unlock();
}

static boolean Music_MusicIsPlaying(void)
{
    if (synth == NULL)
        return false;
    zdos_audio_lock();
    boolean on = music_on && !midi_finished(synth);
    zdos_audio_unlock();
    return on;
}

static snddevice_t music_devices[] = {
    SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS, SNDDEVICE_GENMIDI, SNDDEVICE_AWE32,
};

music_module_t DG_music_module = {
    music_devices,
    arrlen(music_devices),
    Music_Init,
    Music_Shutdown,
    Music_SetMusicVolume,
    Music_PauseMusic,
    Music_ResumeMusic,
    Music_RegisterSong,
    Music_UnRegisterSong,
    Music_PlaySong,
    Music_StopSong,
    Music_MusicIsPlaying,
    NULL,
};
