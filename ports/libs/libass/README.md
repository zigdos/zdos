# libass

libass 0.17.5 as a library: `C:\LIBS\LIBASS.ZDL`, a copy per program. It draws subtitles: ASS/SSA with their styles, and SubRip and others through FFmpeg's `subtitles` filter. It uses `FREETYPE.ZDL`, `HARFBUZZ.ZDL` and `SHNBIDI.ZDL` (SheenBidi with FriBidi's functions).

```sh
ports/libs/libass/build.sh             # all three CPUs (FreeType, HarfBuzz, SheenBidi first if missing)
ports/libs/libass/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                              # puts them onto drive C:
```

Sources: libass's release, unpacked unchanged into `$ZDOS_PORTS_SRC/libass` (`../libass` when that variable is unset; `LIBASS_SRC=...`). Objects: `build/libass/<arch>/`; the sources are only read. The version for ZDOS is taken from `ass.h`.

## How it is made

- Its C files (its `meson.build`'s list) with the C versions of its assembly, and `config.h`: no fontconfig, iconv or libpng.
- Fonts: `ass_zdosfonts.c`, a font provider for the fonts of `C:\SYSTEM\TTF`, as fontconfig is one elsewhere, first in libass's table (`libass-zdos.patch`, on a copy of `ass_fontselect.c`), so `ASS_FONTPROVIDER_AUTODETECT` takes it. Each `.ttf` / `.otf` there is added by path (libass reads its names, weight and style; a face is opened only to ask for a glyph). Arial, Helvetica, Verdana, Tahoma and sans-serif are Arimo; Times New Roman, Times, Georgia and serif Tinos; Courier New, Courier, Consolas and monospace IBM Plex Mono. A glyph a font lacks is looked for in Arimo, Tinos and IBM Plex Mono, then in the others. Bold and italic come from the families' own files.
- Line breaking (`ASS_FEATURE_WRAP_UNICODE`) by `linebreak.zig`, ours, behind libunibreak's interface (`linebreak.h`), built into `LIBASS.ZDL`: the rules of Unicode's line breaking (UAX #14) for text on a screen. Breaks at spaces, after hyphens and dashes, between CJK characters; never before closing punctuation or small kana, never after opening punctuation, never inside a letter with its marks. No dictionary, so Thai wraps at spaces only. `zig test ports/libs/libass/linebreak.zig` tests it on the host.
- The table, `libass_zdl.c`: libass's own list (`libass/libass.sym`) in `exports.def`. It only grows at its end: `build.sh` stops if a new libass lists a function it lacks.
- FreeType, HarfBuzz and SheenBidi through their stubs.
- Import stubs: `libass.a`; the headers: `build/sdk-ports/include/ass`.
