// Abuse's sound on ZDOS, for sdlport/sound.cpp (SDL_mixer): the WAV
// effects mixed on SDL_OpenAudio's callback, 22050 Hz stereo 16-bit,
// with the music: its HMI songs as MIDI (hmi.cpp) played by MIDI.ZDL.
#if defined HAVE_CONFIG_H
#   include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <SDL.h>
#include <midi.h>

#include "sound.h"
#include "hmi.h"
#include "specs.h"
#include "setup.h"

extern flags_struct flags;

// A sample: 16-bit mono at its own rate
struct Mix_Chunk
{
    Sint16 *pcm;
    Uint32 frames;
    Uint32 step; // source frames per output frame, 16.16
};

// VOICES
enum { VOICES = 32, RATE = 22050, SAMPLES = 1024 };

static struct voice
{
    Mix_Chunk *chunk;
    Uint64 pos; // 16.16
    int left, right; // 0-32768
} voices[VOICES];

static int sound_enabled = 0;
static int out_rate = RATE, out_channels = 2;
static int *mixbuf = NULL;
static unsigned next_voice = 0;
static midi *synth = NULL;
static short *musicbuf = NULL;
static song *current = NULL; // the song the synthesizer plays

// One block of up to SAMPLES frames
static void mix_block(Sint16 *out, int frames)
{
    memset(mixbuf, 0, sizeof(int) * 2 * frames);
    for (int v = 0; v < VOICES; v++)
    {
        voice *p = &voices[v];
        Mix_Chunk *c = p->chunk;
        if (c == NULL)
            continue;
        for (int i = 0; i < frames; i++)
        {
            Uint32 n = (Uint32)(p->pos >> 16);
            if (n >= c->frames)
            {
                p->chunk = NULL;
                break;
            }
            int s = c->pcm[n];
            mixbuf[2 * i] += (s * p->left) >> 15;
            mixbuf[2 * i + 1] += (s * p->right) >> 15;
            p->pos += c->step;
        }
    }
    for (int i = 0; i < frames; i++)
    {
        int l = mixbuf[2 * i], r = mixbuf[2 * i + 1];
        if (out_channels == 1)
            l = (l + r) / 2;
        l = l < -32768 ? -32768 : l > 32767 ? 32767 : l;
        r = r < -32768 ? -32768 : r > 32767 ? 32767 : r;
        if (out_channels == 1)
            out[i] = (Sint16)l;
        else
        {
            out[2 * i] = (Sint16)l;
            out[2 * i + 1] = (Sint16)r;
        }
    }
}

// The music under the effects:
static void mix_music(Sint16 *out, int frames)
{
    if (current == NULL)
        return;
    midi_render(synth, musicbuf, frames, 0);
    for (int i = 0; i < frames * out_channels; i++)
    {
        int s = out[i] + musicbuf[i];
        out[i] = (Sint16)(s < -32768 ? -32768 : s > 32767 ? 32767 : s);
    }
}

static void mix(void *, Uint8 *stream, int len)
{
    Sint16 *out = (Sint16 *)stream;
    for (int frames = len / (2 * out_channels); frames > 0;)
    {
        int n = frames < SAMPLES ? frames : SAMPLES;
        mix_block(out, n);
        mix_music(out, n);
        out += n * out_channels;
        frames -= n;
    }
}

int sound_init(int argc, char **argv)
{
    (void)argc, (void)argv;
    if (flags.nosound)
    {
        printf("Sound: Disabled (-nosound)\n");
        return 0;
    }

    // No sfx folder: no sound
    char sfxdir[512];
    struct stat st;
    snprintf(sfxdir, sizeof(sfxdir), "%ssfx", get_filename_prefix());
    if (stat(sfxdir, &st) != 0 || !S_ISDIR(st.st_mode))
    {
        printf("Sound: Disabled (couldn't find the sfx directory)\n");
        return 0;
    }

    mixbuf = (int *)malloc(sizeof(int) * 2 * SAMPLES);
    musicbuf = (short *)malloc(sizeof(short) * 2 * SAMPLES);
    if (mixbuf == NULL || musicbuf == NULL)
        return 0;

    SDL_AudioSpec want, got;
    memset(&want, 0, sizeof(want));
    want.freq = RATE;
    want.format = AUDIO_S16SYS;
    want.channels = flags.mono ? 1 : 2;
    want.samples = SAMPLES;
    want.callback = mix;
    if (SDL_OpenAudio(&want, &got) < 0)
    {
        printf("Sound: Unable to open audio - %s\nSound: Disabled (error)\n", SDL_GetError());
        free(mixbuf);
        mixbuf = NULL;
        return 0;
    }
    out_rate = got.freq;
    out_channels = got.channels;
    sound_enabled = SFX_INITIALIZED;

    // MIDISYNTH chooses FM or the SoundFont:
    synth = midi_open(MIDI_DEFAULT, NULL);
    if (synth != NULL && midi_set_output(synth, out_rate, out_channels) == 0)
        sound_enabled |= MUSIC_INITIALIZED;
    SDL_PauseAudio(0);

    printf("Sound: Enabled (%s)\n", !(sound_enabled & MUSIC_INITIALIZED) ? "no music" :
           midi_synth(synth) == MIDI_FM ? "FM music" : "SoundFont music");
    return sound_enabled;
}

void sound_uninit()
{
    if (!sound_enabled)
        return;
    SDL_CloseAudio();
    midi_close(synth);
    synth = NULL;
    current = NULL;
    sound_enabled = 0;
}

// WAV FILES

static Uint32 le(Uint8 const *p, int n)
{
    Uint32 v = 0;
    while (n--)
        v = v << 8 | p[n];
    return v;
}

