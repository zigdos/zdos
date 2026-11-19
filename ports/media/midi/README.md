# MIDI

General MIDI as a library, `C:\LIBS\MIDI.ZDL`, one copy for every program, with two synthesizers behind one API (`midi.h`):

- **FM** (the default): Nuked-OPL3 1.8, an emulated OPL3, with the instruments of Freedoom's `GENMIDI` lump, built into the library. `fm.c` drives it: 18 voices (a free one released longest ago, else the oldest note), GENMIDI's one- and two-voice instruments, F-number and block per note, pitch bend (and its range by RPN 0), volume, expression and velocity at 40 log, pan by the OPL3's left and right bits, the sustain pedal, all notes off, percussion on channel 10 from GENMIDI's entries for keys 35-81.
- **SoundFont**: TinySoundFont (`tsf.h`, `tml.h`) with a SoundFont 2, by default `C:\DATA\MIDI\GM.SF2`.

`midi_open(MIDI_DEFAULT, NULL)` takes `%MIDISYNTH%` (`fm` or `sf2`), else FM; with `sf2` and no SoundFont it plays FM. `MIDI_FM` and `MIDI_SF2` choose; the SoundFont is a path, `%MIDISF%` or `GM.SF2`. Songs are Standard MIDI Files (`midi_load`, `midi_load_memory`), rendered with `midi_render` (16-bit) or `midi_render_float`, mixed in or not; raw events go through `midi_note_on` ... or as bytes off a cable through `midi_write`.

```sh
ports/media/midi/build.sh             # all three CPUs
ports/media/midi/build.sh x86_64      # one or more: x86, x86_64, arm64
MIDI_SF2_MB=16 ports/media/midi/build.sh   # a bigger, better GM.SF2
zig build                             # puts them onto drive C:
```

Programs link `-lMIDI` (import stubs in `build/sdk-ports`); `PLAY` (Zig) and Abuse use it.

## Sources

All only read; objects in `build/midi/<arch>/`.

- TinySoundFont: `$ZDOS_PORTS_SRC/TinySoundFont` (`TSF_SRC=...`), commit `853a0a171759f1ddba0de1442133a75912bbeffa` (2026-07-19).
- Nuked-OPL3: `$ZDOS_PORTS_SRC/Nuked-OPL3` (`OPL3_SRC=...`), commit `765ec962e473aeb767e4cba74ffdc8f588ffbfe8` (2026-08-24).
- `GENMIDI`: read out of `$ZDOS_PORTS_SRC/freedoom/freedoom2.wad` (`FREEDOOM=...`, as the Doom port) into `build/midi/genmidi.h`.
- FluidR3 GM: `/usr/share/soundfonts/FluidR3_GM.sf2` (`SF2_SRC=...`), Fedora's `fluid-soundfont-gm`. Without it `GM.SF2` isn't made and the library plays FM only. `FluidR3_GS.sf2` (`fluid-soundfont-gs`) is no GM set: 33 GS variation presets (banks 1-8, mostly sound effects) and an effects kit.

The version for ZDOS is taken from `tsf.h`'s first line (TinySoundFont v0.9).

## GM.SF2

`sf2reduce.py` (Python 3 with numpy) makes it from FluidR3_GM, `MIDI_SF2_MB` megabytes at most (8), into `build/DATA/MIDI`:

- bank 0's programs 0-127 and the standard drum kit (128:0, keys 35-81); the GS variations and other kits dropped;
- per key one velocity layer (100's, one that sounds at once), the layers' generators made the instrument's own, no modulators (TinySoundFont has none);
- stereo pairs kept as two zones, each sample panned as recorded (`--stereo`; `MIDI_SF2_MONO=1`: mixed to mono, as loud in each ear as before);
- a few key zones per instrument spread over its range and stretched to 0-127;
- a sample's attack cut short with a new loop of whole periods (crossfaded) and the old decay moved into the volume envelope; unlooped samples cut with a fade;
- 22050 or 16000 Hz, resampled with a windowed sinc, a loop's length kept whole.

`LEVELS` in the script lists how far each step goes; the first that fits the size is used (8 MB stereo: 3 zones, 16000 Hz, 0.45 s attacks, 6.8 MB; 4 MB mono: 3 zones, 0.35 s attacks, 3.8 MB).
