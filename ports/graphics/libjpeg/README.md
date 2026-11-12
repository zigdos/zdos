# libjpeg

The Independent JPEG Group's libjpeg (release 10) as a static library for
other ports (NetSurf's JPEG images): `libjpeg.a` in
`build/sdk-ports/lib/<arch>`, `jpeglib.h`, `jconfig.h`, `jmorecfg.h` and
`jerror.h` in `build/sdk-ports/include` (`-ljpeg`).

```sh
ports/graphics/libjpeg/build.sh [x86|x86_64|arm64]
```

Sources: IJG's release tree in `../libjpeg` (`LIBJPEG_SRC=...`), unchanged.
`jconfig.h` here answers configure's questions for the SDK; the memory manager
is `jmemnobs.c` (no temporary files: images are decoded in memory). License:
IJG's (`README` in its tree, "LEGAL ISSUES").
