# libwebp

libwebp is built as `WEBP.ZDL`, with import stubs (`-lwebp`, and
`-lwebpmux` for animation support) and public headers installed under
`build/sdk-ports`. `WEBPTEST.APP` encodes a small RGBA image as a smoke test.

```sh
ports/graphics/webp/build.sh             # x86, x86_64 and arm64
ports/graphics/webp/build.sh x86_64      # one or more architectures
```

The source tree defaults to `$ZDOS_PORTS_SRC/libwebp`; set `WEBP_SRC` to
override it. Build intermediates are kept in `build/webp/<arch>/`.

The ZDOS pthread header implements the thread operations used by libwebp, but
not the cleanup macros expected by libwebp's configure-time pthread probe.
The build therefore enables libwebp's worker-thread code explicitly after
configuration; encoding can use ZDOS's multicore thread support.

`WEBP.ZDL` holds the WebP encoder and mux libraries, including WebP animation
encoding, and the simple decoding API (`webp/decode.h`: `WebPGetInfo`,
`WebPGetFeatures`, `WebPDecodeRGBA` ... and their `Into` forms), which
NetSurf uses.
