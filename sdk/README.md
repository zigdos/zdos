# ZDOS application SDK

Everything needed to write ZDOS programs in C, C++ and Rust: the header for the program API, program startup, a C library and the linker scripts. It is the same for every edition; only the build target differs.

## Contents

1. [Layout](#layout)
2. [Two ways to write a program](#two-ways-to-write-a-program)
3. [Building](#building)
   - [zdos-cc](#zdos-cc)
   - [C++](#c)
   - [By hand](#by-hand)
   - [Rust](#rust)
4. [Display, input and sound (zdos_media.h)](#display-input-and-sound-zdos_mediah)
5. [The C library](#the-c-library)

---

## Layout

- `src/zdos.h`: the program API (`zdos->files->open` ...), mirroring ZDOS's `src/kernel/abi.zig`.
- `src/zdos_crt0.c`: program startup (`zdos_entry`, constructors, `main`, `exit`).
- `src/zdos_*.c`: the C library; `src/libm/`, `src/libml/`: its math (`README.md` in each). Optional parts (`zdos_posix.c` ...) connect through hook variables their constructor sets, not weak symbols: a program that doesn't link them would keep a relocation the loader refuses.
- `src/zdos_media.h`: display, input and sound for ported libraries and games ([below](#display-input-and-sound-zdos_mediah)).
- `compat/`: the C library's headers.
- `linkers/`: `app-*.ld` for programs (`*-compac.ld` without page padding), `lib-*.ld` for libraries (`.ZDL`), `sys-*.ld` for drivers (`.SYS`).
- `bin/`: `zdos-cc`, `zdos-c++`, `zdos-ar`, `zdos-ranlib`, `zdos-stubs`, `zdos-cargo`.
- `rust/`: the `zdos` crate, a template project and examples.
- `examples/`: `hello.c`, `example_sdk.c` (a tour of the C library), `hello_api.c` (the bare API), `cxxtest.cpp`.

## Two ways to write a program

**With `main` and the C library:**

```c
#include <stdio.h>

int main(int argc, char **argv) {
    printf("Hello, %s\n", argc > 1 ? argv[1] : "world");
    return 0; /* the exit code: ERRORLEVEL in batch files */
}
```

`argv[0]` is the program's own file; the command line is split at blanks, double quotes group words, `\"` is a quote. The API table is in the variable `zdos`, for what the C library doesn't cover (screen, keys, drives ...).

**On the bare API:** define `zdos_entry` yourself, include path `src` only:

```c
#include "zdos.h"

ZDOS_CALL unsigned char zdos_entry(const zdos_start *start) {
    zdos_init(start);         /* connects the groups, sets zdos */
    zdos_puts("Hello\n");
    return 0;                 /* exit code */
}
```

The arguments are UTF-8 in `start->args` / `start->args_len`, not 0-terminated. Strings passed to the API are pointer and length.

## Building

### zdos-cc

`bin/zdos-cc` is a C compiler command for ZDOS, as `gcc` is for Linux: `zig cc` with ZDOS's target, these headers, the C library and the linker script. It runs on Linux and macOS (bash and Zig 0.14).

```sh
SDK/bin/zdos-cc -O2 hello.c -o HELLO.APP          # a program: HELLO.APP, and HELLO.elf beside it
SDK/bin/zdos-cc -O2 -c a.c -o a.o                 # compiling only
SDK/bin/zdos-cc a.o b.o -lm -o prog               # linking: prog is ELF, as make expects
SDK/bin/zdos-cc --app prog PROG.APP               # ... and the .APP from it
SDK/bin/zdos-cc --arch=arm64 hello.c -o HELLO.APP # another CPU: x86, x86_64 (default), arm64
SDK/bin/zdos-c++ -O2 hello.cpp -o HELLO.APP       # C++ with its standard library
```

- x86_64 and arm64 programs run on the UEFI and metal editions of that CPU, x86 ones on the BIOS edition.
- The C library is built once per CPU into `ZDOS_SDK_CACHE` (default `~/.cache/zdos-sdk`); a program gets only the parts it uses. `-lm`, `-lpthread`, `-ldl` and the like are in it; `-shared` fails (no shared libraries). `__zdos__` is defined.
- Ports' libraries in `build/sdk-ports` are found as a system's are (`#include <SDL2/SDL.h>`, `-lSDL2`).
- A library: `-o NAME.ZDL`, its export table from an `exports.def` list of `X(function)` lines through `src/zdos_exports.h`; `bin/zdos-stubs NAME exports.def libNAME.a` makes the import stubs programs link with `-lNAME` ([docs/ZDL.md](../docs/ZDL.md)).

With `configure` and `make`, name the CPU with `-elf` (absolute paths for the commands):

```sh
./configure --host=x86_64-elf CC=SDK/bin/zdos-cc CXX=SDK/bin/zdos-c++ AR=SDK/bin/zdos-ar RANLIB=SDK/bin/zdos-ranlib
make
SDK/bin/zdos-cc --app src/prog PROG.APP
```

It is a cross-compilation: `configure` can't run test programs and guesses instead.

### C++

`zdos-c++` uses LLVM's libc++ 19 (Zig's) with libc++abi and libunwind, built on the first C++ link (`zdos-cc --build-cxx` builds them ahead). Exceptions, RTTI, `std::thread` and `thread_local` work.

- The "C" locale only, and no time zone database (the C library's `TZ` works).
- `std::filesystem` has POSIX path rules: only paths starting with `/` are absolute, so write `/D:/DOCS/X.TXT` where it matters.
- `-nostdlib++` links `src/zdos_cxx.c`'s small runtime instead, for programs without exceptions and library classes.
- Libraries (`.ZDL`) are linked without libc++.

### By hand

With `zig cc`, then `objcopy` to the flat `.APP`:

```sh
zig cc -target x86_64-freestanding -mno-red-zone -Os -ffreestanding -fPIE -pie -fno-stack-protector \
    -nostdlib -Wl,-e,zdos_entry -Wl,-T,SDK/linkers/app-x86_64.ld -ISDK/src -ISDK/compat \
    -o hello.elf SDK/examples/hello.c SDK/src/zdos_crt0.c SDK/src/zdos_libc.c SDK/src/zdos_fs.c SDK/src/zdos_tls.c
zig objcopy -O binary hello.elf HELLO.APP
```

Add the other `src/zdos_*.c` files for what they have, and `src/libm`, `src/libml` with the flags `zdos-cc` gives them.

| Edition            | `-target`                           | Linker script   |
| ------------------ | ----------------------------------- | --------------- |
| BIOS               | `x86-freestanding -mcpu=i686`       | `app-x86.ld`    |
| UEFI, metal x86-64 | `x86_64-freestanding -mno-red-zone` | `app-x86_64.ld` |
| UEFI, metal ARM64  | `aarch64-freestanding`              | `app-arm64.ld`  |

Programs must be position-independent: compile with `-fPIE` **and** link with `-pie`; `readelf -h hello.elf` must show `Type: DYN`, or the program has no relocations and hangs.

### Rust

`bin/zdos-cargo` builds Rust programs with the full `std` on stable Rust: rustup's `std` for the CPU's musl target, linked against this C library. Needs `rustup target add x86_64-unknown-linux-musl` (and `aarch64-` / `i686-` for the other CPUs).

```sh
SDK/bin/zdos-cargo new hello                    # a project from rust/template
cd hello && SDK/bin/zdos-cargo build --release  # target/x86_64-unknown-linux-musl/release/HELLO.APP
SDK/bin/zdos-cargo --arch=arm64 build --release # x86_64 (default), arm64, x86
```

The examples in `rust/examples/` build the same way; their `target/` goes to `~/.cache/zdos-sdk/target/` (`ZDOS_SDK_CACHE`), so the SDK folder stays as shipped.

- `--small` (`zdos-cargo --small build --release`) builds `std` itself on nightly Rust without backtraces, and panics abort the program (a Hello: about 170 KB instead of 400 KB). Needs `rustup toolchain install nightly --component rust-src` and `rustup target add --toolchain nightly x86_64-unknown-linux-musl`. `catch_unwind` catches nothing then.
- Threads get ZDOS's thread stack size (256 KiB, `threads->default_stack_size`) unless `RUST_MIN_STACK` or `thread::Builder::stack_size` asks for another; deeply recursive code may need more.
- Crates' C sources go through `zdos-cc` (`ZDOS_CC`, `ZDOS_CXX` override it). tokio, Axum and hyper work.
- Not there: backtraces with names, and what needs Linux itself (`inotify`, `/proc`, `memfd`, process groups).
- The `zdos` crate (`rust/zdos`) has what `std` lacks: console colors and keys, graphics, input events and sound.

## Display, input and sound (zdos_media.h)

A small layer over the groups `gfx`, `console` and `sound` for libraries and games that bring their own frames and want events (SDL 2's ZDOS backends use it): `zdos_display_*` shows frames in common pixel formats scaled to the screen, `zdos_input_poll` gives key (USB HID scancodes), text, mouse and focus events, `zdos_audio_start` runs a sound thread. The header describes each call.

## The C library

It is a hosted C library with POSIX's usual headers. Where it differs from Linux:

- **Processes** are ZDOS tasks in one address space: `fork` works as `vfork` (for fork, `dup2`, then `exec` or `_exit`); `posix_spawn` starts programs. `exec` without `vfork` runs the program in place of this one.
- **Paths:** `/` and `\` both work; a drive is `D:` in front, or `/D:/DOCS/X.TXT` for one tree. `getcwd` gives `C:\DOCS`. FAT has no links: `lstat` is `stat`, `symlink` fails.
- **Not there:** IPv6 and `AF_UNIX` sockets, shared libraries (`dlopen` of a file fails), locales other than "C", a tz database (`TZ` in POSIX form works).
- **Time:** ZDOS's clock is local time; without `TZ` it counts as UTC. FAT keeps times in 2 seconds, and no access time.
- **Files:** `mmap` of a file reads it into memory (`MAP_SHARED` writes back at `msync` and `munmap`). `fchmod` and `flock` are accepted and do nothing.
- **Users:** `getpwnam` and the like read `USERS.CFG` ([Users](../docs/USERS.md)).
- **Signals:** Ctrl+C ends a program unless `SIGINT` is handled or ignored; CPU faults become signals on metal and BIOS.
- **Math:** errors give IEEE results without setting `errno`.
- **Threads:** pthread mutexes don't inherit priority unless `PTHREAD_PRIO_INHERIT`; a library (`.ZDL`) can't have `thread_local` data.
- **Screen and keys** aren't standard C: use the API, e.g. `zdos->console->set_color(ZDOS_YELLOW, ZDOS_BLACK)`.
