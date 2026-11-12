# libpng

libpng 1.6 as a static library for other ports (NetSurf's PNG images):
`libpng.a` in `build/sdk-ports/lib/<arch>`, `png.h`, `pngconf.h` and
`pnglibconf.h` in `build/sdk-ports/include`, so `zdos-cc ... -lpng -lz` finds
them. zlib is the zlib port's (`ZLIB.ZDL`, through its import stubs).

```sh
ports/graphics/libpng/build.sh [x86|x86_64|arm64]
```

Sources: libpng's release tree in `../libpng` (`LIBPNG_SRC=...`), unchanged;
`pnglibconf.h` is its prebuilt default. No CPU-specific filters (ARM64's NEON
code needs a runtime check ZDOS has no use for). License: libpng's
(`LICENSE` in its tree).
