# HarfBuzz

HarfBuzz 15.1.0 as a library: `C:\LIBS\HARFBUZZ.ZDL`, a copy per program. It turns text into positioned glyphs: ligatures, kerning, marks, the letter forms of Arabic and Indic scripts; libass uses it. It draws through FreeType (`FREETYPE.ZDL`, `hb-ft`).

```sh
ports/libs/harfbuzz/build.sh             # all three CPUs
ports/libs/harfbuzz/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                                # puts them onto drive C:
```

Sources: HarfBuzz's release, unpacked unchanged into `$ZDOS_PORTS_SRC/harfbuzz` (`../harfbuzz` when that variable is unset; `HARFBUZZ_SRC=...`). Objects: `build/harfbuzz/<arch>/`; the sources are only read. The version for ZDOS is taken from `hb-version.h`.

## How it is made

- One C++ file, `src/harfbuzz.cc` (all of HarfBuzz), compiled by `zdos-c++` as its `meson.build` does: C++11, no exceptions, RTTI or thread-safe statics. `config.h` answers its checks: FreeType and the four FreeType functions it looks for, POSIX threads, `atexit`.
- The table, `harfbuzz_zdl.c`: the functions that `hb.h`, `hb-ot.h` and `hb-ft.h` declare (`HB_EXTERN`), as the preprocessor leaves them for this build, in their order, in `exports.def`. It only grows at its end: `build.sh` makes the list anew and stops if a new HarfBuzz declares one it lacks.
- FreeType through its stubs; the port is built first if missing.
- Import stubs: `libharfbuzz.a`; the headers: `build/sdk-ports/include/harfbuzz`.
