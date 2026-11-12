# NetSurf

This port uses NetSurf's existing framebuffer frontend with a libnsfb surface
of its own, `zdos` (`zdos_surface.c`), backed by ZDOS's drawing buffer and
keyboard/mouse APIs; libnsfb's RAM surface stays plain memory for bitmaps. It does not
use SDL. The build stages the source tree under `build/netsurf/src`; the
original source is left untouched.

```sh
ports/network/netsurf/build.sh x86_64
```

The build requires the host tools `make`, `rsync`, `gperf`, and a C compiler.
Set `NETSURF_SRC` and `CURL_SRC` to override `$ZDOS_PORTS_SRC/netsurf` and
`$ZDOS_PORTS_SRC/curl`. Curl is cross-built with the ZDOS SDK and linked into
NetSurf for HTTP and HTTPS, over the SDK's sockets and DNS: gzip pages through
the zlib port, TLS through the Mbed TLS port (`ports/libs/mbedtls`), checking
servers' certificates against `C:\CONF\CACERT.PEM` (curl's built-in CA bundle,
the file FETCH uses). PNG, JPEG and WebP images come from the libpng, libjpeg
and libwebp ports (`ports/graphics/libpng`, `ports/graphics/libjpeg`,
`ports/graphics/webp`, at runtime `WEBP.ZDL`); BMP and GIF from
NetSurf's own libraries. libpng, libjpeg and Mbed TLS
are built first where missing; libwebp on every build. The output is
`NETSURF.APP` in `build/<edition>/APPS_3RD/`, with frontend resources in
`build/DATA/NETSURF/` (`C:\DATA\NETSURF` at runtime).

The resource path is `/C:/DATA/NETSURF` (`Makefile.config`). NetSurf splits
its resource path at colons, as a Unix search path; `filepath-zdos.patch`
keeps a drive's colon (`C:`, `/C:`) in the element it belongs to, so the path
isn't cut into `/C` and `/DATA/NETSURF`.

Pages in a charset the parser has no decoder for (Shift_JIS, GBK, Big5 ...)
show their non-ASCII text as replacement characters
(`libparserutils-fallback.patch`).

The `zdos` surface accepts NetSurf's 32-bit XRGB buffer, presents it through
`zdos_display_present`, and translates ZDOS key, text, mouse, and wheel events
to libnsfb events. ZDOS exposes relative mouse motion, so the pointer starts at
the center of the browser window.

JavaScript runs on NetSurf's Duktape engine, on by default
(`enable_javascript`, `config-zdos.patch`); on x86 (BIOS) with its
unpacked value format, as on x64 (`duktape-zdos.patch`). NetSurf's DOM
bindings are partial (no `XMLHttpRequest` or `fetch`), so many
script-heavy sites won't work.

A page saved as text is UTF-8, as ZDOS's text is (`utf8-local-zdos.patch`;
the framebuffer frontend's own "local" encoding is CP1252, which the SDK's
iconv lacks). Forms are sent in the page's charset, ISO-8859-1 where the
SDK's iconv has no converter for it.

Downloads: the framebuffer frontend has none of its own, so a link to a
file NetSurf can't show (ZIP, EXE, ISO ...) is handed to `FETCH`
(`zdos_download.c`, `download-zdos.patch`). It runs in the background,
with its messages discarded, and saves into `%HOME%\Downloads` (made if
missing; `C:\TEMP` without `HOME`), as `FILE-2.ZIP` ... where the name
exists; other bytes than letters, digits, `.`, `-` and `_` become `_`. The
status bar shows where it goes. FETCH asks again without NetSurf's
cookies, logins or form data, and only over http and https; there is no
progress or end message. Where a download doesn't come, run it by hand to
see why: `FETCH -o C:\TEMP\FILE.ZIP https://...`.

The x86 (BIOS) build is compiled for `NETSURF_ZDOS_X86_CPU` in
`Makefile.config`: `pentium4` (SSE2) by default, `core2` for SSSE3, or
`i686` for every Pentium Pro and later. The libraries it links from other
ports stay i686.

Text is NetSurf's built-in bitmap font (`NETSURF_FB_FONTLIB := internal`:
8x16, doubled for large sizes).

## Not finished

- **Uploads**: a form's file field (`<input type="file">`, "Browse")
  does nothing when clicked: the framebuffer frontend has no file chooser
  (`file_gadget_open` is NetSurf's empty default), so such a form is sent
  without the file.
- **Downloads through NetSurf itself**: progress, cancelling, and files
  behind a login or a form (FETCH has no cookies).
- **SVG**: off; libsvgtiny needs libdom's XML parser, which needs expat
  or libxml2 (not ported).
