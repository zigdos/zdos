# ZSNES

[ZSNES 2](https://github.com/xyproto/zsnes) 2.3.8, a Super Nintendo emulator (xyproto's fork, its x86 assembler ported to C), as `C:\GAMES\ZSNES.APP` on every edition, on SDL 2 ([ports/graphics/SDL](../../graphics/SDL/README.md)), loaded from `C:\LIBS\SDL2.ZDL`.

License: GPL version 2 (`docs/COPYING/ZSNES.TXT`). `ZSNES.APP` is a program of its own; nothing of it goes into ZDOS or the SDK.

```sh
ports/games/zsnes/build.sh             # all three CPUs (builds SDL 2 first if missing)
ports/games/zsnes/build.sh x86_64      # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/zsnes` (`../zsnes` when that variable is unset; `ZSNES_SRC=...`), left unchanged: `build.sh` copies them into `build/zsnes/tree` (`ZSNES_BUILD=...`; without `.git`, `server`, `win`, `macos`), applies `zsnes-zdos.patch`, makes the config file readers from the `.psr` files with `parsegen.py` (`python3`, `PYTHON=...`), and compiles with `zdos-cc` (objects in `build/zsnes/<arch>/`). No Makefile: `config.h` is given to every source (`-include`), the sources are the Makefile's for its Unix/SDL build. The version for ZDOS is taken from `ver.h`.

## Configuration

- ZSNES 2 is written for SDL 3; ZDOS has SDL 2. `SDL3/SDL.h` (ZDOS's, under ZDOS's license) maps the SDL 3 calls ZSNES makes onto SDL 2: renamed functions, SDL 3's `bool` results, its event layout (translated in `SDL_PollEvent`), its audio stream as SDL 2's audio queue. ZSNES's own files are untouched by that.
- Software video only (no OpenGL): the 256×224, 512×448 and 640×480 modes (Config > Video); the filters (NTSC, 2xSaI, hqx ...) are scaled to the window. The default, as upstream's without OpenGL, is 512×448; ZDOS centers it and scales it up by a whole number (on screens under 896 lines it stays 1×: mode 0, 256×224, is 3× on 800 lines).
- BIOS: a true-color VESA mode, as on UEFI and metal. Without VESA, VGA mode 13h, 320×200 in 256 colors, whatever the video mode (no filters): the 256-wide picture centered, of its 224 lines the middle 200 (12 cut at the top, 12 at the bottom), as DOS-era emulators did. A frame's colors go into the palette as they are (up to 255 and black; beyond that the most frequent, the rest the nearest of them). The GUI's 224 lines follow the mouse: the menu bar is on the screen while the pointer is at the top, a dialog's bottom when it is at the bottom.
- Sound through SDL (32 kHz, SDL converts for the card); no PipeWire or libao. Netplay (TCP or UDP, port 7845; IPv4 only). No PNG screenshots (no libpng), debugger, joysticks (ZDOS has none) or OpenGL.

`zsnes-zdos.patch`, and why:

- `gblhdr.h`: `unistd.h` on ZDOS too (it was for `__unix__`).
- `gui/guifuncs.c`: Game > Load lists the drives (`[C:]`, `[D:]` ...) under the folders, as on Windows (it was Windows-only); `GetLogicalDrives` comes from `zdos->drives->letters`.
- `zpath.h`, `zpath.c`: ZDOS's paths are DOS's (`C:\GAMES`, as `getcwd` and `realpath` give them): `\` between folders, `C:\` the root, a drive letter absolute (the Windows build's rules). The settings folder is `%HOME%\.zsnes`, made if missing (Unix's `~/.config/zsnes` with `/` didn't fit them; the first start crashed writing `zfont.txt` there).
- `unix/sw_draw.c`, only for x86 (`zsnes-zdos-vga.patch`, built as `unix/sw_draw_vga.c`): on a BIOS without VESA (no true color) the frame goes to mode 13h through `gfx` itself (SDL 2's window is true color, which ZDOS would dither to 640×480 in 16 colors); SDL's window surface is still made once, for the mouse's area.
- `unix/net_transport.c`: IPv4 sockets where there is no IPv6 (`in6addr_any`, `IPV6_V6ONLY`).

## Use

```
ZSNES D:\ROMS\GAME.SFC
ZSNES                      the GUI, Game > Load
```

ROMs: `.sfc`, `.smc` and the other formats ZSNES knows, also zipped. ZSNES keeps its files in `%HOME%\.zsnes\` (`C:\USERS\<user>\.zsnes`): `zsnesl.cfg` (settings), `zinput.cfg` (keys), battery RAM (`.srm`) and save states (`.zst`) by the ROM's name. Esc opens the GUI (mouse and keys: arrows, Enter; Game > Quit ends ZSNES).

Keys (player 1, ZSNES's defaults; Config > Input changes them):

| SNES          | Keys               |
| ------------- | ------------------ |
| D-pad         | arrows             |
| A B X Y       | X Z S A            |
| L R           | D C                |
| Start, Select | Enter, Right Shift |

F2 saves and F4 loads the state of the current slot (F3 picks it), Esc the GUI.

Netplay: Netplay > Internet; the host presses Host (TCP: untick Use UDP first, `U`), the other side types the host's address and presses Join; both need the same ROM. ZDOS needs a network (`NETWORK=true`, docs/NETWORK.md); behind QEMU's user network forward the port (`hostfwd=tcp::7845-:7845`). ZSNES also asks a STUN server (Google's) for the outside address it shows.

## Tests

Run by hand in QEMU with ROMs on a FAT test disk: full speed on metal-x86_64 and bios-x86.
