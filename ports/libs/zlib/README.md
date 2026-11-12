# zlib

[zlib](https://zlib.net) 1.3.2 as a library: `C:\LIBS\ZLIB.ZDL`, a copy per program. With it comes its test, `ZLIBTEST.APP`.

```sh
ports/libs/zlib/build.sh             # all three CPUs
ports/libs/zlib/build.sh x86_64      # one or more: x86, x86_64, arm64
zig build                            # puts them onto drive C:
```

Sources: zlib's release (`zlib-1.3.2.tar.gz` from zlib.net or github.com/madler/zlib), unpacked unchanged into `$ZDOS_PORTS_SRC/zlib` (`../zlib` when that variable is unset; `ZLIB_SRC=...`). Objects: `build/zlib/<arch>/`; the sources are only read.

## How it is made

- zlib's 15 C files, compiled as its `configure` would on a Unix (`HAVE_UNISTD_H`, `HAVE_STDARG_H`), and `zlib_zdl.c`, the export table, linked by `zdos-cc ... -o ZLIB.ZDL` (with `--gc-sections`).
- The table: zlib's public functions in the order of `exports.def`, zlib's own list for its Windows DLL (`win32/zlib.def`) without `gzopen_w`. It only grows at its end: a new zlib's new functions go at the end of `exports.def` (`build.sh` stops if `zlib.h` has one it lacks).
- Import stubs: `sdk/bin/zdos-stubs` makes them from `exports.def`, into `libz.a`; a program links it with `-lz` and its start-up loads `ZLIB.ZDL`.
- `zconf.h` for programs is zlib's with the two lines `configure` sets (`unistd.h`, `stdarg.h`): `z_off_t` is `off_t`, 64 bits on every CPU.

## Using it from a program

```sh
zdos-cc prog.c -lz -o PROG.APP     # zdos-cc finds build/sdk-ports' zlib.h and libz.a
```

Ported software's `-lz` works unchanged. There is no static zlib; for one, compile zlib's C files into the program.

## The C library inside

A C library has the SDK's C library linked into it, a copy of its own (sizes below are mostly that copy):

- **Memory:** `malloc` / `free` are thin layers over ZDOS's `memory` group, the same in the program and the library, and the memory is the program's. What zlib allocates may be freed by the program and the other way round; `zalloc` / `zfree` of the program's own work too (`ZLIBTEST` counts them).
- **Files:** `gz*` open their files with the library's own descriptors: `gzopen`, `gzread`, `gzwrite`, `gzprintf`, `gzseek` ... work, but `gzdopen` with a descriptor of the program's doesn't (that number means nothing in the library). `errno` (for `Z_ERRNO`, `gzerror`) is the library's too.
- That is why it is a copy per program, not shared: zlib itself has no changing global state, the C library's descriptor table does.
- Not reachable through the stubs: the 64-bit names (`gzopen64` ...) are in the table, but `zlib.h` declares them only on large-file systems; `z_off_t` is 64 bits anyway.

## Tests

`tests/ports/zlib-tests.py [EDITION...]`: `ZLIBTEST`, its output checked against this computer's zlib.
