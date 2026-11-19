# DOSBox

[DOSBox](https://www.dosbox.com) 0.74-3, the DOS PC emulator, as `C:\GAMES\DOSBOX.APP` on every edition, on ZDOS's partial SDL 1.2 ([ports/graphics/sdl12](../../graphics/sdl12/README.md)). GPL 2: a separate program, its license in `docs/COPYING/DOSBOX.TXT`.

```sh
ports/games/dosbox/build.sh             # all three CPUs (builds sdl12 first if missing)
ports/games/dosbox/build.sh x86_64      # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/dosbox` (`../dosbox` when that variable is unset; `DOSBOX_SRC=...`), left unchanged: `build.sh` copies them into `build/dosbox/tree` (`DOSBOX_BUILD=...`), applies `dosbox-zdos.patch`, puts `config.h` in as `include/config.h` (no `configure`) and compiles the `Makefile.am` files' sources with `zdos-c++` (C++03, objects in `build/dosbox/<arch>/`). The version for ZDOS is taken from `configure.ac`.

## Configuration

- CPU cores: the normal, simple, full and prefetch cores everywhere; the recompiler where 0.74-3 has one: `dynamic_x86` on x86 (BIOS edition), `dynrec` with its x86-64 backend on x86-64; ARM64 has none in 0.74-3 (only ARMv4 32-bit). `core=auto` / `dynamic` pick it.
- The recompilers write code into memory and run it. ZDOS's memory is executable unless `RW_NX=true` (metal x86-64, off by default). With the global variable `RW_NX` set to `true` (`SYSTEM.CFG` makes it), `core=auto` keeps to the normal core; anything else in `RW_NX`, or none, changes nothing. A core set in DOSBox's config (`dynamic`, `normal` ...) is used as set: `core=dynamic` under `RW_NX=true` ends DOSBox with a fault.
- FPU: emulated in C; x86 uses the x87 directly (`C_FPU_X86`).
- Sound: Sound Blaster (up to SB16), OPL2/3 (`dbopl`), Gravis Ultrasound, PC speaker, Tandy, Disney, the MPU-401 with General MIDI played by `C:\LIBS\MIDI.ZDL` (`mididevice=zdos`, the default: `midi_zdos.h`; FM, or the SoundFont with `SET MIDISYNTH=sf2` or a SoundFont's path in `midiconfig`; MT-32 music gets General MIDI's instruments). It needs a card's driver: HDA on metal (AC'97 on x86-64 too), HDA, AC'97 or SB16 on BIOS; UEFI plays silently.
- Not there: the debugger (curses), OpenGL output, the overlay output (no YUV overlays: `output=surface`), SDL_net (modem, IPX), SDL_sound (compressed CD audio images), screenshots and video capture to PNG (no libpng), joysticks, real CD-ROM drives (images work: `IMGMOUNT`).

`dosbox-zdos.patch`, and why:

- `include/cross.h`: `\` between folders (`CROSS_FILESPLIT`), names kept as they are: ZDOS paths (`D:\GAMES`).
- `src/misc/cross.cpp`: the config folder `%HOME%\.dosbox` (`~` followed by `\` or `/`).
- `src/dos/dos_programs.cpp`: `MOUNT C D:\GAMES\` without its last `\` for `stat` (`D:\` stays).
- `src/dos/drive_cache.cpp`: a drive's root keeps its `\` (`D:\`, not `D:`, which is the current folder of D:).
- `src/misc/setup.cpp`: paths in the config file with a drive letter are absolute.
- `src/gui/sdlmain.cpp`: `fullscreen=true` by default (the program's tab is the screen; it also locks the mouse at the start), `usescancodes=false`; the version for ZDOS.
- `src/gui/sdl_mapper.cpp`: scancodes never used: the partial SDL's are USB HID usages, the mapper's table knows X11's.
- `src/cpu/cpu.cpp`: `core=auto` without the recompiler when `RW_NX` is `true` (see above).
- `src/cpu/core_dyn_x86/risc_x86.h`: the return address of the recompiled code by `call` / `pop` instead of an absolute address (ZDOS programs are position independent); the flags it loads keep IF set.
- `src/cpu/core_dyn_x86.cpp`: the flags loaded after the guest's `POPF` keep IF set too. ZDOS programs run in ring 0, where `POPFD` changes IF: without it interrupts stop on that core.
- `src/gui/midi.cpp`: the MIDI device `midi_zdos.h` (MIDI.ZDL) instead of OSS's; `src/dosbox.cpp`: `mididevice` offers `zdos`.

## Use

```
DOSBOX                          Z:\ prompt; MOUNT C D:\GAMES, C:, ...
DOSBOX D:\GAMES\KEEN            mounts that folder as C:
DOSBOX D:\GAMES\KEEN\KEEN1.EXE  ... and runs it
DOSBOX -conf D:\DOSBOX.CONF     its settings and [autoexec] from that file
```

Without `-conf` DOSBox reads `dosbox.conf` in the current folder (any case: `D:\DOSBOX.CONF` when started in `D:\`), else `%HOME%\.dosbox\dosbox-0.74-3.conf` (`C:\USERS\<user>\.dosbox`), which it writes with the defaults on the first start; the key mapper's file (`mapper-0.74-3.map`) goes next to the config file read. `DOSBOX -printconf` tells where it is.

Keys: DOSBox's own. Ctrl+F10 frees the mouse (a click takes it again), Alt+Enter switches fullscreen (off: the mouse needs a click), Ctrl+F9 quits, Ctrl+F11 / Ctrl+F12 fewer / more cycles, Ctrl+F1 the key mapper, Alt+Pause pauses. `EXIT` at the prompt quits too.

## Display

- `output=surface` (the only one): DOSBox's picture as the SDL surface, which ZDOS centers and scales up by a whole number. `scaler=none` is enough (ZDOS scales), `normal2x` (the default) costs time for nothing; `fullresolution=original`.
- 8, 16 or 32 bits as DOSBox picks; the BIOS edition shows them in a true-color VESA mode (Warcraft II's 640×480 in 640×480); without VESA up to 320×200 in mode 13h, larger modes in 640×480 with 16 colors.

## Tests

`tests/ports/dosbox-tests.py` (metal-x86_64, `DOSBOX_DISK=...`).

## Open items

- Run: metal-x86_64 and bios-x86 (`dynamic_x86` with Warcraft II, sound on). `dynrec` on x86-64 and arm64 are built, not run by the tests.
