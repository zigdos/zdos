#!/usr/bin/env bash
# libass: LIBASS.ZDL, its headers and libass.a (stubs).
# It uses FREETYPE.ZDL, HARFBUZZ.ZDL and SHNBIDI.ZDL (their ports are
# built first if missing); linebreak.zig breaks lines,
# ass_zdosfonts.c gives the fonts.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../libass (LIBASS_SRC=...), only read; built in build/libass.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/libass
LIBASS_SRC=${LIBASS_SRC:-$SRC_ROOT/libass}
[ -f "$LIBASS_SRC/libass/ass.h" ] || die "no libass sources in $LIBASS_SRC (LIBASS_SRC=...)"
BUILD=$ZIGDOS/build/libass
PORTS=$ZIGDOS/build/sdk-ports
mkdir -p "$BUILD"
# Its meson.build's list, the C versions of the assembly:
SRCS="c/c_be_blur c/c_blend_bitmaps c/c_blur c/c_rasterizer ass ass_arabic_charmap ass_bitmap ass_bitmap_engine
ass_blur ass_cache ass_drawing ass_filesystem ass_font ass_fontselect ass_library ass_outline ass_parse
ass_rasterizer ass_render ass_render_api ass_shaper ass_string ass_strtod ass_utils"

# Its own export list (libass/libass.sym); a new libass's additions go
# to the end of exports.def:
FUNCS=$BUILD/libass.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
missing=$(tr -d '\r' <"$LIBASS_SRC/libass/libass.sym" | sed '/^\s*$/d' | grep -vxF -f "$FUNCS" || true)
[ -z "$missing" ] || die "libass/libass.sym has functions exports.def lacks: $missing"

# ass_fontselect.c with ZDOS's font provider in its table
# (libass-zdos.patch), on a copy:
mkdir -p "$BUILD/src/libass"
cp "$LIBASS_SRC/libass/ass_fontselect.c" "$BUILD/src/libass/"
patch -s -d "$BUILD/src" -p1 <"$PORT/libass-zdos.patch" || die "libass-zdos.patch doesn't apply"

FLAGS="-O2 -I$PORT -I$LIBASS_SRC/libass -I$PORTS/include/freetype2 -I$PORTS/include/harfbuzz -I$PORTS/include/sheenbidi"

for arch in $(arches "$@"); do
    select_arch "$arch"
    need_port libs/freetype libfreetype.a FREETYPE.ZDL
    need_port libs/sheenbidi libsheenbidi.a SHNBIDI.ZDL
    need_port libs/harfbuzz libharfbuzz.a HARFBUZZ.ZDL
    obj=$BUILD/$arch
    mkdir -p "$obj/c"
    echo "=== LIBASS.ZDL for $arch ==="
    objs=
    for f in $SRCS; do
        src=$LIBASS_SRC/libass/$f.c
        [ "$f" = ass_fontselect ] && src=$BUILD/src/libass/$f.c
        $CC $FLAGS -w -c "$src" -o "$obj/$f.o"
        objs="$objs $obj/$f.o"
    done
    $CC $FLAGS -c "$PORT/ass_zdosfonts.c" -o "$obj/ass_zdosfonts.o"
    objs="$objs $obj/ass_zdosfonts.o"
    $CC $FLAGS -Wno-deprecated-declarations -c "$PORT/libass_zdl.c" -o "$obj/libass_zdl.o"
    # Line breaking (libunibreak's interface), ours, in Zig:
    case $arch in
        x86) zt="-target x86-freestanding -mcpu=i686" ;;
        x86_64) zt="-target x86_64-freestanding -mno-red-zone" ;;
        arm64) zt="-target aarch64-freestanding" ;;
    esac
    zig build-obj $zt -O ReleaseSmall -fPIC -fno-stack-protector -fno-stack-check \
        --cache-dir "$BUILD/zig-cache" -femit-bin="$obj/linebreak.o" "$PORT/linebreak.zig"
    # The three libraries through their stubs; --gc-sections: of the C
    # library and runtime only what is used:
    lib=$PORTS/lib/$arch
    $CC $objs "$obj/libass_zdl.o" "$obj/linebreak.o" "$lib/libfreetype.a" "$lib/libharfbuzz.a" "$lib/libsheenbidi.a" \
        -Wl,--gc-sections -o "$obj/LIBASS.ZDL"
    $STUBS LIBASS "$FUNCS" "$obj/libass.a"
    install_app "$obj/LIBASS.ZDL" LIBS_3RD
    install_file "$obj/libass.a" "sdk-ports/lib/$arch"
done
# The headers, as libass installs them (include/ass):
mkdir -p "$PORTS/include/ass"
cp "$LIBASS_SRC/libass/ass.h" "$LIBASS_SRC/libass/ass_types.h" "$PORTS/include/ass/"
echo "Copied to build/sdk-ports/include/ass"
