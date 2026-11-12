# DGen

[DGen/SDL](https://sourceforge.net/projects/dgen) 1.33, a Sega Genesis / Mega Drive emulator, as `C:\GAMES\DGEN.APP` on every edition, on ZDOS's partial SDL 1.2 ([ports/graphics/sdl12](../../graphics/sdl12/README.md)).

License: its Musashi (68000) and CZ80 (Z80) cores may be used for non-commercial purposes only, so `DGEN.APP` as a whole is for non-commercial use (`docs/COPYING/DGEN.TXT`).

```sh
ports/games/dgen/build.sh             # all three CPUs (builds sdl12 first if missing)
ports/games/dgen/build.sh x86_64      # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/dgen` (`../dgen` when that variable is unset; `DGEN_SRC=...`), left unchanged: `build.sh` copies them into `build/dgen/tree` (`DGEN_BUILD=...`), applies `dgen-zdos.patch`, generates what `make` would (Musashi's opcode handlers with `m68kmake`, the message bar's fonts with `pbm2df`; both built with the host's `cc`, `HOSTCC=...`), and compiles with `zdos-cc` / `zdos-c++` (objects in `build/dgen/<arch>/`). No `configure`: `config.h` is given to every source (`-include`).

## Configuration

- CPU cores in C: Musashi (68000) and CZ80 (Z80). No assembler (StarScream, MZ80, Cyclone, DrZ80, the x86 tiles, MMX and Crap TV routines).
- Sound (YM2612 FM and the PSG), 44100 Hz stereo 16-bit; the card's driver converts to its rate.
- Save states, battery RAM, `dgenrc`, the prompt (`:`), Game Genie codes (F9), screenshots (F12), the "Crap TV" and scale2x filters, the screen thread (`bool_screen_thread`, off by default).
- Not there: OpenGL, joysticks, compressed ROMs (libarchive), the debugger (needs `termios` line editing), hqx (its 64 MB lookup table is static data, more than a program may have).
- DGen always emulates a 6-button pad; games that don't know it read it as a 3-button one.

`dgen-zdos.patch`:

- `system.h`, `system.c`: ZDOS paths: `\` as well as `/` between folders, `C:\...` absolute (Windows's rules, which DGen has for MinGW), so ROMs and save states get the right names.
- `rc-vars.h`, `rc.cpp`: ZDOS's default keys (below), and a second key for each of pad 1's controls (`key2_pad1_up` ... in `dgenrc`; W A S D, the keypad); pad 2 without keys (the keypad is pad 1's); the message bar 13 lines (the 8×13 font), none on BIOS.
- `main.cpp`: drops the `bind_w = key_pad1_up` ... entries an earlier ZDOS build wrote into `dgenrc.auto` (its second keys, which as DGen key combinations didn't combine with other held keys).
- `sdl/sdl.cpp`: a 320-wide picture (ZDOS scales it to the screen, DGen's own 2× would only cost time), the same scale when a PAL game switches to 240 lines; `pressed` declared without joystick support (upstream doesn't build without it); the second keys checked beside the first ones. Releases of bound keys (`bind_*` with a `key_*` action): DGen took a key out of its list of held keys before looking for the `bind_*` entries it ends, so they never matched and the bound button stayed pressed; the released key now counts while they are looked at. `-DZDOS_PAD_LOG` (for tests only) prints pad 1's changes on `stderr`.
- `md.cpp`: the region of later carts, whose header has a hex digit (`4`: Americas, `1` Japan, `8` Europe) instead of letters; without it DGen took them for Japanese and they stopped at "for NTSC Genesis systems only".
- `vdp.cpp`: VRAM fill (DMA) as the VDP does it: the word written normally, then its high byte at each next address ^ 1 (DGen wrote whole words). Contra: Hard Corps fills single bytes of the H scroll table so; its backgrounds were mangled from level 1 on (upstream's `BUGS`).

## Use

```
DGEN D:\ROMS\SONIC.BIN
DGEN -R U GAME.MD          region (J, U, E) when the header misleads
DGEN -s 0 GAME.BIN         starting from save state slot 0
```

ROMs: plain `.bin`, `.gen`, `.md`, `.smd` (not zipped), given by path, or by name from `%HOME%\.dgen\roms\`. DGen keeps its files in `%HOME%\.dgen\` (`C:\USERS\<user>\.dgen`): `dgenrc` (made on the first start, the settings: see DGen's `dgenrc.5` and `sample.dgenrc`), `dgenrc.auto` (written at the end), `saves\` (save states `NAME.gs0`-`gs9`), `ram\` (battery RAM), `screenshots\`.

Keys (pad 1):

| Genesis | Keys                   |
| ------- | ---------------------- |
| D-pad   | arrows, or W A S D     |
| A B C   | J K L, or keypad 4 5 6 |
| X Y Z   | U I O, or keypad 7 8 9 |
| Start   | Enter, or keypad Enter |
| Mode    | Backspace              |

The keypad works with Num Lock on or off (on BIOS and metal; UEFI's firmware reports keypad keys as digits or arrows). DGen's own keys: Esc quits, F2 saves and F3 loads the state of the current slot (0-9 pick it, F7 / F8 step), Tab resets, F1 fixes the checksum, F5 Crap TV, F6 the scaler, F9 Game Genie, F10 / F11 switch Z80 / 68000 core, F12 screenshot, `z` pauses, `:` opens the prompt (`quit`, `load`, `reset`, setting variables), `=` / `-` volume. Shift+letter is another key (`J` is not `j`).

## Display

- UEFI and metal: 32-bit, the 320×224 picture and the message bar (frames per second with `bool_fps = true`, messages such as "Saved state to slot 0."), scaled up by a whole number to the screen.
- BIOS: VGA mode 13h, 320×200 in 256 colors: DGen's 8-bit output (the Genesis shows up to 64 colors at once, set with `SDL_SetColors`), and of the 224 lines the middle 200 (12 cut at the top, 12 at the bottom; PAL's 240: 20 and 20), as DOS-era emulators did, instead of shrinking the picture. There is no message bar: the partial SDL 1.2 does the crop (any 8-bit 320×201-240 picture on VGA).
- Sound needs a card's driver: HDA on the metal editions (also AC'97 on x86-64), HDA, AC'97 or SB16 on BIOS; the UEFI editions have none, DGen plays silently there.

## Tests

Run by hand in QEMU with ROMs on a FAT test disk: full speed on metal-x86_64 and bios-x86.
