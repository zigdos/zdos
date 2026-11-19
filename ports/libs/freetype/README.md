# FreeType

[FreeType](https://freetype.org) 2.15.0 as a library: `C:\LIBS\FREETYPE.ZDL`, one copy for every program. It draws TrueType and OpenType fonts (`.ttf`, `.otf`) and others, smoothed, at any size. Zig programs use it through `apps/zdos/freetype.zig`; its test is `TTFTEST` (`apps/ttftest.zig`).

```sh
ports/libs/freetype/build.sh             # all three CPUs
ports/libs/freetype/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                                # puts them onto drive C:
```

Sources: FreeType's release, unpacked unchanged into `$ZDOS_PORTS_SRC/freetype` (`../freetype` when that variable is unset; `FREETYPE_SRC=...`). Objects: `build/freetype/<arch>/`; the sources are only read. The version for ZDOS is taken from `freetype.h`.

Portions of this software are copyright © 1996-2026 The FreeType Project (www.freetype.org). All rights reserved.

## How it is made

- FreeType's source list (its `CMakeLists.txt`) with its portable `ftsystem.c` through `ftsystem-zdos.c`: font files through ZDOS handles, read into memory once when opened (up to 4 MB), not at each access; its default options: zlib built in; no PNG, HarfBuzz, Brotli or bzip2. `ftmodule-zdos.h` is its module list without the BDF and PCF drivers.
- The table, `freetype_zdl.c`: the functions of FreeType's public headers (`FT_EXPORT`) in the order of `exports.def`, `freetype.h`'s first, without `ftmac.h`'s. It only grows at its end: `build.sh` stops if a new FreeType declares one it lacks.
- Import stubs: `sdk/bin/zdos-stubs` makes them from `exports.def`, into `libfreetype.a`. The headers go to `build/sdk-ports/include/freetype2`, as FreeType installs them.
- `build.sh` checks `apps/zdos/freetype.zig` too: its slot names against `exports.def`, and with `layout.zig` its types' sizes and field offsets against FreeType's headers, for each CPU.

## Using it from a program

Zig, `apps/zdos/freetype.zig`: no headers or stubs; it loads `FREETYPE.ZDL` and calls it by slot. `ft.Library.init()`, `lib.openFace(path, 0)`, `face.setPixelSizes`, `face.loadGlyph` / `loadChar` with `ft.load_render` (the drawing in `face.glyph.bitmap`), glyphs, the stroker and the cache; FreeType's error codes as Zig errors.

C:

```sh
zdos-cc -I build/sdk-ports/include/freetype2 prog.c -lfreetype -o PROG.APP
```

One copy serves every program: its state is in what each makes (`FT_Library`, `FT_Face`), in that program's memory. `FT_New_Face` opens a path itself, with a ZDOS handle of the calling program (`ftsystem-zdos.c`); `FT_New_Memory_Face` and `FT_Open_Face` with the program's own stream functions work too.

## TTFTEST

`TTFTEST` (`apps/ttftest.zig`, built with ZDOS) shows "ZDOS TTF Test" in Arimo and "Monospace text" in IBM Plex Mono from `\SYSTEM\TTF` at 13, 16 and 22 pixels, white on blue: in true color at the screen's own size (UEFI, metal, BIOS with VESA), else in 320 x 200 with 256 colors. Colors are mixed with a mild gamma correction (1.4). Keys 1-4 switch how glyphs meet the pixels (TrueType's default v40, full TrueType hinting v35, FreeType's auto-hinter, monochrome), G gamma correction, S the auto-hinter's stem darkening; any other key ends it.

`TTFTEST FONT` loads a font through `freetype.zig`, prints its name, draws "ZDOS ¤!" at 16 pixels as ASCII shades with a checksum of the pixels, strokes an outline and looks a glyph up through FreeType's cache. The exit code is the number of failures; without this port it reports `FREETYPE.ZDL` missing.
