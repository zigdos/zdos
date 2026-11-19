# Abuse

Abuse 0.8, Crack dot Com's 1995 side-scrolling shooter in its SDL version, as `C:\GAMES\ABUSE.APP`, on ZDOS's partial SDL 1.2 ([ports/graphics/sdl12](../../graphics/sdl12/README.md)). Its data is in `C:\DATA\ABUSE`.

```sh
ports/games/abuse/build.sh             # all three CPUs (builds sdl12 and midi first if missing)
ports/games/abuse/build.sh x86         # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/abuse` (`../abuse` when that variable is unset; `ABUSE_SRC=...`), left unchanged: `build.sh` copies them into `build/abuse/tree` (`ABUSE_BUILD=...`), applies `abuse-zdos.patch`, adds `config.h` (no `configure`), `zdos-abuse.cpp` and `sound-zdos.cpp`, and compiles with `zdos-c++` (objects in `build/abuse/<arch>/`). The game's `data` folder goes to `build/DATA/ABUSE`. The version for ZDOS is taken from `configure.ac`.

## Configuration

- 320×200 in 256 colors, one picture a frame (`doublebuf=1`), not scaled by Abuse (`scale=1`): ZDOS scales it on UEFI and metal, BIOS shows it in a true-color VESA mode (without VESA in VGA mode 13h).
- Sound without SDL_mixer: `sound-zdos.cpp` mixes the WAV files itself, 22050 Hz stereo, and the music: Abuse's HMI songs turned into MIDI by its own `sdlport/hmi.cpp`, played by `MIDI.ZDL` ([ports/media/midi](../../media/midi/README.md)), FM unless `MIDISYNTH=sf2`. A song plays once and Abuse starts it again; `-music_volume 0-127` and the volume window set its loudness, `-nosound` turns it off with the effects.
- No OpenGL, joysticks or screen icon.
- Built with `-fno-delete-null-pointer-checks`: Abuse's Lisp calls methods on `NULL` (nil) and tests `this`, which clang otherwise drops.

`abuse-zdos.patch`:

- `sdlport/setup.cpp`: the data folder `..\DATA\ABUSE` beside `ABUSE.APP`'s folder (else that folder; `-datadir`, `ABUSE_PATH` and `datadir=` still choose another), saves and `abuserc` in `%HOME%\.abuse\`, the defaults above, Ctrl+C as a key (right Ctrl changes weapons).
- `imlib/specs.cpp`, `game.cpp`, `net/fileman.cpp`: `C:\...` is an absolute path, not one under the data folder (the saves); `open_FILE` put a space between folder and name; the save folder's name was allocated a byte short.
- `lisp/lisp.cpp`: `LObject::Eval` gives `PtrRef` a variable, not `this`: it kept the address of a temporary gone after its constructor, and with clang the GC took that stack slot (Lisp text) for an object ("collecting bad object" while loading `abuse.lsp`).
- `lol/timer.cpp`: the `gettimeofday` timer, not SDL's milliseconds.
- `net/tcpip.h`: no System V headers.
- `sdlport/sound.h`: no SDL_mixer types. `sdlport/video.cpp`: no icon (no `SDL_LoadBMP`). `sdlport/event.cpp`: Print Screen saves `screen.bmp` in the save folder (no `SDL_SaveBMP`).
- `chat.cpp`: the chat window at the screen's bottom (its height in pixels, not lines).

## Use

```
ABUSE
ABUSE -nosound
ABUSE -edit                level editor
ABUSE -datadir D:\ABUSE    other data
```

Arrows move, Up jumps, Down uses; the mouse aims, its left button fires, the right one is the special power; right Ctrl and Insert, `,` and `.`, the digits or the wheel change weapons; Esc is the menu. `abuserc` sets the keys (Abuse's README). Larger pictures (`-size 640 480`) work on every edition; on BIOS if no VESA they get VGA's 16-color mode. Sound needs a card's driver (the UEFI editions have none).
