# TinyGL

[TinyGL](https://github.com/C-Chads/tinygl), C-Chads' fork of Fabrice Bellard's software OpenGL 1.1 subset (fixed function: lighting, textures up to 256×256, display lists, blending, polygon stipple, `glDrawText`), as a static library, `libTinyGL.a`, linked into each program.

```sh
ports/graphics/tinygl/build.sh                  # all three CPUs
ports/graphics/tinygl/build.sh x86_64           # one or more: x86, x86_64, arm64
ports/graphics/tinygl/build.sh --demos x86_64   # also TinyGL's demos
```

Sources: `$ZDOS_PORTS_SRC/tinygl` (`../tinygl` when that variable is unset; `TINYGL_SRC=...`), compiled as they are, no patch (objects in `build/tinygl/<arch>/`). It installs into `build/sdk-ports/`, which `zdos-cc` searches:

- `lib/<arch>/libTinyGL.a` (0.8-1.2 MB; a program takes what it uses: `GEARS` is 200 KB);
- `include/tinygl/`: `GL/gl.h`, `zbuffer.h`, `zfeatures.h`, as TinyGL's `make install` puts them.

Built as upstream's Makefile does, with 32-bit pixels (`zfeatures.h`), without `-march=native` and OpenMP (its `#pragma omp` are ignored: one core).

## Showing frames

TinyGL draws into its `ZBuffer`; a 32-bit one is `0x00RRGGBB`, ZDOS's `XRGB8888`, so its buffer goes to the screen as it is:

```c
#include <tinygl/GL/gl.h>
#include <tinygl/zbuffer.h>
#include "zdos_media.h"

ZBuffer *zb = ZB_open(640, 480, ZB_MODE_RGBA, 0);
glInit(zb);
zdos_display_open(640, 480, ZDOS_PIXELS_XRGB8888);
for (;;) {
    /* glClear, draw ... ; zdos_input_poll for keys and the mouse */
    zdos_display_present(zb->pbuf, zb->linesize);
}
```

```sh
zdos-cc -O2 demo.c -lTinyGL -o DEMO.APP
```

A larger picture than the screen is scaled down, a smaller one centered (and scaled up on UEFI and metal); the BIOS edition dithers it to VGA mode 13h (up to 320×200) or 12h. A 16-bit TinyGL (`TGL_FEATURE_16_BITS` in `zfeatures.h`, rebuilt) would be `ZDOS_PIXELS_RGB565`.

## Demos

`--demos` builds TinyGL's `SDL_Examples` unchanged: `GEARS`, `TEXTURE`, `HELLOWORLD`, `MODEL`, `MENU`, `GAME`, into `build/tinygl/<arch>/demos/` with their textures and models (they load them from the current folder). They are written for SDL 1.2 and linked with ZDOS's partial SDL 1.2 (`-lSDL`, [ports/graphics/sdl12](../sdl12/README.md), built first if missing). `-w 320 -h 200` sets the size (BIOS: mode 13h); they print frames per second every 5 seconds (`GEARS > G.TXT`). Esc or Q ends them.

Frames per second in QEMU (640×480; BIOS 320×200 in mode 13h; x86-64 under KVM, the others emulated):

| Demo       | metal-x86_64 | uefi-x86_64 | metal-arm64 | bios-x86 |
| ---------- | ------------ | ----------- | ----------- | -------- |
| GEARS      | 600          | 875         | 65          | 88       |
| TEXTURE    | 375          | 480         | 36          | 35       |
| MODEL      | 290          | 320         | 17          | 5        |
| HELLOWORLD | 600          | 900         | 70          | 200      |

`MENU` and `GAME` are built but untested. No sound (the demos' music needs SDL_mixer, left out upstream by default).
