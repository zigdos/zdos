#!/usr/bin/env bash
# TinyGL (C-Chads): libTinyGL.a and its headers in sdk-ports.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
#   build.sh --demos [ARCH]...   also its SDL_Examples (not onto C:)
# Sources: TINYGL_SRC=..., unpatched.
source "$(dirname "$0")/../../common.sh"
TINYGL_SRC=${TINYGL_SRC:-$SRC_ROOT/tinygl}
BUILD=${TINYGL_BUILD:-$ZIGDOS/build/tinygl}
[ -f "$TINYGL_SRC/include/zbuffer.h" ] || die "no TinyGL in $TINYGL_SRC (TINYGL_SRC=...)"
DEMOS=0
if [ "${1:-}" = --demos ]; then
    DEMOS=1
    shift
fi

# src/Makefile's objects and flags without -march=native and OpenMP (one core).
# Silenced: upstream's unused variables and init.c's float bit pattern test.
OBJS="api list vertex init matrix texture misc clear light clip select get zbuffer zline ztriangle
    zmath image_util msghandling arrays specbuf memory ztext zraster accum zpostprocess"
CFLAGS="-O3 -std=c99 -DNDEBUG -Wall -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable -Wno-constant-conversion"
DEMO_PROGRAMS="gears texture helloworld model menu game"
DEMO_DATA="texture.png tex.jpg tex_hole.png extrude.obj monkey3.obj"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    echo "=== libTinyGL.a for $arch ==="
    mkdir -p "$obj/lib"
    for o in $OBJS; do
        src=$TINYGL_SRC/src/$o.c
        if [ ! "$obj/lib/$o.o" -nt "$src" ] || [ "$TINYGL_SRC/include/zfeatures.h" -nt "$obj/lib/$o.o" ]; then
            $CC $CFLAGS -I"$TINYGL_SRC/include" -c "$src" -o "$obj/lib/$o.o"
        fi
    done
    rm -f "$obj/libTinyGL.a"
    zig ar rcs "$obj/libTinyGL.a" "$obj"/lib/*.o
    install_file "$obj/libTinyGL.a" "sdk-ports/lib/$arch"
    if [ $DEMOS = 1 ]; then
        echo "=== TinyGL's demos for $arch ==="
        mkdir -p "$obj/demos"
        [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL.a" ] || "$ZIGDOS/ports/graphics/sdl12/build.sh" "$arch"
        for d in $DEMO_PROGRAMS; do
            # -w: the demos' own warnings (unused results, sign mixes):
            $CC -O2 -std=c99 -w "$TINYGL_SRC/SDL_Examples/$d.c" "$obj/libTinyGL.a" -lSDL \
                -o "$obj/demos/$(echo "$d" | tr a-z A-Z).APP"
        done
        for f in $DEMO_DATA; do cp "$TINYGL_SRC/SDL_Examples/$f" "$obj/demos/"; done
        rm -f "$obj"/demos/*.elf
        echo "Demos in $obj/demos"
    fi
done

# As make install puts them (include/tinygl/GL/gl.h ...):
INC=$ZIGDOS/build/sdk-ports/include/tinygl
mkdir -p "$INC/GL"
for h in GL/gl.h zbuffer.h zfeatures.h; do
    cmp -s "$TINYGL_SRC/include/$h" "$INC/$h" || cp -p "$TINYGL_SRC/include/$h" "$INC/$h"
done
echo "Headers in build/sdk-ports/include/tinygl"
