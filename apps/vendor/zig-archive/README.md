# zig-archive

Reading and writing archives in zig.

Upstream: https://github.com/truemedian/zig-archive (MIT, see LICENSE).

> **ZDOS copy:** this library has been extensively modified to work with Zig 0.14
> and to support different platforms: it runs inside `ZIP.APP` on ZDOS (BIOS x86,
> UEFI x86-64 and ARM64), where `ZIP.APP` gives it files through the ZDOS program
> interface. Only the library sources (`src/`) are kept here; upstream's build file,
> tests and generated documentation were removed.

## Features

- Reading and writing zip archives
  - Supports zip64
  - Supports zip files with a preamble (like self-extracting archives)
- TODO: Reading and writing tar archives

## Usage

`apps/zip.zig` (`ZIP.APP`) imports `src/main.zig`; it shows reading, extracting and
writing a zip archive.
