# FFmpeg

[FFmpeg](https://ffmpeg.org) 9.0.2 (LGPL) as one library, `C:\LIBS\FFMPEG9.ZDL` (a copy per program), with its three tools: `FFPROBE.APP`, `FFMPEG.APP` and `FFPLAY.APP` (on SDL 2, `C:\LIBS\SDL2.ZDL`).

```sh
ports/media/ffmpeg/build.sh            # all three CPUs (builds SDL 2 first if missing)
zig build                              # puts them onto drive C:
```

Sources: FFmpeg's git clone in `$ZDOS_PORTS_SRC/FFmpeg` (`../FFmpeg` when that variable is unset; `FFMPEG_SRC=...`); `build.sh` exports its tag `n9.0.2` into `build/ffmpeg/src` (the clone's checkout is not touched). A release tree works too. Objects: `build/ffmpeg/<arch>/`, where FFmpeg's `configure` runs. About 25 s on 16 cores; 1 min with `configure`. The version for ZDOS is taken from `RELEASE`.

## How it is made

- FFmpeg's own `configure` and `make`, `zdos-cc` as the compiler (`--target-os=none --enable-cross-compile`), static libraries.
- `ffmpeg-zdos.patch`, the only change to the sources:
  - x86-64: two pieces of assembly (H.264's intra deblocking, swresample's resampler) kept data in the red zone below the stack pointer, where ZDOS's interrupts write; they get stack space instead. `build.sh` stops if another such piece appears.
  - ffplay offers yuv420p first, so SDL converts its frames with SSE2 instead of ffplay with swscale in C.
  - The `subtitles` filter finds fonts through libass's provider of `C:\SYSTEM\TTF` (`Arimo-Regular.ttf` for what no font has) and keeps a file's track and fonts for the next filter of the same file: ffplay builds its filters anew after every seek.
- `FFMPEG9.ZDL`: `ffmpeg_zdl.c` (the export table) linked with libavfilter, libavformat, libavcodec, libswresample, libswscale and libavutil (`--gc-sections`).
- The table: the functions FFmpeg's export maps make public (`libavcodec/libavcodec.v` ...: `av*`, `avcodec_*`, `sws_*`, `swr_*` ...), without the libraries' private `avpriv_*`, in the order of `exports.def` (sorted when made, 1023 functions). It only grows at its end: `build.sh` stops when the libraries have a public function `exports.def` lacks; append it there.
- Data can't be imported (the table holds functions): the exported constants `av_aes_size`, `av_md5_size`, `av_sha_size` ... (the `av_*_size` of the hash and cipher modules) and the version strings `av_*_ffversion`, `swr_ffversion` are not reachable from programs; the tools use none of them. `av_*_alloc` of those modules works.
- Import stubs (`sdk/bin/zdos-stubs`) in one archive, installed under six names: `-lavcodec`, `-lavformat`, `-lavutil`, `-lavfilter`, `-lswscale`, `-lswresample` all give it, so ported software's link lines work unchanged. Headers: `build/sdk-ports/include/libav*`, `libsw*` (`make install-headers`).
- The tools: FFmpeg's `fftools` objects linked on the stubs (and `-lSDL2` for `FFPLAY`).
- `zdos-cc` searches `build/sdk-ports/include` before a build's own `-I`: FFmpeg itself is built on a view of it holding only SDL 2's headers (`build/ffmpeg/sdk-ports-view`), so the installed FFmpeg headers don't replace its sources' ones.

## Configure options and why

- x86-64: FFmpeg's SIMD assembly (`nasm` needed) with `--enable-pic`, so it addresses its tables relative to the instruction pointer: `build.sh` stops if the library gets a relocation other than a relative one. ZDOS doesn't turn on AVX (no `XSAVE`; tasks keep the SSE state), so FFmpeg's own check picks SSE2 ... SSE4.2 code, never AVX / AVX2. x86: `--disable-asm`, C only (its assembly, inline too, addresses tables absolutely or through a GOT; the BIOS edition has no SSE anyway). ARM64: its NEON assembly, with `--enable-pic`.
- `--disable-everything` and then a subset (`COMPONENTS` in `build.sh`): decoders, demuxers, parser, encoders, muxers, filters, protocols.
- `--enable-zlib`: the zlib port, so `FFMPEG9.ZDL` loads `ZLIB.ZDL` (built first if missing); PNG and APNG, compressed MOV headers and Matroska tracks need it.
- `--disable-network`, `--disable-autodetect` (no other external libraries), `--disable-avdevice` (no capture or output devices), `--enable-pthreads`, `--enable-sdl2` (through `sdl2-config`).
- LGPL only: no `--enable-gpl`, no `--enable-nonfree` (`docs/COPYING/FFMPEG.TXT`).
- `HAVE_DOS_PATHS 1` (set in `config.h` after `configure`, which turns it on only for Windows, OS/2 and DOS): `D:\FILM.MKV` is a file; without it FFmpeg takes `d:` for a protocol ("Protocol not found").

A decoder (or demuxer ...) more: add it to `COMPONENTS` in `build.sh` and run it again; `configure` runs again by itself. Should it bring a public function the table lacks (a parser's `av_*` ...), `build.sh` says so: append it to `exports.def`.

## Using it

```sh
FFPROBE VIDEO.MP4
FFMPEG -i SONG.MP3 SONG.WAV
FFMPEG -i VIDEO.MKV -f null -          # decode only (-benchmark: the times)
FFPLAY -autoexit VIDEO.MP4             # in a tab of its own, with sound
```

`FFMPEG` reads keys from standard input (`q` ends it): in batch files give it `-nostdin`. In a program: `zdos-cc prog.c -lavformat -lavcodec -lavutil -o PROG.APP` (`#include <libavformat/avformat.h>`).

## Limits

- x86-64 tested (metal under KVM). x86 and ARM64 build (`build.sh x86 arm64`: same table, only relative relocations), not run yet.
- No network protocols, no hardware decoding.
- Sound with more channels (AC-3 5.1) is mixed down to stereo: ZDOS's SDL opens at most two channels, ffplay's swresample converts.
- `FFPLAY` shows only bitmap subtitles (DVD, PGS): text ones (SubRip, ASS) are decoded but drawing them needs FFmpeg's `subtitles` filter with libass and FreeType, which the GPL build has ([ffmpeg264](../ffmpeg264/README.md)). `FFMPEG` writes them out (`-c:s srt`, WebVTT, ASS).
- FFmpeg's `FILE` streams and descriptors are the library's own (a copy of the C library inside): `pipe:0` / `pipe:1` are the program's standard input and output all the same, as ZDOS gives both copies the same ones.
- `FFPLAY` draws through SDL's software renderer ("Failed to initialize a hardware accelerated renderer" is SDL's first try); yuv420p frames go to it as they are (SDL converts them, SSE2 on x86-64), others through swscale first.
- Without `-c` FFmpeg takes the format's default encoder, which this build lacks for MP4, MOV, MKV and MP3 (H.264, MP3), WebM (VP9), Ogg (Theora): name one (`-c:v mpeg4`, `-c:a aac`). Vorbis and Opus encoders are FFmpeg's experimental ones: `-strict -2`.
- No AV1: FFmpeg's own `av1` decoder needs hardware decoding (dav1d is not ported).

## Tests

`tests/ports/ffmpeg-tests.py` (metal-x86_64, also in `tests/run-all.py`): decoding frame for frame as this computer's ffmpeg, the encoders, filters, FFPROBE and FFPLAY; it tells this build from ffmpeg264's by the encoders in `FFMPEG9.ZDL`. `ffmpeg-tests.py CASE STEP...` by hand.
