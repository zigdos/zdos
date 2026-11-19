/* The FM synthesizer: General MIDI on Nuked-OPL3's OPL3 in its
 * 18 two-operator voices, with the instruments of Freedoom's GENMIDI
 * lump (genmidi.h, made by build.sh). */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "opl3.h"
#include "fm.h"
#include "genmidi.h"

/* GENMIDI: "#OPL_II#", then 175 instruments of 36 bytes (128
 * programs, then percussion keys 35-81), then their names.
 * An instrument: flags (1 fixed note, 4 two voices), the second
 * voice's fine tune, the fixed note, two voices of 16 bytes.
 * A voice: the modulator's 20/60/80/E0 registers, KSL, level;
 * feedback and connection; the carrier's six; unused;
 * note offset (int16). */
enum { INSTRUMENTS = 175, DRUM_FIRST = 35, DRUM_LAST = 81 };
enum { F_FIXED = 1, F_DOUBLE = 4 };
enum { VOICES = 18, OPL_RATE = 49716 };

struct voice {
    int on, held; /* keyed; held by the sustain pedal */
    int ch, key, note, vel;
    const uint8_t *p; /* the voice's 16 bytes */
    double detune;    /* semitones */
    unsigned when;    /* keyed on or off at */
    uint8_t b0;       /* last 0xB0 value */
};

struct channel {
    int program, volume, expression, pan, bend, sustain, rpn;
    double range; /* pitch bend in semitones */
};

struct fm {
    opl3_chip chip;
    int rate;
    unsigned clock;
    struct voice v[VOICES];
    struct channel c[16];
};

static const uint8_t op_offset[9] = {0, 1, 2, 8, 9, 10, 16, 17, 18};

static const uint8_t *instrument(int n)
{
    return genmidi_lump + 8 + 36 * n;
}

/* REGISTERS */

static void w(fm *f, int reg, int value)
{
    OPL3_WriteReg(&f->chip, (uint16_t)reg, (uint8_t)value);
}

static int bank_of(int v)
{
    return v < 9 ? 0 : 0x100;
}

static int mod_reg(int v)
{
    return bank_of(v) + op_offset[v % 9];
}

static int ch_reg(int v)
{
    return bank_of(v) + v % 9;
}

/* Velocity, volume and expression, 40 log each, as levels of
 * 0.75 dB on top of the patch's: */
static int level(fm *f, struct voice *v, int base)
{
    struct channel *c = &f->c[v->ch];
    double g = v->vel / 127.0 * (c->volume / 127.0) * (c->expression / 127.0);
    int att = g <= 0 ? 63 : (int)(-40.0 * log10(g) / 0.75 + 0.5);
    int l = (base & 63) + att;
    return l > 63 ? 63 : l;
}

static void set_volume(fm *f, int n)
{
    struct voice *v = &f->v[n];
    const uint8_t *p = v->p;
    int m = mod_reg(n);
    /* Additive (connection 1): the modulator is heard too: */
    w(f, m + 0x40, p[4] | ((p[6] & 1) ? level(f, v, p[5]) : (p[5] & 63)));
    w(f, m + 3 + 0x40, p[11] | level(f, v, p[12]));
}

static void set_pan(fm *f, int n)
{
    int pan = f->c[f->v[n].ch].pan;
    int lr = pan < 48 ? 0x10 : pan > 80 ? 0x20 : 0x30;
    w(f, ch_reg(n) + 0xC0, (f->v[n].p[6] & 0x0F) | lr);
}

static void set_freq(fm *f, int n, int key_on)
{
    struct voice *v = &f->v[n];
    struct channel *c = &f->c[v->ch];
    double note = v->note + v->detune + (c->bend - 8192) / 8192.0 * c->range;
    double fn = 440.0 * pow(2.0, (note - 69.0) / 12.0) * 1048576.0 / OPL_RATE;
    int block = 0;
    while (fn >= 1023.5 && block < 7)
    {
        fn /= 2;
        block++;
    }
    int fnum = fn > 1023 ? 1023 : (int)(fn + 0.5);
    v->b0 = (uint8_t)((key_on ? 0x20 : 0) | block << 2 | fnum >> 8);
    w(f, ch_reg(n) + 0xA0, fnum & 0xFF);
    w(f, ch_reg(n) + 0xB0, v->b0);
}

static void key_off(fm *f, int n)
{
    struct voice *v = &f->v[n];
    if (!v->on)
        return;
    v->on = v->held = 0;
    v->when = ++f->clock;
    v->b0 &= ~0x20;
    w(f, ch_reg(n) + 0xB0, v->b0);
}

/* A free voice released longest ago, else the oldest note: */
static int allocate(fm *f)
{
    int best = -1;
    for (int n = 0; n < VOICES; n++)
        if (!f->v[n].on && (best < 0 || f->v[n].when < f->v[best].when))
            best = n;
    if (best >= 0)
        return best;
    best = 0;
    for (int n = 1; n < VOICES; n++)
        if (f->v[n].when < f->v[best].when)
            best = n;
    key_off(f, best);
    return best;
}

/* NOTES */

