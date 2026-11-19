# MicroPython for ZDOS

`MICROPYTHON.APP` is MicroPython 1.29 with its own ZDOS port, `ports/zdos`, built with the SDK. The port started as a copy of MicroPython's `minimal` port (its unused STM32 files are still there). No MicroPython file outside `ports/zdos` is changed.

```sh
ports/coding/micropython/build.sh             # all three editions
ports/coding/micropython/build.sh x86         # one: x86 (BIOS), x86_64, arm64
```

The sources are `../micropython` next to the ZDOS folder (`MICROPYTHON=` moves it). The build script copies `zdos/` into the checkout as `ports/zdos` (only changed files), builds there with `make` (objects in `ports/zdos/build-<arch>/`), and puts `micropython.app` into `build/<edition>/APPS_3RD/` (for x86-64 and ARM64 both the UEFI and the metal edition's); the next `zig build` puts it into `C:\APPS`. The version for ZDOS is taken from `py/mpconfig.h`.

On ZDOS, `MICROPYTHON` starts the REPL and `MICROPYTHON SCRIPT.PY a b` runs a script; its exit status is the ERRORLEVEL.

## Status

- [x] Builds for all three editions.
- [x] Runs on ZDOS: the REPL, scripts, files and folders, Ctrl+C; the garbage-collector stress test `scripts/gcstress.py` (`C:\SCRIPTS\GCSTRESS.PY`) passes on all editions.
- [ ] MicroPython's own test suite (`tests/`) not run yet.

## The port's files (`zdos/`)

- `Makefile`: the SDK's `zdos-cc` for the CPU (`ZDOS_ARCH`) as compiler and linker, from the SDK given (`SDK=`; the C library comes with it), plain `zig cc -E` for MicroPython's qstr preprocessing, and the MicroPython sources and modules chosen.
- `mpconfigport.h`: the BASIC feature level, 64-bit floats, a 2 MB heap, the VFS and the modules.
- `main.c`: garbage collector and runtime set-up, `sys.argv`, the VFS, then the script or the REPL.
- `uart_core.c`: the console. `mphalport.h`: the clock and sleeping. `zdos_time.h`: the date and time for `time.localtime()`.
- `zdos_vfs.c`: files and folders on ZDOS, mounted at `/`.

From the SDK: the start-up (`main`, `argc` / `argv`), the C library, its headers and the linker scripts. Math comes from MicroPython's own `lib/libm_dbl`, not the SDK's; the Makefile sets `ZDOS_NO_FLOAT_T`, so the SDK's `math.h` leaves `float_t` / `double_t` to it.

## What works

- **The language** at MicroPython's BASIC level, with 64-bit floats on every edition. The BASIC level leaves out f-strings, `compile`, `input`, `help`, `bytes.hex`, `frozenset`, `memoryview` and some string methods. `quit()` (like `sys.exit()`) ends MicroPython.
- **Modules:**
  - `array`, `binascii`, `cmath`, `collections`, `errno`, `gc`, `heapq`, `io`, `json`, `math`, `micropython`, `os`, `platform`, `random`, `re`, `struct`, `sys`, `time`, `vfs`.
  - Smaller versions: `deflate` decompresses only, `hashlib` has SHA-256 only, and `random` has no automatic seed (call `random.seed(n)`).
  - Modules are chosen one by one in `Makefile` and `mpconfigport.h`. Raising the global feature level instead would turn on features ZDOS has nothing behind.
- **Imports:** built-in modules and `.py` files; no native extensions.
- **Exit codes:** a script stopped by Ctrl+C returns 130, as on Unix.

## Console

- **Output** goes through ZDOS, so redirection works (`> OUT.TXT`, `| MORE`). ANSI colors always work; cursor movement and erasing need `TERM=vt100`.
- **Input** is the redirected input if there is one, else the keyboard. The REPL has line editing and history (arrows, Home, End). It works in both console modes and doesn't need VT100 codes: the port moves the cursor through ZDOS.
- **Ctrl+C** belongs to MicroPython, not ZDOS:
  - At the prompt it drops the line.
  - In running code it raises `KeyboardInterrupt`. The keyboard is checked every 1000 loop steps and during `time.sleep()`; keys typed meanwhile are kept for `input()` and the REPL.
- **Ctrl+D** on an empty line leaves the REPL.

## Files

- **Paths:**
  - The VFS is at `/`, but relative paths start from the folder MicroPython was started in, and the prompt stays there afterwards.
  - `/X.PY` is in the current drive's root. Other drives are `/D:/X.PY` (or `D:/X.PY`).
  - `os.getcwd()` gives `/C:/DOCS`, so `os.chdir(os.getcwd())` works across drives.
- **Files:**
  - Modes `r`, `w`, `a`, `+`, `b`, `t`. Text and binary differ only in the Python type; there's no line-end translation.
  - `f.truncate([size])` sets the length.
- **`os`:**
  - `listdir`, `ilistdir`, `stat`, `mkdir`, `rmdir` (empty folders), `remove`, `rename` (the destination must not exist), `chdir`, `getcwd`, `statvfs`.
  - `os.stat` gives `st_mtime` (modified), `st_atime` (last read, a date only on FAT) and `st_ctime` (created, as on Windows), all local times.
  - `os.statvfs` counts 512-byte blocks.
- **Errors** raise `OSError` with ZDOS's cause as a Linux errno number, shown by name: `[Errno 2] ENOENT`. The names include `EEXIST`, `EACCES` (read-only), `ENOTEMPTY`, `ENOTDIR`, `EISDIR`, `ENOSPC`, `EROFS` and `EIO`.

## Time

ZDOS's clock is local time with no time zone:
- `time.localtime()`, `gmtime()` and `mktime()` are calendar arithmetic, with MicroPython's epoch, 2000-01-01.
- `time.time()` isn't there: it would need a UTC offset ZDOS doesn't have. Use `ticks_ms()` / `ticks_diff()` for elapsed time.
- The `ticks_*` and `sleep_*` functions count in milliseconds.

## Limits

- No sockets, TLS, threads, `select` or `machine` peripherals.
- The heap is a fixed 2 MB (`MICROPY_HEAP_SIZE`), reserved when the program loads.
- The garbage collector scans the stack but not the CPU registers, as in the `minimal` port. An object that only a register points to during a collection could be freed. The stress test passes, but the full ports save the registers first.

## Building by hand

In `ports/zdos` of the checkout, for x86-64:

```sh
make -j8 ZDOS_ARCH=x86_64 BUILD=build-x86_64 SDK=/path/to/zigdos/sdk
zig objcopy -O binary build-x86_64/micropython.elf build-x86_64/micropython.app
```

- **The program must be position-independent:** `readelf -h` must show `Type: DYN`, and the build script checks it. Run `make clean` after switching SDK folders.
- **The 32-bit preprocessor quirk:** `zig cc -E` accepts the 32-bit target as `i686` only when it gets several input files. With one file it wants `x86`, so a rebuild after changing a single source would fail. The Makefile therefore adds an empty input (`-x c /dev/null`) for x86. The side effect: `make build-x86/<file>.pp` doesn't work; use the x86-64 build for that.
