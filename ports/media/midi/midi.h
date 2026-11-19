/* MIDI.ZDL: General MIDI synthesis, FM (OPL3) or SoundFont.
 * A midi handle is used by one thread at a time: a program that
 * renders on a sound thread locks around the other calls. */
#ifndef MIDI_H
#define MIDI_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct midi midi;

/* SYNTHESIZERS */
enum {
    MIDI_DEFAULT = 0, /* %MIDISYNTH% (fm or sf2), else FM */
    MIDI_FM = 1,      /* OPL3 with a built-in bank */
    MIDI_SF2 = 2      /* a SoundFont 2 */
};

/* soundfont: for SF2, NULL for %MIDISF% or C:\DATA\MIDI\GM.SF2.
 * MIDI_DEFAULT falls back to FM without the SoundFont; MIDI_SF2
 * gives NULL then. */
midi *midi_open(int synth, const char *soundfont);
midi *midi_open_memory(const void *sf2, int size);
void midi_close(midi *m);
/* MIDI_FM or MIDI_SF2 */
int midi_synth(midi *m);

/* rate 8000-96000 Hz, channels 1 or 2 (44100 stereo at first);
 * 0, or -1 for a bad value */
int midi_set_output(midi *m, int rate, int channels);
/* 0-400 percent (100 at first) */
void midi_set_volume(midi *m, int percent);

/* SONGS: a Standard MIDI File (format 0 or 1); 0, or -1 */
int midi_load(midi *m, const char *path);
int midi_load_memory(midi *m, const void *data, int size);
/* The song gone, all notes off: */
void midi_stop(midi *m);
void midi_restart(midi *m);
void midi_set_loop(midi *m, int loop);
/* 1 when the song has ended and died away (or there is none) */
int midi_finished(midi *m);
unsigned midi_length_ms(midi *m);
unsigned midi_position_ms(midi *m);

/* RENDERING: frames of the output's channels, interleaved; mix:
 * added to what out holds. Plays the song's events on the way. */
void midi_render(midi *m, short *out, int frames, int mix);
void midi_render_float(midi *m, float *out, int frames, int mix);

/* EVENTS: channel 0-15 (9 is percussion), values 0-127 */
void midi_note_on(midi *m, int channel, int key, int velocity);
void midi_note_off(midi *m, int channel, int key);
void midi_program(midi *m, int channel, int program);
void midi_control(midi *m, int channel, int controller, int value);
/* 0-16383, 8192 the middle */
void midi_pitch_bend(midi *m, int channel, int value);
void midi_channel_pressure(midi *m, int channel, int value);
/* MIDI bytes as on a cable (running status; system exclusive,
 * common and real-time messages are skipped): */
void midi_write(midi *m, const unsigned char *bytes, int len);
/* All sounds off, every channel as at the start: */
void midi_reset(midi *m);

#ifdef __cplusplus
}
#endif

#endif
