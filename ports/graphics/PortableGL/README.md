# PortableGL

[PortableGL](https://github.com/rswinkle/PortableGL) 0.101, a software OpenGL 3.x core-like API whose shaders are C (or C++) functions, in one header, `portablegl.h`. `build.sh` copies it into `build/sdk-ports/include/`, where `zdos-cc` finds it; one file of the program defines `PORTABLEGL_IMPLEMENTATION` before including it. Nothing in it is changed.

```sh
ports/graphics/PortableGL/build.sh                  # the header
ports/graphics/PortableGL/build.sh --demos          # also the demos, all three CPUs
ports/graphics/PortableGL/build.sh --demos x86_64   # one or more: x86, x86_64, arm64
```

Sources: `$ZDOS_PORTS_SRC/PortableGL` (`../PortableGL` when that variable is unset; `PORTABLEGL_SRC=...`), used as they are; demos are built into `build/PortableGL/<arch>/` (`PORTABLEGL_BUILD=...`).

## Showing frames

PortableGL draws into a back buffer it allocates (`init_glContext(&ctx, &buf, w, h)`). With `PGL_ARGB32` defined before the include its pixels are `0x00RRGGBB`, ZDOS's `XRGB8888`, and go to the screen as they are; PortableGL's default `PGL_ABGR32` is `ZDOS_PIXELS_XBGR8888` (converted), `PGL_RGB565` `ZDOS_PIXELS_RGB565`.

```c
#define PGL_ARGB32
#define PORTABLEGL_IMPLEMENTATION
#include <portablegl.h>
#include "zdos_media.h"

init_glContext(&ctx, &buf, w, h);
zdos_display_open(w, h, ZDOS_PIXELS_XRGB8888);
for (;;) {
    /* glClear, glDrawArrays ...; zdos_input_poll for keys and the mouse */
    zdos_display_present(buf, w * sizeof(pix_t));
}
```

Programs written for SDL 2, as PortableGL's examples are, build with the SDL port (`ports/graphics/SDL`): `zdos-cc -Ibuild/sdk-ports/include/SDL2 ex.c -lSDL2` (their streaming texture is converted to SDL's window surface).

## Demos

`--demos` builds into `build/PortableGL/<arch>/pgl/demos/`, with the textures where they look for them (`<arch>/media/textures`, `<arch>/pgl/media/textures`): copy the `<arch>` folder's contents to a drive and run them from `PGL\DEMOS`.

- `PGLCUBE [width height]` (`zdos/pglcube.c`): a spinning cube lit by its fragment shader, on `zdos_media.h` alone (no SDL); dragging with the mouse turns it, Space stops the spin.
- On SDL 2 (when `build/sdk-ports/lib/<arch>/libSDL2.a` is there), upstream's unchanged: `EX1` (a triangle), `EX2` (colors interpolated), `EX3` (a spinning triangle), `GEARS` (the classic gears), `LESSON6` (learningwebgl's textured crate: arrows turn it, F the filter, PgUp/PgDn the distance), `SHADERTOY` (eleven Shadertoy-style fragment shaders at 320×240: Left / Right switch). The C++ ones (`LESSON6` with GLM, `SHADERTOY`) build with `zdos-c++`; `LESSON6` changes to its own folder with `my_chdir`, defined only for Linux and Windows, so `build.sh` defines it as `chdir`.

They print frames per second (`GEARS > G.TXT`); Esc ends them. Each SDL one carries SDL (about 1 MB).

Frames per second in QEMU (640×480, `SHADERTOY` 320×240 with its first shader; x86-64 under KVM, the others emulated):

| Demo      | metal-x86_64 | uefi-x86_64 | metal-arm64 | bios-x86            |
| --------- | ------------ | ----------- | ----------- | ------------------- |
| PGLCUBE   | 183          | 175         | 14          | 3.5 (22 at 320×200) |
| EX2       | 290          | 310         | 24          | 6                   |
| GEARS     | 240          | 270         | 22          | 5.5                 |
| LESSON6   | 158          | 157         | 11          | 3                   |
| SHADERTOY | 310          | 390         | 30          | 6.6                 |

`EX1` and `EX3`: 320 and 430 on metal-x86_64. On BIOS 640×480 is a true-color VESA mode; without VESA it is VGA's 16 colors (mode 12h), where the crate's browns come out green, and `PGLCUBE 320 200` uses mode 13h.
