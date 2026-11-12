#!/usr/bin/env bash
# x264: X264.ZDL, X264TEST.APP, x264.h, x264_config.h, libx264.a stubs.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/media/x264
X264_SRC=${X264_SRC:-$SRC_ROOT/x264}
BUILD=$ZIGDOS/build/x264
[ -f "$X264_SRC/x264.h" ] && [ -f "$X264_SRC/Makefile" ] ||
    die "no x264 sources in $X264_SRC (X264_SRC=...)"

API=$(sed -n 's/^#define X264_BUILD \([0-9][0-9]*\)$/\1/p' "$X264_SRC/x264.h")
[ -n "$API" ] || die "could not read X264_BUILD from x264.h"
grep -qx "X(x264_encoder_open_$API)" "$PORT/exports.def" ||
    die "exports.def must use x264_encoder_open_$API for this source version"

mkdir -p "$BUILD"
FUNCS=$BUILD/x264.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
[ -s "$FUNCS" ] || die "exports.def has no functions"

for arch in $(arches "$@"); do
    select_arch "$arch"
    case $arch in
        x86) host=i686-linux-gnu; asm=--disable-asm ;;
        x86_64) host=x86_64-linux-gnu; asm=--enable-asm ;;
        arm64) host=aarch64-linux-gnu; asm=--enable-asm ;;
    esac

    obj=$BUILD/$arch
    mkdir -p "$obj"
    flags="$host $asm"
    if [ ! -f "$obj/config.mak" ] || [ "$(cat "$obj/.flags" 2>/dev/null)" != "$flags" ] ||
        [ "$X264_SRC/x264.h" -nt "$obj/config.mak" ] || [ "$X264_SRC/configure" -nt "$obj/config.mak" ]; then
        echo "=== configure x264 for $arch ==="
        (
            cd "$obj"
            CC="$CC" AR="$SDK/bin/zdos-ar" RANLIB="$SDK/bin/zdos-ranlib" \
                STRINGS=llvm-strings "$X264_SRC/configure" --host="$host" \
                --enable-static --disable-cli --enable-pic --bit-depth=8 --chroma-format=420 \
                "$asm" --disable-opencl --disable-avs --disable-lavf --disable-ffms \
                --disable-gpac --disable-lsmash --prefix=/usr
        ) >"$obj/configure.log" 2>&1 || die "configure failed: $obj/configure.log"
        echo "$flags" >"$obj/.flags"
    fi
    grep -qx '#define HAVE_THREAD 1' "$obj/config.h" &&
        grep -qx '#define HAVE_POSIXTHREAD 1' "$obj/config.h" ||
        die "x264 POSIX threading was not enabled for $arch"

    echo "=== build x264 for $arch ==="
    (cd "$obj" && make -s -f "$X264_SRC/Makefile" -j"$(cpus)" lib-static) \
        >"$obj/make.log" 2>&1 || die "make failed: $obj/make.log"

    # Every requested export must be in this architecture's build:
    nm -g --defined-only "$obj/libx264.a" | awk 'NF == 3 && $2 ~ /^[Tt]$/ { print $3 }' |
        sort -u >"$obj/defined.txt"
    missing=$(while IFS= read -r f; do
        grep -qxF "$f" "$obj/defined.txt" || echo "$f"
    done <"$FUNCS")
    [ -z "$missing" ] || die "libx264.a lacks exports: $missing"

    echo "=== X264.ZDL for $arch ==="
    $CC -O2 -I"$obj" -I"$X264_SRC" -I"$PORT" -c "$PORT/x264_zdl.c" -o "$obj/x264_zdl.o"
    (cd "$obj" && $CC -Wl,--start-group x264_zdl.o libx264.a -Wl,--end-group \
        -Wl,--gc-sections -o X264.ZDL)
    readelf -h "$obj/X264.elf" | grep -q 'Type:.*DYN' ||
        die "X264.ZDL is not position independent: $obj/X264.elf"
    other=$(readelf -r --wide "$obj/X264.elf" |
        awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort -u)
    [ -z "$other" ] || die "X264.ZDL has non-relative relocations: $other"

    $STUBS X264 "$FUNCS" "$obj/libx264-stubs.a"

    echo "=== X264TEST.APP for $arch ==="
    $CC -O2 -I"$obj" -I"$X264_SRC" "$PORT/x264test.c" "$obj/libx264-stubs.a" -o "$obj/X264TEST.APP"

    install_app "$obj/X264.ZDL" LIBS_3RD
    install_app "$obj/X264TEST.APP" APPS_3RD
    install_file "$obj/libx264-stubs.a" "sdk-ports/lib/$arch" libx264.a
done

# x264_config.h is the same for every architecture with these options:
cp "$BUILD/$(arches "$@" | awk '{print $1}')/x264_config.h" "$BUILD/x264_config.h"
install_file "$X264_SRC/x264.h" sdk-ports/include
install_file "$BUILD/x264_config.h" sdk-ports/include
echo "x264 headers and import stubs installed in build/sdk-ports"
