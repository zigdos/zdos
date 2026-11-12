# Libraries (.ZDL)

A `.ZDL` is a ZDOS library: code that programs load while they run, as a DLL on Windows or a `.so` on Linux. It has the program format (`sdk/linkers/lib-*.ld`), but instead of an entry point it has an **export table**: a slot count, then pointers to its functions, slot 1 first. ZDOS's own libraries are in `libs/` (`ZCRYPT.ZDL`), ported ones under `ports/` (`ZLIB.ZDL`, `SDL2.ZDL`).

A program asks for `NAME.ZDL` by name; ZDOS looks in the program's folder, then in `\LIBS` on the boot drive, and returns the table ([API](API.md#libraries-zdl)).

## Shared or per program

- **Per program** (the default): each program that loads it gets its own copy, with its own global variables.
- **Shared**: one copy for every program, for libraries without changing global state (callers pass their own memory). The library says so by defining the symbol `zdos_library_shared`.

A C library carries its own copy of the C library (its file descriptors, `FILE` streams), so it stays per program. `malloc` / `free`, threads, `errno` and signal handlers are the program's: memory may be freed on either side.

## The table only grows

A function keeps its slot for good. New functions go at the end, nothing is removed or moved. A program built for an older library then keeps working with a newer one. `zdos.library(T, name)` (Zig) gives slots an older library lacks as functions that fail with `NotSupported`; C import stubs expect the library to be at least as new as the program.

## A library in C

The table comes from a list of `X(function)` lines, `exports.def`, in slot order:

```c
/* HELLO.ZDL's table, slot 1 first; only ever add at the end */
X(hello_add)
X(hello_greet)
```

The library's source includes `zdos_exports.h`, which turns the list into the table (`zdos_library`):

```c
#include <stdio.h>
#include "hello.h"

int hello_add(int a, int b) { return a + b; }
void hello_greet(const char *who) { printf("Hello, %s!\n", who); }

#define ZDOS_EXPORTS "exports.def"
#include "zdos_exports.h"
```

```sh
zdos-cc -O2 -I. hello.c -o HELLO.ZDL      # the library (-I: where exports.def is)
zdos-stubs HELLO exports.def libhello.a   # its import stubs, from the same list
zdos-cc -O2 prog.c -L. -lhello -o PROG.APP
```

`-o NAME.ZDL` makes `zdos-cc` link a library: the library start-up runs its global constructors and loads the libraries it imports itself. With `ZDOS_EXPORTS_DECLARE` defined before the include, `zdos_exports.h` declares the functions itself, for a list of functions no included header declares.

**Import stubs** let a program call the functions by name, as with any C library: `prog.c` includes `hello.h` and calls `hello_greet("ZDOS")`. Each stub jumps through the table; the program's start-up loads `HELLO.ZDL` and stops with "HELLO.ZDL: can't load the library" if it can't. Without stubs, a program loads it with `zdos->programs->load_library("HELLO", 5)` and calls through the table it returns (slot count first).

A port does the same in its `build.sh`: `ports/libs/zlib/` is a complete example (zlib's own DLL list as `exports.def`, `libz.a` for `-lz`).

## A library in Zig

A `.zig` file in `libs/` becomes `NAME.ZDL` in `C:\LIBS` with `zig build`. It imports `zdos` (whose start-up runs once per load) and exports its table as an `extern struct` that starts with `slots`:

```zig
const zdos = @import("zdos");
const abi = @import("abi");

comptime {
    _ = zdos; // the library's start-up
}

pub const Api = extern struct {
    slots: usize,
    add: *const fn (a: i32, b: i32) callconv(abi.cc) i32,
};

export const zdos_library_shared: u8 = 1; // no globals: one copy for all

export const zdos_library: Api = .{ .slots = abi.slotsOf(Api), .add = add };

fn add(a: i32, b: i32) callconv(abi.cc) i32 {
    return a + b;
}
```

A program gets the table with `zdos.library(Api, "HELLO")` and calls `t.add(2, 3)`. The `Api` struct belongs where the programs see it: `ZCRYPT.ZDL` keeps its in `apps/zdos/zcrypt.zig` and is built from `libs/zcrypt.zig`.

## Versions

A library's header has the same version fields as a program's: `ZDOS_FILE_VERSION(1, 0, 0, 0);` in C or `pub const zdos_file_version = [4]u8{ 1, 0, 0, 0 };` in Zig sets the one `VER HELLO.ZDL` shows, and `zdos_api_version` the API version it needs ([DEVELOPER.md](DEVELOPER.md#the-app-program-format)).