// A PCM WAV (8 or 16 bits, mono or stereo) as a chunk; NULL if not one
static Mix_Chunk *load_wav(Uint8 const *d, Uint32 size)
{
    if (size < 12 || memcmp(d, "RIFF", 4) || memcmp(d + 8, "WAVE", 4))
        return NULL;
    Uint32 rate = 0, channels = 0, bits = 0, len = 0;
    Uint8 const *pcm = NULL;
    for (Uint32 at = 12; at + 8 <= size;)
    {
        Uint32 n = le(d + at + 4, 4);
        Uint8 const *body = d + at + 8;
        if (n > size - at - 8)
            n = size - at - 8; // a data chunk cut short
        if (!memcmp(d + at, "fmt ", 4) && n >= 16)
        {
            if (le(body, 2) != 1)
                return NULL;
            channels = le(body + 2, 2);
            rate = le(body + 4, 4);
            bits = le(body + 14, 2);
        }
        else if (!memcmp(d + at, "data", 4))
        {
            pcm = body;
            len = n;
        }
        at += 8 + n + (n & 1);
    }
    if (pcm == NULL || rate == 0 || (channels != 1 && channels != 2) || (bits != 8 && bits != 16))
        return NULL;
    Uint32 frames = len / (channels * bits / 8);
    Mix_Chunk *c = (Mix_Chunk *)malloc(sizeof(Mix_Chunk));
    if (c == NULL)
        return NULL;
    c->pcm = (Sint16 *)malloc(sizeof(Sint16) * (frames ? frames : 1));
    if (c->pcm == NULL)
    {
        free(c);
        return NULL;
    }
    for (Uint32 i = 0; i < frames; i++)
    {
        int s = 0;
        for (Uint32 k = 0; k < channels; k++)
        {
            Uint8 const *p = pcm + (i * channels + k) * (bits / 8);
            s += bits == 8 ? (p[0] - 128) * 256 : (Sint16)(p[0] | p[1] << 8);
        }
        c->pcm[i] = (Sint16)(s / (int)channels);
    }
    c->frames = frames;
    c->step = (Uint32)(((unsigned long long)rate << 16) / (Uint32)out_rate);
    return c;
}

sound_effect::sound_effect(char const *filename)
{
    m_chunk = NULL;
    if (!sound_enabled)
        return;

    jFILE fp(filename, "rb");
    if (fp.open_failure())
        return;

    Uint32 size = (Uint32)fp.file_size();
    Uint8 *data = (Uint8 *)malloc(size ? size : 1);
    if (data == NULL)
        return;
    if (fp.read(data, size) == (int)size)
        m_chunk = load_wav(data, size);
    free(data);
    if (m_chunk == NULL)
        printf("Sound: ERROR - could not load %s\n", filename);
}

sound_effect::~sound_effect()
{
    if (m_chunk == NULL)
        return;
    SDL_LockAudio();
    for (int v = 0; v < VOICES; v++)
        if (voices[v].chunk == m_chunk)
            voices[v].chunk = NULL;
    SDL_UnlockAudio();
    free(m_chunk->pcm);
    free(m_chunk);
}

// volume 0-127; panpot 0 right, 128 the middle, 255 left
void sound_effect::play(int volume, int pitch, int panpot)
{
    (void)pitch;
    if (!sound_enabled || m_chunk == NULL)
        return;
    volume = volume < 0 ? 0 : volume > 127 ? 127 : volume;
    panpot = panpot < 0 ? 0 : panpot > 255 ? 255 : panpot;
    int gain = volume * 32768 / 127;
    int left = panpot < 128 ? panpot * 2 : 255;
    int right = panpot > 127 ? (255 - panpot) * 2 : 255;

    SDL_LockAudio();
    // a free voice, else the next one in turn
    int v;
    for (v = 0; v < VOICES && voices[v].chunk != NULL; v++)
        ;
    if (v == VOICES)
        v = (int)(next_voice++ % VOICES);
    voices[v].chunk = m_chunk;
    voices[v].pos = 0;
    voices[v].left = gain * left / 255;
    voices[v].right = gain * right / 255;
    SDL_UnlockAudio();
}

// MUSIC: one song at a time, its MIDI file in data, song_id bytes.
// It plays once: music_check starts it again.

song::song(char const *filename)
{
    data = NULL;
    Name = strdup(filename);
    song_id = 0;
    rw = NULL;
    music = NULL;
    if (!(sound_enabled & MUSIC_INITIALIZED))
        return;

    char path[512];
    snprintf(path, sizeof(path), "%s%s", get_filename_prefix(), filename);
    uint32_t size = 0;
    data = load_hmi(path, size);
    if (data == NULL)
        printf("Sound: ERROR - could not load %s\n", path);
    song_id = size;
}

song::~song()
{
    stop();
    free(data);
    free(Name);
}

// volume 0-127
void song::play(unsigned char volume)
{
    if (data == NULL)
        return;
    SDL_LockAudio();
    if (midi_load_memory(synth, data, (int)song_id) == 0)
    {
        midi_set_volume(synth, volume * 100 / 127);
        current = this;
    }
    else
        current = NULL;
    SDL_UnlockAudio();
}

void song::stop(long fadeout_time)
{
    (void)fadeout_time;
    if (current != this)
        return;
    SDL_LockAudio();
    midi_stop(synth);
    current = NULL;
    SDL_UnlockAudio();
}

int song::playing()
{
    if (current != this)
        return 0;
    SDL_LockAudio();
    int on = !midi_finished(synth);
    SDL_UnlockAudio();
    return on;
}

void song::set_volume(int volume)
{
    if (current != this)
        return;
    SDL_LockAudio();
    midi_set_volume(synth, volume * 100 / 127);
    SDL_UnlockAudio();
}
