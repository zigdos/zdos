# Ports

Programs and libraries from elsewhere, built for ZDOS with its SDK (`sdk/`). They sit in folders by kind (`coding/`, `databases/`, `games/`, `graphics/`, `libs/`, `media/`, `network/`, `office/`), one folder per port. A port keeps only what ZDOS needs on top of the original sources (configuration, patches, backends, a library's export table) and one `build.sh`. Details of a port are in its own `README.md` and in the header of its `build.sh`.

## Sources

The original sources stay outside this tree, each in a folder of its own in `$ZDOS_PORTS_SRC` (`$ZDOS_PORTS_SRC/lua`, `$ZDOS_PORTS_SRC/SDL` ...; the folder next to zigdos, `../lua`, when that variable is unset), and are not changed there. Ports that need patches copy the sources into `build/<port>/` and patch the copy. A port's own variable (`LUA_SRC`, `SDL_SRC` ...) moves just that one.

## Building

```sh
ports/<kind>/<port>/build.sh                 # all three CPUs
ports/<kind>/<port>/build.sh x86 arm64       # some of them: x86, x86_64, arm64
zig build                                    # puts the results onto drive C:
```

A port that needs another one (a program on SDL, a library on zlib) builds it first if it is missing.

## What a `build.sh` does

1. Copies the port's files into the sources, only those that changed and keeping their times, so a rebuild compiles only what changed.
2. Builds with the SDK's `zdos-cc` (see [sdk/README.md](../sdk/README.md#zdos-cc)), with the CPU picked by `--arch=`.
3. Checks that a program is position-independent and turns it into a flat `.APP`.
4. Copies the results into ZDOS's build folders, which `zig build` keeps and puts onto C:.

Tools a port's build runs on the build machine (code generators and the like) are compiled with the host's `cc`, not `zdos-cc`. Make passes a `CC=` given on its command line to every sub-make, so such tools need their own step or their own `CC`.

| What                 | Into                        | On ZDOS          |
| -------------------- | --------------------------- | ---------------- |
| programs             | `build/<edition>/APPS_3RD/` | `C:\APPS`        |
| games                | `build/<edition>/GAMES/`    | `C:\GAMES`       |
| libraries (`.ZDL`)   | `build/<edition>/LIBS_3RD/` | `C:\LIBS`        |
| data                 | `build/DATA/<NAME>/`        | `C:\DATA\<NAME>` |
| headers, libs, stubs | `build/sdk-ports/`          | -                |

`build/sdk-ports/` holds the headers, static libraries and import stubs that other ports build against; `zdos-cc` finds them, and they don't go onto ZDOS.

A program is built once per CPU and goes into every edition of it: x86 into `bios-x86`, x86_64 into `uefi-x86_64` and `metal-x86_64`, arm64 into `uefi-arm64` and `metal-arm64`.

## A new port

Add a folder under its kind with `build.sh` (sourcing `../../common.sh`, which has the architectures, `zdos-cc` and the install helpers; bash 3.2 compatible for macOS) and a short `README.md`. Put its license into `docs/COPYING/`, which every build copies to `C:\DOCS\COPYING`.
