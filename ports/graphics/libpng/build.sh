#!/usr/bin/env bash
# libpng: libpng.a and its headers in sdk-ports (-lpng -lz).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../libpng (LIBPNG_SRC=...), unchanged, its prebuilt config.
source "$(dirname "$0")/../../common.sh"
LIBPNG_SRC=${LIBPNG_SRC:-$SRC_ROOT/libpng}
[ -f "$LIBPNG_SRC/png.h" ] || die "no libpng sources in $LIBPNG_SRC (LIBPNG_SRC=...)"
BUILD=$ZIGDOS/build/libpng
SRCS="png pngerror pngget pngmem pngpread pngread pngrio pngrtran pngrutil pngset pngtrans pngwio pngwrite pngwtran pngwutil"
mkdir -p "$BUILD"
cp "$LIBPNG_SRC/scripts/pnglibconf.h.prebuilt" "$BUILD/pnglibconf.h"
# No CPU-specific filters (NEON's need arm/*.c and a runtime check):
FLAGS="-O2 -I$BUILD -I$LIBPNG_SRC -DPNG_ARM_NEON_OPT=0 -DPNG_INTEL_SSE_OPT=0"

for arch in $(arches "$@"); do
    select_arch "$arch"
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libz.a" ] || "$ZIGDOS/ports/libs/zlib/build.sh" "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== libpng.a for $arch ==="
    for f in $SRCS; do
        $CC $FLAGS -c "$LIBPNG_SRC/$f.c" -o "$obj/$f.o"
    done
    rm -f "$obj/libpng.a"
    zig ar rcs "$obj/libpng.a" $(for f in $SRCS; do echo "$obj/$f.o"; done)
    install_file "$obj/libpng.a" "sdk-ports/lib/$arch"
done
for h in "$LIBPNG_SRC/png.h" "$LIBPNG_SRC/pngconf.h" "$BUILD/pnglibconf.h"; do
    install_file "$h" sdk-ports/include
done
