#!/usr/bin/env bash
# zlib: ZLIB.ZDL, ZLIBTEST.APP, and zlib.h, zconf.h, libz.a (stubs).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../zlib (ZLIB_SRC=...), only read; built in build/zlib.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/zlib
ZLIB_SRC=${ZLIB_SRC:-$SRC_ROOT/zlib}
[ -f "$ZLIB_SRC/zlib.h" ] || die "no zlib sources in $ZLIB_SRC (ZLIB_SRC=...)"
BUILD=$ZIGDOS/build/zlib
mkdir -p "$BUILD"
SRCS="adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil"

# Every function zlib.h declares (but Windows' gzopen_w and the macros
# documented as functions); a new zlib's additions go to exports.def:
FUNCS=$BUILD/zlib.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
missing=$(sed -n 's/^ZEXTERN[^(]*ZEXPORT\(VA\)\{0,1\} *\([A-Za-z0-9_]*\) *(.*/\2/p' "$ZLIB_SRC/zlib.h" | sort -u |
    grep -vxE 'gzopen_w|deflateInit2?|inflateInit2?|inflateBackInit' | grep -vxF -f "$FUNCS" || true)
[ -z "$missing" ] || die "zlib.h has functions exports.def lacks: $missing"

# zconf.h as zlib's configure leaves it (unistd.h and stdarg.h); the
# library is compiled with the same:
cp "$ZLIB_SRC/zlib.h" "$BUILD/zlib.h"
sed -e 's/^#if HAVE_UNISTD_H-0 .*/#if 1/' -e 's/^#if HAVE_STDARG_H-0 .*/#if 1/' "$ZLIB_SRC/zconf.h" >"$BUILD/zconf.h"
grep -q '^#if 1' "$BUILD/zconf.h" || die "zconf.h: its HAVE_UNISTD_H line not found"
FLAGS="-O2 -DHAVE_UNISTD_H -DHAVE_STDARG_H -I$ZLIB_SRC"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== ZLIB.ZDL for $arch ==="
    for f in $SRCS; do
        $CC $FLAGS -c "$ZLIB_SRC/$f.c" -o "$obj/$f.o"
    done
    $CC $FLAGS -I"$PORT" -c "$PORT/zlib_zdl.c" -o "$obj/zlib_zdl.o"
    # --gc-sections: of the C library and runtime only what is used:
    (cd "$obj" && $CC $(for f in $SRCS; do echo "$f.o"; done) zlib_zdl.o -Wl,--gc-sections -o ZLIB.ZDL)
    $STUBS ZLIB "$FUNCS" "$obj/libz.a"
    echo "=== ZLIBTEST.APP for $arch ==="
    $CC -O2 -I"$BUILD" "$PORT/zlibtest.c" "$obj/libz.a" -o "$obj/ZLIBTEST.APP"
    install_app "$obj/ZLIB.ZDL" LIBS_3RD
    install_app "$obj/ZLIBTEST.APP" APPS_3RD
    install_file "$obj/libz.a" "sdk-ports/lib/$arch"
done
install_file "$BUILD/zlib.h" sdk-ports/include
install_file "$BUILD/zconf.h" sdk-ports/include
