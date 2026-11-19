/* MIDI.ZDL: songs and events for two synthesizers, FM (fm.c) and
 * TinySoundFont's SoundFont player. */
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#if defined __zdos__
/* Files through ZDOS's handles, not FILE streams: MIDI.ZDL is one
 * copy for every program, a handle the calling program's */
#define TSF_NO_STDIO
#define TML_NO_STDIO
#endif
#define TSF_IMPLEMENTATION
#include "tsf.h"
#define TML_IMPLEMENTATION
#include "tml.h"

#include "fm.h"
#include "midi.h"

#define DEFAULT_SF2 "C:\\DATA\\MIDI\\GM.SF2"

#if defined __zdos__
#include "zdos.h"

typedef struct
{
    int32_t handle;
    uint64_t pos;
} file_stream;

static int file_read(void *data, void *ptr, unsigned int size)
{
    file_stream *f = data;
    int64_t n = zdos->files->read(f->handle, ptr, size);
    if (n <= 0)
        return 0;
    f->pos += (uint64_t)n;
    return (int)n;
}

static int file_skip(void *data, unsigned int count)
{
    file_stream *f = data;
    if (!zdos->files->seek(f->handle, f->pos + count))
        return 0;
    f->pos += count;
    return 1;
}

static int file_open(file_stream *f, const char *path)
{
    f->handle = zdos->files->open(path, strlen(path), ZDOS_READ);
    f->pos = 0;
    return f->handle >= 0;
}

static tsf *tsf_load_filename(const char *path)
{
    file_stream f;
    if (!file_open(&f, path))
        return NULL;
    struct tsf_stream s = { &f, file_read, file_skip };
    tsf *sf = tsf_load(&s);
    zdos->files->close(f.handle);
    return sf;
}

static tml_message *tml_load_filename(const char *path)
{
    file_stream f;
    if (!file_open(&f, path))
        return NULL;
    struct tml_stream s = { &f, file_read };
    tml_message *song = tml_load(&s);
    zdos->files->close(f.handle);
    return song;
}
#endif
enum { BLOCK = 64, SF2_VOICES = 64, FM_TAIL_MS = 1500, SF2_TAIL_MS = 4000 };
/* The two alike, with room for loud songs: SoundFont -6 dB, FM
 * +6 dB (in 256ths): */
#define SF2_GAIN 0.5f
enum { FM_GAIN = 512 };

struct midi {
    int synth, rate, channels, volume;
    tsf *sf;
    fm *fm;
    tml_message *song, *next;
    double ms;         /* the song's time */
    double tail;       /* after its end, ms */
    unsigned length;
    int loop;
    unsigned char status, data[2]; /* midi_write's message */
    int have, sysex;
    short buf[2 * BLOCK];
};

/* OPENING */

static void gm_reset(midi *m)
{
    if (m->sf)
    {
        tsf_reset(m->sf);
        for (int ch = 0; ch < 16; ch++)
        {
            if (ch == 9)
                tsf_channel_set_bank_preset(m->sf, ch, 128, 0);
            else
                tsf_channel_set_presetnumber(m->sf, ch, 0, 0);
            tsf_channel_midi_control(m->sf, ch, 121, 0);
            tsf_channel_midi_control(m->sf, ch, 7, 100);
            tsf_channel_set_pitchwheel(m->sf, ch, 8192);
        }
    }
    else
        fm_reset(m->fm);
}

static void apply_output(midi *m)
{
    if (m->sf)
    {
        tsf_set_output(m->sf, m->channels == 2 ? TSF_STEREO_INTERLEAVED : TSF_MONO, m->rate, 0);
        tsf_set_volume(m->sf, m->volume * SF2_GAIN / 100.0f);
    }
    else
        fm_set_rate(m->fm, m->rate);
}

static midi *create(int synth, tsf *sf)
{
    midi *m = (midi *)calloc(1, sizeof(midi));
    if (m == NULL)
    {
        tsf_close(sf);
        return NULL;
    }
    m->synth = synth;
    m->rate = 44100;
    m->channels = 2;
    m->volume = 100;
    m->sf = sf;
    if (sf)
        tsf_set_max_voices(sf, SF2_VOICES);
    else if ((m->fm = fm_new(m->rate)) == NULL)
    {
        free(m);
        return NULL;
    }
    apply_output(m);
    gm_reset(m);
    return m;
}

