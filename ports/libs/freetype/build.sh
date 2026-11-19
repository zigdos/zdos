#!/usr/bin/env bash
# FreeType: FREETYPE.ZDL, its headers and libfreetype.a (stubs); checks
# apps/zdos/freetype.zig (Zig programs' side) against them.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../freetype (FREETYPE_SRC=...), only read; built in build/freetype.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/freetype
FREETYPE_SRC=${FREETYPE_SRC:-$SRC_ROOT/freetype}
[ -f "$FREETYPE_SRC/include/ft2build.h" ] || die "no FreeType sources in $FREETYPE_SRC (FREETYPE_SRC=...)"
BUILD=$ZIGDOS/build/freetype
mkdir -p "$BUILD"
# FreeType's own list (CMakeLists.txt) without the BDF and PCF
# drivers, with its portable ftdebug.c; ftsystem.c through
# ftsystem-zdos.c (font files read into memory once):
SRCS="autofit/autofit base/ftbase base/ftbbox base/ftbdf base/ftbitmap base/ftcid base/ftfstype base/ftgasp
base/ftglyph base/ftgxval base/ftinit base/ftmm base/ftotval base/ftpatent base/ftpfr base/ftstroke base/ftsynth
base/fttype1 base/ftwinfnt bzip2/ftbzip2 cache/ftcache cff/cff cid/type1cid gzip/ftgzip hvf/hvf lzw/ftlzw
pfr/pfr psaux/psaux pshinter/pshinter psnames/psnames raster/raster sdf/sdf sfnt/sfnt smooth/smooth svg/svg
truetype/truetype type1/type1 type42/type42 winfonts/winfnt base/ftdebug"

# Every function the public headers declare (but ftmac.h's); a new
# FreeType's additions go to the end of exports.def:
FUNCS=$BUILD/freetype.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
missing=$(cd "$FREETYPE_SRC/include/freetype" && awk '
    FNR == 1 { want = 0 }
    /^[ \t]*FT_EXPORT\(/ { want = 1; sub(/.*FT_EXPORT\([^)]*\)[ \t]*/, "") }
    want && /[A-Za-z_]/ { match($0, /[A-Za-z_][A-Za-z0-9_]*/); print substr($0, RSTART, RLENGTH); want = 0 }
' $(ls *.h | grep -vx ftmac.h) | sort -u | grep -vxF -f "$FUNCS" || true)
[ -z "$missing" ] || die "FreeType's headers have functions exports.def lacks: $missing"
# freetype.zig's slots in the same order:
BINDING=$ZIGDOS/apps/zdos/freetype.zig
sed -n '/^const names = /,/^};/p' "$BINDING" | grep -o '"[A-Za-z0-9_]*"' | tr -d '"' |
    cmp -s - "$FUNCS" || die "apps/zdos/freetype.zig's names differ from exports.def"

# Its default options; the module list without BDF and PCF:
FLAGS="-O2 -DFT2_BUILD_LIBRARY -DFT_CONFIG_MODULES_H=<ftmodule-zdos.h> -I$PORT -I$FREETYPE_SRC/include"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== FREETYPE.ZDL for $arch ==="
    objs=
    for f in $SRCS; do
        o=$obj/$(basename "$f").o
        $CC $FLAGS -w -c "$FREETYPE_SRC/src/$f.c" -o "$o"
        objs="$objs $o"
    done
    $CC $FLAGS -w -I"$FREETYPE_SRC/src/base" -c "$PORT/ftsystem-zdos.c" -o "$obj/ftsystem.o"
    objs="$objs $obj/ftsystem.o"
    $CC $FLAGS -c "$PORT/freetype_zdl.c" -o "$obj/freetype_zdl.o"
    # --gc-sections: of the C library and runtime only what is used:
    $CC $objs "$obj/freetype_zdl.o" -Wl,--gc-sections -o "$obj/FREETYPE.ZDL"
    $STUBS FREETYPE "$FUNCS" "$obj/libfreetype.a"
    # freetype.zig's types as the C headers lay them out (layout.zig):
    case $arch in x86) zt="x86-freestanding -mcpu=i686" ;; x86_64) zt=x86_64-freestanding ;; arm64) zt=aarch64-freestanding ;; esac
    zig build-obj -fno-emit-bin --cache-dir "$BUILD/zig-cache" -target $zt -D__zdos__=1 -I"$SDK/compat" -I"$SDK/src" -I"$FREETYPE_SRC/include" \
        --dep freetype -Mroot="$PORT/layout.zig" --dep abi -Mfreetype="$BINDING" -Mabi="$ZIGDOS/src/kernel/abi.zig" ||
        die "apps/zdos/freetype.zig's types differ from FreeType's for $arch"
    install_app "$obj/FREETYPE.ZDL" LIBS_3RD
    install_file "$obj/libfreetype.a" "sdk-ports/lib/$arch"
done
# The headers, as FreeType installs them (include/freetype2):
rm -rf "$ZIGDOS/build/sdk-ports/include/freetype2"
mkdir -p "$ZIGDOS/build/sdk-ports/include/freetype2"
cp "$FREETYPE_SRC/include/ft2build.h" "$ZIGDOS/build/sdk-ports/include/freetype2/"
cp -R "$FREETYPE_SRC/include/freetype" "$ZIGDOS/build/sdk-ports/include/freetype2/"
echo "Copied to build/sdk-ports/include/freetype2"
