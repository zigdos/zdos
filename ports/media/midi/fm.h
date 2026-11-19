/* The FM synthesizer: General MIDI on an emulated OPL3 */
#ifndef FM_H
#define FM_H

typedef struct fm fm;

fm *fm_new(int rate);
void fm_free(fm *f);
void fm_set_rate(fm *f, int rate);
void fm_reset(fm *f);
void fm_note_on(fm *f, int ch, int key, int vel);
void fm_note_off(fm *f, int ch, int key);
void fm_program(fm *f, int ch, int program);
void fm_control(fm *f, int ch, int ctl, int value);
void fm_pitch_bend(fm *f, int ch, int value);
/* frames of stereo 16-bit: */
void fm_render(fm *f, short *out, int frames);
/* Voices keyed on: */
int fm_playing(fm *f);

#endif
