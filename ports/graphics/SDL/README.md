# SDL 2

[SDL](https://libsdl.org) 2.33 as a library, `C:\LIBS\SDL2.ZDL` (a copy per program), which programs load through its import stubs (`zdos-cc game.c -lSDL2`); or linked into the program (`-lSDL2-static`). Video, events, audio, threads, timers and SDL's software renderer (`SDL_Renderer`); no OpenGL.

```sh
ports/graphics/SDL/build.sh                  # all three CPUs
ports/graphics/SDL/build.sh x86_64           # one or more: x86, x86_64, arm64
ports/graphics/SDL/build.sh --tests x86_64   # also SDL's test programs
```

Sources: SDL 2 in `$ZDOS_PORTS_SRC/SDL` (`../SDL` when that variable is unset; `SDL_SRC=...`), left unchanged: `build.sh` copies its `src` and `include` into `build/SDL/tree` (`SDL_BUILD=...`), applies `sdl-zdos.patch`, adds this folder's `src/` and `SDL_config_zdos.h` (as `SDL_config.h`), and compiles there with the `Makefile` (objects in `build/SDL/<arch>/`; needs `rsync`, `patch` and `make`). `SDL2.ZDL` goes into `build/<edition>/LIBS_3RD` (C:\LIBS on the image). It installs into `build/sdk-ports/`, which `zdos-cc` searches:

- `lib/<arch>/libSDL2.a` (import stubs), `libSDL2-static.a` (all of SDL), `libSDL2_test.a` (SDL's test framework), `libSDL2main.a` (empty: ZDOS calls `main` itself, SDL's `main` is the program's);
- `include/SDL2/`: SDL's headers, `SDL_config.h` being ZDOS's;
- `bin/sdl2-config` (`--cflags`, `--libs`) for build scripts.

```sh
zdos-cc -O2 -Ibuild/sdk-ports/include/SDL2 game.c -lSDL2 -o GAME.APP   # #include "SDL.h"
zdos-cc -O2 game.c -lSDL2 -o GAME.APP                                  # #include <SDL2/SDL.h>
```

## What is ZDOS's

On the SDK's display, input and sound glue (`sdk/src/zdos_media.h`, [sdk/README.md](../../../sdk/README.md#display-input-and-sound-zdos_mediah)):

- `src/video/zdos/`: one window, shown full-screen in the program's tab: its framebuffer (`SDL_PIXELFORMAT_RGB888`) goes to `zdos_display_present`, scaled to fit the screen if larger, centered (and on UEFI and metal scaled up by a whole number) if smaller; on BIOS dithered to VGA mode 13h or 12h. Display modes: the screen's (`gfx->screen`, desktop) and `gfx->modes`; a fullscreen mode is the window's size, not a mode switch. The title is the tab's name. Events in `PumpEvents`: keys with SDL scancodes, text input (`SDL_TEXTINPUT`), the mouse (relative mode: ZDOS's mouse moves; the pointer is an arrow drawn into the picture), the tab going behind another (Alt+Tab: focus lost, minimized) and coming back (restored, focus). A second window fails.
- `src/audio/zdos/`: SDL's audio thread writes into `sound->write`, then waits until at most one of its buffers is queued (the card's queue holds about a third of a second; players such as ffplay take SDL's latency to be about two buffers, so a full queue put the sound 0.3 s behind the picture): 8-bit unsigned or 16-bit signed, mono or stereo, 8000-192000 Hz (SDL converts the rest). Without a card's driver (`HDA.SYS`, `AC97.SYS`, `SB16.SYS`) SDL's audio fails to start.
- `src/timer/zdos/`: ticks from `time->millis` (1 ms); `SDL_Delay` is `time->sleep`, which Ctrl+C ends.
- `src/filesystem/zdos/`: `SDL_GetBasePath` is the program's folder (`C:\GAMES\`), `SDL_GetPrefPath(org, app)` `C:\DATA\org\app\` on the program's drive.
- `SDL_config_zdos.h`: what the C library has; pthreads (cooperative on UEFI), dummy joystick, haptic, sensor, power, loadso, locale and misc; no dynamic API (`sdl-zdos.patch` turns it off and adds the drivers to SDL's lists); no signal handlers, so Ctrl+C ends an SDL program as any other.

## Limits

- One window; no OpenGL, Vulkan, joysticks, clipboard, message boxes, IME.
- UEFI has no key releases: a key counts as pressed while the keyboard repeats it (the first release about 300 ms after a tap), its scancode from the US layout of the character; modifiers come with the keys they are pressed with.
- Text input comes after the key events it was typed with, not between them.

## SDL2.ZDL

- The export table (`sdl2_zdl.c`) is SDL's own dynamic API list, `src/dynapi/SDL_dynapi_procs.h`, as ZDOS's configuration selects it (836 functions, the same on every CPU); `build.sh` makes the stubs from the same list. SDL only adds to its end, so a newer `SDL2.ZDL` serves older programs.
- A copy per program: SDL's globals (its window, audio device, events) are each program's. It has the SDK's C library inside, but its threads, pthread keys, `errno` and signal handlers are the program's (the program's start-up offers its C runtime to the libraries it loads, `sdk/src/zdos_internal.h`): SDL's audio and timer threads get the program's `thread_local` data, so C++ or Rust code in a callback works. Descriptors and `FILE` streams stay apart (`SDL_RWFromFP` with a program's `FILE` doesn't work; `SDL_RWFromFile` does).
- Sizes: `SDL2.ZDL` 880 KB (arm64) to 1040 KB (x86-64); SDL's tests 120-175 KB each instead of 750-930 KB; ZSNES 2.5 MB instead of 3.2 MB.

## Tests

`build.sh --tests` builds SDL's own test programs (`TESTSPRITE2`, `TESTKEYS`, `LOOPWAVE` ...); they log to `stderr`.
