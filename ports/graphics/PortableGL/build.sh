#!/usr/bin/env bash
# PortableGL: portablegl.h into sdk-ports/include.
#   build.sh --demos [ARCH]...   also PGLCUBE and upstream's SDL 2
#                                examples (not onto C:)
# Sources: PORTABLEGL_SRC=..., used as they are.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/graphics/PortableGL
PGL_SRC=${PORTABLEGL_SRC:-$SRC_ROOT/PortableGL}
BUILD=${PORTABLEGL_BUILD:-$ZIGDOS/build/PortableGL}
[ -f "$PGL_SRC/portablegl.h" ] || die "no PortableGL in $PGL_SRC (PORTABLEGL_SRC=...)"
DEMOS=0
if [ "${1:-}" = --demos ]; then
    DEMOS=1
    shift
fi

INC=$ZIGDOS/build/sdk-ports/include
mkdir -p "$INC"
cmp -s "$PGL_SRC/portablegl.h" "$INC/portablegl.h" || cp -p "$PGL_SRC/portablegl.h" "$INC/"
echo "Copied to build/sdk-ports/include/portablegl.h"
[ $DEMOS = 1 ] || exit 0

# Name, sources, CUTILS_SIZE_T (from their Makefiles). Silenced:
# portablegl.h's warnings (int limits as floats, an unused variable)
# and the examples'.
C_EXAMPLES="ex1:examples/original/ex1.c ex2:examples/original/ex2.c ex3:examples/original/ex3.c
    gears:examples/classic/gears.c"
CXX_EXAMPLES="lesson6:examples/webgl_lessons/lesson6.cpp,glcommon/gltools.cpp:int
    shadertoy:demos/shadertoy.cpp,glcommon/gltools.cpp,glcommon/rsw_math.cpp:long"
FLAGS="-O2 -DNDEBUG -DUSING_PORTABLEGL -fno-strict-aliasing -I$PGL_SRC -I$PGL_SRC/glcommon -I$PGL_SRC/external
    -I$ZIGDOS/build/sdk-ports/include/SDL2 -w"
# lesson6 changes folder (my_chdir) to load ../../media/textures/ crate.gif;
# shadertoy loads ../media/textures/ from pgl/demos:
CHDIR=(-include unistd.h '-Dmy_chdir(x)=chdir(x)')
TEXTURES="crate.gif"
SHADERTOY_TEXTURES="tex00.jpg tex01.jpg tex02.jpg tex06.jpg tex09.jpg"

for arch in $(arches "$@"); do
    select_arch "$arch"
    out=$BUILD/$arch/pgl/demos
    mkdir -p "$out" "$BUILD/$arch/media/textures" "$BUILD/$arch/pgl/media/textures"
    echo "=== PortableGL's demos for $arch ==="
    $CC -O2 -I"$PGL_SRC" -Wall -Wno-unused-parameter -Wno-implicit-const-int-float-conversion \
        -Wno-unused-but-set-variable "$PORT/zdos/pglcube.c" -o "$out/PGLCUBE.APP"
    if [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL2.a" ]; then
        for t in $C_EXAMPLES; do
            $CC $FLAGS -DCUTILS_SIZE_T=int "$PGL_SRC/${t#*:}" -lSDL2 -o "$out/$(echo "${t%%:*}" | tr a-z A-Z).APP"
        done
        for t in $CXX_EXAMPLES; do
            name=${t%%:*} rest=${t#*:}
            srcs=()
            for s in $(echo "${rest%:*}" | tr ',' ' '); do srcs+=("$PGL_SRC/$s"); done
            "$ZDOS_CC" --arch="$arch" -x c++ -std=c++20 -fno-rtti -fno-exceptions $FLAGS -DCUTILS_SIZE_T="${rest##*:}" \
                "${CHDIR[@]}" "${srcs[@]}" -lSDL2 -o "$out/$(echo "$name" | tr a-z A-Z).APP"
        done
        for f in $TEXTURES; do cp "$PGL_SRC/media/textures/$f" "$BUILD/$arch/media/textures/"; done
        for f in $SHADERTOY_TEXTURES; do cp "$PGL_SRC/media/textures/$f" "$BUILD/$arch/pgl/media/textures/"; done
    else
        echo "No libSDL2.a for $arch (ports/graphics/SDL/build.sh $arch): only PGLCUBE"
    fi
    rm -f "$out"/*.elf
    echo "Demos in $out"
done
