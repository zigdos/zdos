# x264

x264 is built as `X264.ZDL`, a per-program ZDOS library, with import stubs
installed as `build/sdk-ports/lib/<arch>/libx264.a`. Its public headers are
installed under `build/sdk-ports/include`.

```sh
ports/media/x264/build.sh                 # x86, x86_64 and arm64
ports/media/x264/build.sh x86_64          # one or more architectures
```

The source tree is `$ZDOS_PORTS_SRC/x264` (or `../x264` when that variable is
unset); set `X264_SRC` to override it. The build directory is local to this
port at `build/x264/`. Threads remain enabled and use the SDK's POSIX thread
support, which the build verifies. The x86 build disables assembly because the
BIOS target does not assume SIMD; x86-64 and ARM64 use x264's assembly
optimizations.

Use the API from a program as usual:

```sh
zdos-cc encoder.c -lx264 -o ENCODER.APP
```

Include `<stdint.h>` before `<x264.h>`, as x264's public header requires it.

The export table in `exports.def` is ABI-ordered; append new entries rather
than reordering existing ones. `x264_encoder_open` is versioned by the
upstream header macro and is exported under its actual symbol name
(`x264_encoder_open_165` in this source version). The public data symbols
`x264_levels` and `x264_chroma_format` are not in the function table and
cannot be imported through the current ZDOS library-stub mechanism.

`X264TEST.APP` encodes a few generated frames with two encoder threads as a
smoke test. The x264 library is GPL-licensed; follow its license terms when
redistributing a build.
