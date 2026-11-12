# ZDOS Developer Guide

How ZDOS is built inside, and how to write programs for it. For using ZDOS, see the [README](../README.md); for what each version has, the [Devlog](DEVLOG.md).

## Contents

1. [Architecture](#architecture)
   - [Boot and structure](#boot-and-structure)
   - [Portability (platform layer)](#portability-platform-layer)
   - [The .APP program format](#the-app-program-format)
   - [Compatibility](#compatibility)
   - [Calling convention](#calling-convention)
   - [Stacks](#stacks)
   - [Timekeeping](#timekeeping)
2. [Writing programs](#writing-programs)
   - [In Zig](#writing-programs-in-zig)
   - [In C](#writing-programs-in-c)
   - [In C++](#writing-programs-in-c-1)
   - [Other languages](#other-languages)
   - [Where programs and their data go](#where-programs-and-their-data-go)
3. [Program API reference](API.md)
4. [Game Development](#game-development)
5. [Project layout](#project-layout)

---

## Architecture

### Boot and structure

```
 COMMAND.APP (command interpreter), other .APP       apps/command.zig, apps/command/, apps/*.zig
   │  program API (groups of function pointers)      src/kernel/abi.zig (apps/zdos/zdos.zig,
   │                                                 system.zig, gfx.zig, sdk/src/zdos.h)
 kernel ── file system logic, program loader,        src/kernel/
   │       program API, startup
   │  platform interface                             src/platform.zig
 platform backend ── console, storage, memory,       src/platform/uefi/
   │                 clock, power
 UEFI firmware ── screen, keyboard, mouse, disks, FAT, clock
   │
 Hardware
```

1. The firmware starts `\EFI\BOOT\BOOTX64.EFI`, a normal UEFI application; `src/main_uefi.zig` is its entry point.
2. `platform.init()` turns off the firmware's 5-minute watchdog (it would reset the PC), connects drivers for every disk, and calibrates the millisecond clock.
3. The kernel (`src/kernel/startup.zig`) assigns drive letters, reads `\CONF\SYSTEM.CFG` and starts `\APPS\COMMAND.APP` as a program like any other (`COMMAND -p`). COMMAND.APP runs `SCRIPTS\AUTOEXEC.CMD` beside its own folder, then its command loop. Should it end, the kernel starts it again; if it is missing, the kernel asks for its path.

The UEFI editions never call `ExitBootServices`: the firmware drives the hardware, and ZDOS uses its services for the screen, keyboard, mouse, disks and FAT, memory, the clock and power off.

### Portability (platform layer)

The code is split so that one layer can be replaced, for the BIOS and metal editions:

- **Kernel** (`src/kernel/`): file system logic (drives, paths, recursive copy and delete), program loader, program API, startup. Depends only on `src/platform.zig`.
- **Command interpreter** (`apps/command.zig`, `apps/command/`): depends only on the program API.
- **Platform interface** (`src/platform.zig`): ZDOS's own types (`Key`, `DateTime`, `EntryInfo` ...) and the functions a backend must provide.
- **UEFI backend** (`src/platform/uefi/`): those functions on firmware services.
- **BIOS backend** (`src/platform/bios/`, see [BIOS.md](BIOS.md)): on the BIOS and `src/drivers/`.
- **Metal backend** (`src/platform/metal/`): on `src/drivers/` alone.
- **Drivers** (`src/drivers/`): FAT, ext2, Minix, partition tables, ATA, NVMe/AHCI, USB, virtio, network cards, PS/2 keyboard and mouse, CMOS clock. No firmware needed.
- **CPU code** (`src/arch/x86_64.zig`, `x86.zig`, `arm64.zig`; `src/arch.zig` picks one): timer, switching to a program's stack, instruction cache sync.
- **Program API** (`src/kernel/abi.zig`): the table and its types. Depends on nothing but `std`.
- **Program libraries** (`apps/zdos/zdos.zig`, `system.zig`, `gfx.zig`, `sdk/src/zdos.h`): wrappers and entry point for Zig and C programs. They follow `abi.zig`; the C header mirrors it.

Rules the code follows:

- The kernel never imports UEFI: everything goes through `platform.console`, `platform.storage`, `platform.memory`, `platform.clock` and `platform.power`.
- Text is UTF-8 everywhere; only the UEFI backend converts to the firmware's UCS-2.
- Paths given to the platform are absolute within a volume, with `\` (`\DOCS\REPORT.TXT`). Drive letters, current directories, `.` and `..` are kernel logic.
- The backend is chosen at compile time from the target; `src/platform.zig` checks that it provides every function, so a missing one is a compile error.

### The .APP program format

An `.APP` file is a flat binary: a 64-byte header, then the program's machine code and data, linked at address 0 as position-independent code.

| Offset | Size | Field        | Meaning                                      |
| ------ | ---- | ------------ | -------------------------------------------- |
| 0      | 4    | magic        | `0x3650415A` ("ZAP6"; "ZAP3", "ZAPA")        |
| 4      | 4    | version      | API version that it needs; 1 if not exported |
| 8      | 4    | file_version | Version of the file: major (high); 0: none   |
| 12     | 4    | reserved     | 0                                            |
| 16     | 8    | entry        | offset of the entry                          |
| 24     | 8    | end          | size in memory, with `.bss`                  |
| 32     | 8    | rela_start   | start of the relocation table                |
| 40     | 8    | rela_end     | end of the relocation table                  |
| 48     | 8    | code_end     | end of the code                              |
| 56     | 8    | ro_end       | start of `.data`, `.bss`                     |

Libraries (`.ZDL`) and drivers (`.SYS`) have the same first 64 bytes, then fields of their own. `file_version` is at byte 8 in all of them: a program sets it with `pub const zdos_file_version = [4]u8{ 1, 2, 0, 0 };` in its root file (Zig, programs, libraries and drivers), `ZDOS_FILE_VERSION(1, 2, 0, 0);` at file level (C, C++) or `zdos::file_version!(1, 2, 0, 0);` (Rust); without it the field is 0. `VER FILE` shows it. `version` at byte 4 is set the same way: `pub const zdos_api_version: u32 = 2;` (Zig), `ZDOS_API_VERSION(2);` (C, C++) or `zdos::api_version!(2);` (Rust); without it 1. A version the SDK doesn't have yet stops the build.

The linker scripts in `sdk/linkers/` write this header and put code, read-only data (with the relocation table) and writable data on separate pages: 4 KiB on x86, 16 KiB on ARM64. A later ZDOS with memory protection can map them read-execute, read-only and read-write without programs being rebuilt; ZDOS doesn't use `code_end` and `ro_end` yet. The `app-*-compac.ld` scripts leave out the padding, up to two pages smaller; their header is the first 48 bytes, which is all today's ZDOS reads.

**Loading** (`src/kernel/loader.zig`):

1. Check the header: magic, version, sizes.
2. Allocate executable memory for it anywhere.
3. Read the file into it and zero the rest up to `end` (`.bss`).
4. Add the load address to every pointer listed in the relocation table (`R_X86_64_RELATIVE`), since the program was linked at 0.
5. Switch to a fresh stack (see [Stacks](#stacks)) and call `entry(&start)`, with the start record (see [Writing programs](#writing-programs)).
6. When it returns, switch back and free what the program left: open files, heap blocks, its stack and its image.

### Compatibility

Until the first release the API is **version 1** and may change in place; programs are rebuilt. ZDOS loads a file whose header asks for its own version or an older one, and refuses a newer one ("not a program"). From the release on, functions are only added, in a group's reserved slots or at its end, so programs keep working on newer ZDOS, and on an older one only calls it lacks fail, with `NotSupported`.

### Calling convention

ZDOS is compiled for the UEFI target, which uses the **Microsoft x64** convention, while programs are compiled for a freestanding target (System V by default). So every API function and the entry point are declared with the Microsoft convention: `callconv(.{ .x86_64_win = .{} })` in Zig, `__attribute__((ms_abi))` in C.

The BIOS edition uses 32-bit cdecl, ARM64 the standard AAPCS64. `abi.cc` (Zig) and `ZDOS_CALL` (C) choose by the target, so program sources don't change.

### Stacks

| Stack                           | Size                |
| ---                             |---                  |
| A program (its main thread)     | 1 MiB               |
| A thread created without a size | 256 KiB             |
| A thread created with a size    | 16 KiB to 16 MiB    |
| A task's own, where it starts its program | 64 KiB    |
| A job on another core (`cores->start`)    | 64 KiB; UEFI: the firmware's (OVMF: 32 KiB) |

- Sizes: `stacks` in `src/platform/*/config.zig`; worker cores: `src/platform/metal/smp.zig`.
- Taken in full when the program or thread starts. Zig's `threadCreate`, C's `pthread_create` and Rust's `std::thread` get the same default; `RLIMIT_STACK`: 1 MiB.
- Metal: an unmapped guard page under each stack, so an overflow is a `Stack overflow` (SIGSEGV), handled on a small spare stack. UEFI and BIOS: no guard.
- The UEFI kernel: a 1 MiB stack of its own (`src/main_uefi.zig`), else the firmware's.
- Switching stacks: `arch.callOnStack`.

### Timekeeping

UEFI has no millisecond counter. On x86-64 the backend measures the CPU's time stamp counter against a 10 ms firmware delay at startup and uses it for `millis()`; ARM64 reads its generic timer.

---

## Writing programs

Every program is entered with a **start record**: its arguments, and `group(name)`, which gives a group of functions (see [Compatibility](#compatibility) and the [reference](API.md)). The libraries connect all groups before `main`, so programs call `zdos->files->open(...)` (C) or the Zig wrappers. There is no other interface: no system calls and no standard library, like `INT 21h` for DOS programs.

Compiler settings, whatever the language:

- A freestanding target.
- Position-independent code (`-fPIE`), linked as PIE (`-pie`).
- No red zone on x86-64 (`-mno-red-zone`): firmware interrupts use the program's stack.
- The linker script `sdk/linkers/app-x86_64.ld`, which puts the header first.
- A flat binary (`objcopy -O binary`).

The commands here build for x86-64 UEFI. For the other editions only the target and the linker script change; see [BIOS.md](BIOS.md#programs) and [ARM64.md](ARM64.md#programs).

### Writing programs in Zig

A minimal program, e.g. `apps/myprog.zig`:

```zig
const zdos = @import("zdos/zdos.zig");
comptime {
    _ = zdos; // pulls in the program entry point
}

pub fn main(args: []const u8) u8 {
    zdos.print("Hello from a ZDOS program!\n");
    if (args.len > 0) zdos.printf("You passed: {s}\n", .{args});
    return 0; // exit code
}
```

`apps/zdos/zdos.zig` provides the entry point: it connects the groups and calls your `main`. The `comptime { _ = zdos; }` line is required, or Zig leaves the entry point out. The table's types come from `src/kernel/abi.zig` as the module `abi`:

```sh
zig build-exe -target x86_64-freestanding -O ReleaseSmall \
    -mno-red-zone -fPIE -fentry=zdos_entry -T sdk/linkers/app-x86_64.ld -femit-bin=build/uefi-x86_64/myprog.elf \
    --dep abi -Mroot=apps/myprog.zig -Mabi=src/kernel/abi.zig
zig objcopy -O binary build/uefi-x86_64/myprog.elf build/uefi-x86_64/MYPROG.APP
```

**See also:**  
[Compiling for ARM64](ARM64.md#programs).  
[Compiling for x86](BIOS.md#programs).

`zig build` compiles every top-level `.zig` and `.c` file in `apps/` for every edition, so a new program there needs no build command of its own. The folders below `apps/` aren't programs: `apps/zdos/` is the Zig library, `apps/command/` and `apps/ash/` hold the rest of `COMMAND.APP` and `ASH.APP`, `apps/vendor/` third-party libraries.

Programs that hash or check passwords with Argon2 (`apps/zdos/users.zig`: `LOGIN`, `PASSWD`, `ADDUSER`, `SU`, `SUDO`, `SSHD`, `SSHTEST`) are built single-threaded (`-fsingle-threaded`, `usesArgon2` in `build.zig`): std's Argon2 has a several-thread path through `std.Thread`, which has no freestanding version.

**Optimization:** `ReleaseSmall` gives the smallest programs (the one above is about 9 KB, most of it page padding: 4.5 KB with `app-x86_64-compac.ld`; `DEMO` about 78 KB). `ReleaseSafe` keeps Zig's bounds and overflow checks while developing, but programs get much larger and a failed check halts the machine.

Useful parts of `zdos/zdos.zig`:

```zig
zdos.printf("{d} files\n", .{n});                  // formatted output (up to 256 bytes)
var list = std.ArrayList(u32).init(zdos.allocator); // std containers on the ZDOS heap
const k = zdos.readKey();                           // k.char, k.scan (zdos.Scan.up, .f1 ...), k.ctrl() ...
const f = try zdos.open("D:\\NOTES.TXT", .write);  // .read / .write / .update
defer f.close();
try f.writeAll("text\n");
const dir = try zdos.openDir("");                   // "" = current directory
defer dir.close();
var e: zdos.DirEntry = undefined;
while (try dir.next(&e)) zdos.print(e.name());
zdos.makeDir("OUT") catch |err| switch (err) {      // specific causes, see Errors
    error.AlreadyExists => {},
    else => zdos.printf("{s}\n", .{zdos.message(err)}),
};
```

Zig's standard library works where it needs no OS: formatting, `std.mem`, `ArrayList`, `HashMap`, sorting, parsing. `std.fs`, `std.os`, threads and `std.heap.page_allocator` don't; use the zdos API.

In inline assembly, an `"m"` input given a value is a slot holding a pointer to it, not the value's memory: `fldcw %[cw]` with `"m" (cw)` loads half an address. Pass the address in a register: `asm volatile ("fldcw (%[p])" : : [p] "r" (&cw));`.

### Writing programs in C

Include `sdk/src/zdos.h` and define `zdos_entry`. A minimal program, `prog.c`:

```c
#include "zdos.h"

ZDOS_CALL unsigned char zdos_entry(const zdos_start *start) {
    zdos_init(start);                 /* connects the groups, sets zdos */
    zdos_puts("Hello from C!\n");
    if (start->args_len > 0) zdos->console->print(start->args, start->args_len);
    return 0;                         /* exit code */
}
```

With `zig cc`:

```sh
zig cc -target x86_64-freestanding -Os -ffreestanding -fPIE -mno-red-zone -fno-stack-protector \
    -nostdlib -Wl,-e,zdos_entry -Wl,-T,sdk/linkers/app-x86_64.ld -I sdk/src -o build/uefi-x86_64/prog.elf prog.c
zig objcopy -O binary build/uefi-x86_64/prog.elf build/uefi-x86_64/PROG.APP
```

**See also:**  
[Compiling for ARM64](ARM64.md#programs).  
[Compiling for x86](BIOS.md#programs).

or with GCC and GNU binutils:

```sh
gcc -std=c11 -Os -ffreestanding -fPIE -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables \
    -nostdlib -static-pie -Wl,--no-dynamic-linker -Wl,--build-id=none -Wl,--no-warn-rwx-segments \
    -Wl,-T,sdk/linkers/app-x86_64.ld -I sdk/src -o build/uefi-x86_64/prog.elf prog.c
objcopy -O binary build/uefi-x86_64/prog.elf build/uefi-x86_64/PROG.APP
```

`-std=c11`: in its default GNU mode GCC on Linux predefines `unix` as 1, which breaks `zdos.h` (a field is called `unix`).

Compiling and linking in separate steps (Makefiles) needs `-pie` at the link too (`-static-pie` with GCC; `zig cc` rejects `-Wl,-pie`). Without it the relocation table is empty and the program crashes or hangs at its first stored pointer. Check before `objcopy`: `readelf -h prog.elf` must show `Type: DYN`.

The loader applies only relative relocations (type 8 on x86-64 and x86, 1027 on ARM64) and refuses a program with any other ("Invalid program file"). A weak undefined symbol, for example, leaves a `GLOB_DAT` or `JUMP_SLOT` relocation when nothing defines it.

With Zig 0.14.1, `zig cc -c x.c -o /dev/null` still writes `x.o` into the current folder, and `zig cc -fsyntax-only` fails with `FileNotFound`: compile checks into a build or scratch folder.

- `zdos.h` alone has no C library: use the groups (`zdos->memory->alloc`, `zdos->files->open` ...) and its small helpers (`zdos_puts`, `zdos_strlen`, `zdos_open`). The [SDK](../sdk/README.md) adds one, with `main(argc, argv)`.
- Strings passed to the API are pointer and length, not 0-terminated.
- The compiler may emit calls to `memcpy` / `memset`. `zig cc` supplies them; with GCC, write your own if the linker misses them.
- `apps/democ.c` (`DEMOC.APP`) is a larger example: it calls each API group, its structs as `zdos.h` lays them out.

### Writing programs in C++

The same header works in C++. Build like C with `g++`, without the features that need a runtime:

```sh
g++ -Os -ffreestanding -fPIE -mno-red-zone -fno-stack-protector -fno-exceptions -fno-rtti \
    -fno-asynchronous-unwind-tables -nostdlib -static-pie -Wl,--no-dynamic-linker \
    -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-T,sdk/linkers/app-x86_64.ld -I sdk/src \
    -o build/uefi-x86_64/prog.elf prog.cpp
objcopy -O binary build/uefi-x86_64/prog.elf build/uefi-x86_64/PROG.APP
```

- [x] Classes, templates, `constexpr`, namespaces.
- [x] Global constructors, when linked with the SDK's `zdos_crt0.c` (starting at `main`).
- [x] `new` / `delete` (all forms, placement new with `<new>`), static locals, pure virtuals: the SDK's `zdos_cxx.c`. Built by hand like this, declare `extern "C" int main`.
- [x] The C++ standard library (LLVM's libc++ as Zig bundles it: `std::string`, containers, `iostream`, `fstream`, `std::filesystem`, `std::format`), exceptions, RTTI, `std::thread`, `thread_local` objects with destructors: with the SDK's `zdos-c++` (`zdos-c++ -O2 prog.cpp -o PROG.APP`), see [C++ in the SDK](../sdk/README.md#c). `sdk/examples/cxxtest.cpp` tests it; it passed on all five editions.

### Other languages

A language works if it can produce freestanding code without a runtime.

- [x] Zig, C, C++ (above).
- [x] Lua and MicroPython, as interpreters for scripts ([ports](../ports/README.md)).
- [x] Rust, with the full `std`: `sdk/bin/zdos-cargo` and the `zdos` crate ([Rust in the SDK](../sdk/README.md#rust)).
- [ ] Assembly: possible, not tested. Write the header by hand and call the table with the edition's convention.
- Go, Java, C#, JavaScript: no; they need a garbage collector, threads and virtual memory.

### Where programs and their data go

The build folders and what goes onto drive C: are listed in the README's [Building](../README.md#building). Programs built with their own scripts (`ports/`) put their `.APP` into `build/<edition>/APPS_3RD/` or `GAMES/`, and their data into `build/DATA/<NAME>/`.

A program finds its data in `..\DATA\<NAME>` seen from its own folder (`program_path`: `C:\GAMES\DOOM.APP` -> `C:\DATA\DOOM`). Data that can't be kept apart goes next to the program.

A user's own settings and files go in their home folder, `HOME` (`C:\USERS\<name>`, see [Users](USERS.md)); the user is `USER`. In Zig, `apps/zdos/users.zig` reads and writes the user list.

---

## Game Development

Games are Zig programs in `games/`, with the same entry point and API: [gfx.zig](API.md#graphics-game-keys-and-mouse-gfxzig) for graphics, game keys and the mouse, `zdos.zig` for keys and time. `games/blocks.zig` and `games/snake.zig` are small examples.

`zig build` compiles each `games/*.zig` for every edition into `build/<edition>/GAMES/` (`C:\GAMES`). A game imports the library as `@import("zdos")`; the build provides that module and `abi`.

Ported games are built by their own scripts into the same folders ([ports](../ports/README.md)).

## Project layout

- `src/`: the kernel: `kernel/` (program API, file systems, tasks, startup), `platform/` (the `uefi`, `metal` and `bios` backends), `drivers/`, `arch/`, `net/` (lwIP and its glue), `boot/bios/`.
- `apps/`: ZDOS's programs, the command interpreter (`command/`), Ash (`ash/`), the Zig library (`zdos/`), C programs on the SDK (`posix/`), third-party code (`vendor/`).
- `games/`: the games.
- `libs/`: libraries (`.ZDL`).
- `sys/`: drivers (`.SYS`).
- `sdk/`: the C and C++ SDK ([sdk/README.md](../sdk/README.md)).
- `ports/`: programs and libraries from elsewhere ([ports/README.md](../ports/README.md)).
- `tools/`: the build's tools (`build/`, `disk/`); `tests/`: the tests in QEMU.
- `conf/`, `scripts/`, `fonts/`, `keyb/`, `icons/`, `data/`: what goes onto drive C:.
- `build.zig`, `build.sh`, `dist.sh`, `install.sh`, `run-*.sh`: building, releases, installing, running in QEMU.