void fm_note_on(fm *f, int ch, int key, int vel)
{
    if (vel == 0)
    {
        fm_note_off(f, ch, key);
        return;
    }
    const uint8_t *ins;
    if (ch == 9)
    {
        if (key < DRUM_FIRST || key > DRUM_LAST)
            return;
        ins = instrument(128 + key - DRUM_FIRST);
    }
    else
        ins = instrument(f->c[ch].program);
    /* The same key again starts anew: */
    for (int n = 0; n < VOICES; n++)
        if (f->v[n].on && f->v[n].ch == ch && f->v[n].key == key)
            key_off(f, n);
    int flags = ins[0] | ins[1] << 8;
    int layers = (flags & F_DOUBLE) ? 2 : 1;
    for (int l = 0; l < layers; l++)
    {
        const uint8_t *p = ins + 4 + 16 * l;
        /* GENMIDI's notes are an octave below MIDI's: */
        int note = (flags & F_FIXED) ? ins[3] : key + (int16_t)(p[14] | p[15] << 8);
        note += 12;
        while (note < 0)
            note += 12;
        while (note > 127)
            note -= 12;
        int n = allocate(f);
        struct voice *v = &f->v[n];
        v->on = 1;
        v->held = 0;
        v->ch = ch;
        v->key = key;
        v->note = note;
        v->vel = vel;
        v->p = p;
        v->detune = l ? (ins[2] - 128) / 64.0 : 0;
        v->when = ++f->clock;
        int m = mod_reg(n);
        w(f, m + 0x20, p[0]);
        w(f, m + 0x60, p[1]);
        w(f, m + 0x80, p[2]);
        w(f, m + 0xE0, p[3]);
        w(f, m + 3 + 0x20, p[7]);
        w(f, m + 3 + 0x60, p[8]);
        w(f, m + 3 + 0x80, p[9]);
        w(f, m + 3 + 0xE0, p[10]);
        set_volume(f, n);
        set_pan(f, n);
        set_freq(f, n, 1);
    }
}

void fm_note_off(fm *f, int ch, int key)
{
    for (int n = 0; n < VOICES; n++)
    {
        struct voice *v = &f->v[n];
        if (!v->on || v->ch != ch || v->key != key)
            continue;
        if (f->c[ch].sustain)
            v->held = 1;
        else
            key_off(f, n);
    }
}

void fm_program(fm *f, int ch, int program)
{
    f->c[ch].program = program & 127;
}

static void update(fm *f, int ch, int what)
{
    for (int n = 0; n < VOICES; n++)
    {
        if (!f->v[n].on || f->v[n].ch != ch)
            continue;
        if (what == 0)
            set_volume(f, n);
        else if (what == 1)
            set_pan(f, n);
        else
            set_freq(f, n, 1);
    }
}

static void channel_defaults(struct channel *c)
{
    c->expression = 127;
    c->bend = 8192;
    c->sustain = 0;
    c->rpn = 0x3FFF;
}

void fm_control(fm *f, int ch, int ctl, int value)
{
    struct channel *c = &f->c[ch];
    switch (ctl)
    {
    case 7:
        c->volume = value;
        update(f, ch, 0);
        break;
    case 11:
        c->expression = value;
        update(f, ch, 0);
        break;
    case 10:
        c->pan = value;
        update(f, ch, 1);
        break;
    case 64:
        c->sustain = value >= 64;
        if (!c->sustain)
            for (int n = 0; n < VOICES; n++)
                if (f->v[n].held && f->v[n].ch == ch)
                    key_off(f, n);
        break;
    case 100:
        c->rpn = (c->rpn & 0x3F80) | value;
        break;
    case 101:
        c->rpn = (c->rpn & 0x7F) | value << 7;
        break;
    case 6:
        if (c->rpn == 0)
            c->range = value;
        break;
    case 38:
        if (c->rpn == 0)
            c->range = floor(c->range) + value / 100.0;
        break;
    case 121:
        channel_defaults(c);
        for (int n = 0; n < VOICES; n++)
            if (f->v[n].held && f->v[n].ch == ch)
                key_off(f, n);
        update(f, ch, 0);
        update(f, ch, 2);
        break;
    case 120:
    case 123:
    case 124:
    case 125:
    case 126:
    case 127:
        for (int n = 0; n < VOICES; n++)
            if (f->v[n].ch == ch)
                key_off(f, n);
        break;
    }
}

void fm_pitch_bend(fm *f, int ch, int value)
{
    f->c[ch].bend = value;
    update(f, ch, 2);
}

/* THE CHIP */

void fm_reset(fm *f)
{
    OPL3_Reset(&f->chip, (uint32_t)f->rate);
    w(f, 0x105, 0x01); /* OPL3 */
    w(f, 0x104, 0x00); /* no 4-operator voices */
    w(f, 0x001, 0x20);
    w(f, 0x0BD, 0x00);
    memset(f->v, 0, sizeof(f->v));
    for (int n = 0; n < VOICES; n++)
    {
        w(f, mod_reg(n) + 0x40, 63);
        w(f, mod_reg(n) + 3 + 0x40, 63);
        f->v[n].p = instrument(0) + 4;
    }
    for (int ch = 0; ch < 16; ch++)
    {
        struct channel *c = &f->c[ch];
        channel_defaults(c);
        c->program = 0;
        c->volume = 100;
        c->pan = 64;
        c->range = 2;
    }
    f->clock = 0;
}

fm *fm_new(int rate)
{
    fm *f = (fm *)calloc(1, sizeof(fm));
    if (f == NULL)
        return NULL;
    f->rate = rate;
    fm_reset(f);
    return f;
}

void fm_free(fm *f)
{
    free(f);
}

void fm_set_rate(fm *f, int rate)
{
    f->rate = rate;
    fm_reset(f);
}

void fm_render(fm *f, short *out, int frames)
{
    for (int i = 0; i < frames; i++)
        OPL3_GenerateResampled(&f->chip, out + 2 * i);
}

int fm_playing(fm *f)
{
    int n = 0;
    for (int i = 0; i < VOICES; i++)
        n += f->v[i].on;
    return n;
}
