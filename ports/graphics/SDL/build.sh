#!/usr/bin/env bash
# SDL2: SDL2.ZDL; libSDL2.a (stubs), libSDL2-static.a, libSDL2_test.a,
# an empty libSDL2main.a, the headers and sdl2-config in sdk-ports.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
#   build.sh --tests [ARCH]...   also SDL's test programs (not onto C:)
# Sources: SDL 2 (SDL_SRC=...), unchanged: a copy with the ZDOS
# backends and sdl-zdos.patch is built in build/SDL (SDL_BUILD=...).
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/graphics/SDL
SDL_SRC=${SDL_SRC:-$SRC_ROOT/SDL}
BUILD=${SDL_BUILD:-$ZIGDOS/build/SDL}
TREE=$BUILD/tree
[ -f "$SDL_SRC/include/SDL_version.h" ] || die "no SDL in $SDL_SRC (SDL_SRC=...)"
TESTS=0
if [ "${1:-}" = --tests ]; then
    TESTS=1
    shift
fi

# SDL's src and include (times kept), patched files fresh when the
# patch or they changed, the port's files on top:
PATCHED="src/dynapi/SDL_dynapi.h src/video/SDL_video.c src/video/SDL_sysvideo.h src/audio/SDL_audio.c src/audio/SDL_sysaudio.h"
mkdir -p "$TREE"
excludes=(--exclude=include/SDL_config.h)
for f in $PATCHED; do excludes+=(--exclude="$f"); done
(cd "$SDL_SRC" && rsync -a "${excludes[@]}" src include "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$SDL_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/sdl-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$SDL_SRC/$f" "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/sdl-zdos.patch" || die "sdl-zdos.patch doesn't apply to $SDL_SRC"
fi
rsync -a "$PORT/src/" "$TREE/src/"
cmp -s "$PORT/SDL_config_zdos.h" "$TREE/include/SDL_config.h" || cp -p "$PORT/SDL_config_zdos.h" "$TREE/include/SDL_config.h"

# Name and sources (in SDL's test/), and their data:
TEST_PROGRAMS="testdraw2:testdraw2.c testsprite2:testsprite2.c,testutils.c testkeys:testkeys.c
    testmouse:testmouse.c testwm2:testwm2.c loopwave:loopwave.c,testutils.c testthread:testthread.c
    testtimer:testtimer.c testaudioinfo:testaudioinfo.c testplatform:testplatform.c
    testfilesystem:testfilesystem.c checkkeys:checkkeys.c"
TEST_DATA="icon.bmp sample.wav"

# SDL's dynamic API list as ZDOS's configuration selects it (the same
# on every CPU), for the stubs; sdl2_zdl.c builds the table:
FUNCS=$BUILD/sdl2.funcs
printf '#include "SDL.h"\n#include "SDL_syswm.h"\n#include "SDL_vulkan.h"\n#define SDL_DYNAPI_PROC(rc, fn, params, args, ret) ZDOS_EXPORT fn\n#include "dynapi/SDL_dynapi_procs.h"\n' >"$BUILD/procs.c"
"$ZDOS_CC" --arch=x86_64 -E -P -I"$TREE/include" -I"$TREE/src" "$BUILD/procs.c" |
    grep -o 'ZDOS_EXPORT [A-Za-z0-9_]*' | sed 's/^ZDOS_EXPORT //' >"$FUNCS"
[ "$(wc -l <"$FUNCS")" -gt 800 ] || die "SDL's dynamic API list not found"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    echo "=== libSDL2.a for $arch ==="
    make -s -f "$PORT/Makefile" -j"$(cpus)" TREE="$TREE" OBJ="$obj" CC="$CC" CFLAGS="-O2 -w" "$obj/libSDL2.a"
    echo "=== SDL2.ZDL for $arch ==="
    $CC -O2 -w -I"$TREE/include" -I"$TREE/src" -c "$PORT/sdl2_zdl.c" -o "$obj/sdl2_zdl.o"
    # --gc-sections: of the C library and runtime only what is used:
    (cd "$obj" && $CC sdl2_zdl.o libSDL2.a -Wl,--gc-sections -o SDL2.ZDL)
    mkdir -p "$obj/zdl"
    $STUBS SDL2 "$FUNCS" "$obj/zdl/libSDL2.a"
    install_app "$obj/SDL2.ZDL" LIBS_3RD
    install_file "$obj/zdl/libSDL2.a" "sdk-ports/lib/$arch"
    install_file "$obj/libSDL2.a" "sdk-ports/lib/$arch" libSDL2-static.a
    # The test library and an empty SDL2main (ZDOS calls main itself):
    mkdir -p "$obj/test"
    for src in "$TREE"/src/test/*.c; do
        o=$obj/test/$(basename "$src" .c).o
        [ "$o" -nt "$src" ] || $CC -O2 -w -I"$TREE/include" -c "$src" -o "$o"
    done
    rm -f "$obj/libSDL2_test.a" "$obj/libSDL2main.a"
    zig ar rcs "$obj/libSDL2_test.a" "$obj"/test/*.o
    zig ar rcs "$obj/libSDL2main.a"
    for lib in libSDL2_test.a libSDL2main.a; do install_file "$obj/$lib" "sdk-ports/lib/$arch"; done
    if [ $TESTS = 1 ]; then
        echo "=== SDL's tests for $arch ==="
        mkdir -p "$obj/tests"
        for t in $TEST_PROGRAMS; do
            name=${t%%:*}
            srcs=()
            for s in $(echo "${t#*:}" | tr ',' ' '); do srcs+=("$SDL_SRC/test/$s"); done
            $CC -O2 -w -I"$TREE/include" "${srcs[@]}" "$obj/libSDL2_test.a" "$obj/zdl/libSDL2.a" \
                -o "$obj/tests/$(echo "$name" | tr a-z A-Z).APP"
        done
        for f in $TEST_DATA; do cp "$SDL_SRC/test/$f" "$obj/tests/"; done
        cp "$obj/SDL2.ZDL" "$obj/tests/" # found in the program's folder too
        rm -f "$obj"/tests/*.elf
        echo "Tests in $obj/tests"
    fi
done

# As configure installs them; sdl2-config for build scripts:
INC=$ZIGDOS/build/sdk-ports/include/SDL2
mkdir -p "$INC"
for h in "$TREE"/include/*.h; do
    case $(basename "$h") in SDL_config_*.h | SDL_revision.h.cmake) continue ;; esac
    cmp -s "$h" "$INC/$(basename "$h")" || cp -p "$h" "$INC/"
done
mkdir -p "$ZIGDOS/build/sdk-ports/bin"
VERSION=$(awk '/^#define SDL_MAJOR_VERSION/ { a = $3 } /^#define SDL_MINOR_VERSION/ { b = $3 }
    /^#define SDL_PATCHLEVEL/ { c = $3 } END { print a "." b "." c }' "$TREE/include/SDL_version.h")
sed "s#@VERSION@#$VERSION#" "$PORT/sdl2-config" >"$ZIGDOS/build/sdk-ports/bin/sdl2-config"
chmod +x "$ZIGDOS/build/sdk-ports/bin/sdl2-config"
echo "Headers in build/sdk-ports/include/SDL2, sdl2-config in build/sdk-ports/bin"