midi *midi_open(int synth, const char *soundfont)
{
    if (synth == MIDI_DEFAULT)
    {
        const char *s = getenv("MIDISYNTH");
        synth = s && !strcasecmp(s, "sf2") ? MIDI_SF2 : MIDI_FM;
        if (synth == MIDI_SF2)
        {
            midi *m = midi_open(MIDI_SF2, soundfont);
            return m ? m : midi_open(MIDI_FM, NULL);
        }
    }
    if (synth == MIDI_FM)
        return create(MIDI_FM, NULL);
    if (synth != MIDI_SF2)
        return NULL;
    if (soundfont == NULL)
        soundfont = getenv("MIDISF");
    if (soundfont == NULL || !*soundfont)
        soundfont = DEFAULT_SF2;
    tsf *sf = tsf_load_filename(soundfont);
    return sf ? create(MIDI_SF2, sf) : NULL;
}

midi *midi_open_memory(const void *sf2, int size)
{
    tsf *sf = tsf_load_memory(sf2, size);
    return sf ? create(MIDI_SF2, sf) : NULL;
}

void midi_close(midi *m)
{
    if (m == NULL)
        return;
    tml_free(m->song);
    tsf_close(m->sf);
    fm_free(m->fm);
    free(m);
}

int midi_synth(midi *m)
{
    return m->synth;
}

int midi_set_output(midi *m, int rate, int channels)
{
    if (rate < 8000 || rate > 96000 || channels < 1 || channels > 2)
        return -1;
    m->rate = rate;
    m->channels = channels;
    apply_output(m);
    gm_reset(m);
    return 0;
}

void midi_set_volume(midi *m, int percent)
{
    m->volume = percent < 0 ? 0 : percent > 400 ? 400 : percent;
    if (m->sf)
        tsf_set_volume(m->sf, m->volume * SF2_GAIN / 100.0f);
}

/* EVENTS */

void midi_note_on(midi *m, int channel, int key, int velocity)
{
    channel &= 15, key &= 127, velocity &= 127;
    if (m->sf)
    {
        if (velocity)
            tsf_channel_note_on(m->sf, channel, key, velocity / 127.0f);
        else
            tsf_channel_note_off(m->sf, channel, key);
    }
    else
        fm_note_on(m->fm, channel, key, velocity);
}

void midi_note_off(midi *m, int channel, int key)
{
    channel &= 15, key &= 127;
    if (m->sf)
        tsf_channel_note_off(m->sf, channel, key);
    else
        fm_note_off(m->fm, channel, key);
}

void midi_program(midi *m, int channel, int program)
{
    channel &= 15, program &= 127;
    if (m->sf)
        tsf_channel_set_presetnumber(m->sf, channel, program, channel == 9);
    else
        fm_program(m->fm, channel, program);
}

void midi_control(midi *m, int channel, int controller, int value)
{
    channel &= 15, controller &= 127, value &= 127;
    if (m->sf)
        tsf_channel_midi_control(m->sf, channel, controller, value);
    else
        fm_control(m->fm, channel, controller, value);
}

void midi_pitch_bend(midi *m, int channel, int value)
{
    channel &= 15;
    value = value < 0 ? 0 : value > 16383 ? 16383 : value;
    if (m->sf)
        tsf_channel_set_pitchwheel(m->sf, channel, value);
    else
        fm_pitch_bend(m->fm, channel, value);
}

/* Neither synthesizer has a use for it: */
void midi_channel_pressure(midi *m, int channel, int value)
{
    (void)m, (void)channel, (void)value;
}

static void message(midi *m, int status, int a, int b)
{
    int ch = status & 15;
    switch (status & 0xF0)
    {
    case 0x80:
        midi_note_off(m, ch, a);
        break;
    case 0x90:
        midi_note_on(m, ch, a, b);
        break;
    case 0xB0:
        midi_control(m, ch, a, b);
        break;
    case 0xC0:
        midi_program(m, ch, a);
        break;
    case 0xD0:
        midi_channel_pressure(m, ch, a);
        break;
    case 0xE0:
        midi_pitch_bend(m, ch, a | b << 7);
        break;
    }
}

void midi_write(midi *m, const unsigned char *bytes, int len)
{
    for (int i = 0; i < len; i++)
    {
        int c = bytes[i];
        if (c >= 0xF8)
            continue; /* real time, between any bytes */
        if (c == 0xF0)
        {
            m->sysex = 1;
            m->status = 0;
            continue;
        }
        if (c >= 0xF1)
        {
            m->sysex = 0; /* 0xF7 ends system exclusive */
            m->status = 0;
            continue;
        }
        if (c >= 0x80)
        {
            m->sysex = 0;
            m->status = (unsigned char)c;
            m->have = 0;
            continue;
        }
        if (m->sysex || m->status == 0)
            continue;
        m->data[m->have++] = (unsigned char)c;
        int need = (m->status & 0xE0) == 0xC0 ? 1 : 2;
        if (m->have == need)
        {
            message(m, m->status, m->data[0], m->data[1]);
            m->have = 0;
        }
    }
}

void midi_reset(midi *m)
{
    gm_reset(m);
    m->status = 0;
    m->have = m->sysex = 0;
}

/* SONGS */

static void notes_off(midi *m)
{
    for (int ch = 0; ch < 16; ch++)
    {
        midi_control(m, ch, 64, 0);
        midi_control(m, ch, 123, 0);
    }
}

static int start_song(midi *m, tml_message *song)
{
    if (song == NULL)
        return -1;
    midi_stop(m);
    m->song = song;
    unsigned length = 0;
    tml_get_info(song, NULL, NULL, NULL, NULL, &length);
    m->length = length;
    midi_restart(m);
    return 0;
}

int midi_load(midi *m, const char *path)
{
    return start_song(m, tml_load_filename(path));
}

int midi_load_memory(midi *m, const void *data, int size)
{
    return start_song(m, tml_load_memory(data, size));
}

void midi_stop(midi *m)
{
    tml_free(m->song);
    m->song = m->next = NULL;
    m->ms = m->tail = 0;
    m->length = 0;
    midi_reset(m);
}

void midi_restart(midi *m)
{
    midi_reset(m);
    m->next = m->song;
    m->ms = m->tail = 0;
}

void midi_set_loop(midi *m, int loop)
{
    m->loop = loop;
}

int midi_finished(midi *m)
{
    if (m->next)
        return 0;
    if (m->sf)
        return tsf_active_voice_count(m->sf) == 0 || m->tail >= SF2_TAIL_MS;
    return m->tail >= FM_TAIL_MS;
}

unsigned midi_length_ms(midi *m)
{
    return m->length;
}

unsigned midi_position_ms(midi *m)
{
    return m->next || !m->song ? (unsigned)m->ms : m->length;
}

/* RENDERING */

/* The song's events up to the end of the next n frames: */
static void advance(midi *m, int n)
{
    double step = n * 1000.0 / m->rate;
    if (m->next == NULL)
    {
        m->tail += step;
        return;
    }
    m->ms += step;
    while (m->next && m->next->time <= m->ms)
    {
        tml_message *e = m->next;
        m->next = e->next;
        if (e->type == TML_PITCH_BEND)
            midi_pitch_bend(m, e->channel, e->pitch_bend);
        else if (e->type != TML_SET_TEMPO)
            message(m, e->type | e->channel, (unsigned char)e->key, (unsigned char)e->velocity);
    }
    if (m->next == NULL)
    {
        notes_off(m);
        if (m->loop)
            midi_restart(m);
    }
}

static void fm_block(midi *m, short *out, int n, int mix)
{
    fm_render(m->fm, m->buf, n);
    int vol = m->volume * FM_GAIN / 100;
    for (int i = 0; i < n; i++)
    {
        int l = m->buf[2 * i] * vol >> 8, r = m->buf[2 * i + 1] * vol >> 8;
        if (m->channels == 1)
        {
            int s = (l + r) / 2 + (mix ? out[i] : 0);
            out[i] = (short)(s < -32768 ? -32768 : s > 32767 ? 32767 : s);
            continue;
        }
        if (mix)
            l += out[2 * i], r += out[2 * i + 1];
        out[2 * i] = (short)(l < -32768 ? -32768 : l > 32767 ? 32767 : l);
        out[2 * i + 1] = (short)(r < -32768 ? -32768 : r > 32767 ? 32767 : r);
    }
}

void midi_render(midi *m, short *out, int frames, int mix)
{
    while (frames > 0)
    {
        int n = frames < BLOCK ? frames : BLOCK;
        advance(m, n);
        if (m->sf)
            tsf_render_short(m->sf, out, n, mix);
        else
            fm_block(m, out, n, mix);
        out += n * m->channels;
        frames -= n;
    }
}

void midi_render_float(midi *m, float *out, int frames, int mix)
{
    while (frames > 0)
    {
        int n = frames < BLOCK ? frames : BLOCK;
        if (m->sf)
        {
            advance(m, n);
            tsf_render_float(m->sf, out, n, mix);
        }
        else
        {
            short tmp[2 * BLOCK];
            midi_render(m, tmp, n, 0);
            for (int i = 0; i < n * m->channels; i++)
                out[i] = (mix ? out[i] : 0) + tmp[i] / 32768.0f;
        }
        out += n * m->channels;
        frames -= n;
    }
}

#if defined __zdos__
const unsigned char zdos_library_shared = 1;
#define VERSION_(a, b) ZDOS_FILE_VERSION(a, b, 0, 0)
#define VERSION(a, b) VERSION_(a, b)
VERSION(TSF_VERSION_MAJOR, TSF_VERSION_MINOR);
#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
#endif
