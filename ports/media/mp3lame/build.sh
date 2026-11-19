#!/usr/bin/env bash
# LAME: MP3LAME.ZDL, LAMETEST.APP, lame.h and libmp3lame.a stubs.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/media/mp3lame
MP3LAME_SRC=${MP3LAME_SRC:-$SRC_ROOT/mp3lame}
BUILD=$ZIGDOS/build/mp3lame
[ -f "$MP3LAME_SRC/configure" ] && [ -f "$MP3LAME_SRC/include/lame.h" ] &&
    [ -f "$MP3LAME_SRC/include/libmp3lame.sym" ] ||
    die "no LAME sources in $MP3LAME_SRC (MP3LAME_SRC=...)"

mkdir -p "$BUILD"

for arch in $(arches "$@"); do
    select_arch "$arch"
    case $arch in
        x86) host=i686-linux-gnu ;;
        x86_64) host=x86_64-linux-gnu ;;
        arm64) host=aarch64-linux-gnu ;;
    esac

    obj=$BUILD/$arch
    mkdir -p "$obj"
    funcs=$obj/lame.funcs
    exports=$obj/exports.def
    awk 'NF != 1 || $1 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ { exit 1 }
         { print $1 }' "$MP3LAME_SRC/include/libmp3lame.sym" >"$funcs" ||
        die "invalid symbol in $MP3LAME_SRC/include/libmp3lame.sym"
    [ -s "$funcs" ] || die "LAME export list is empty"
    sort "$funcs" | uniq -d | grep -q . && die "duplicate symbol in LAME export list"
    sed 's/^/X(/; s/$/)/' "$funcs" >"$exports"

    flags="$host --disable-nasm --disable-decoder --disable-frontend"
    if [ ! -f "$obj/Makefile" ] || [ "$(cat "$obj/.flags" 2>/dev/null)" != "$flags" ] ||
        [ "$MP3LAME_SRC/configure" -nt "$obj/Makefile" ] ||
        [ "$MP3LAME_SRC/configure.ac" -nt "$obj/Makefile" ]; then
        echo "=== configure LAME for $arch ==="
        (
            cd "$obj"
            CC="$CC" AR="$SDK/bin/zdos-ar" RANLIB="$SDK/bin/zdos-ranlib" \
                "$MP3LAME_SRC/configure" --host="$host" --disable-shared --enable-static \
                --disable-nasm --disable-decoder --disable-frontend --prefix=/usr
        ) >"$obj/configure.log" 2>&1 || die "configure failed: $obj/configure.log"
        echo "$flags" >"$obj/.flags"
    fi

    echo "=== build LAME for $arch ==="
    make -s -C "$obj/libmp3lame" -j"$(cpus)" >"$obj/make.log" 2>&1 ||
        die "make failed: $obj/make.log"
    archive=$obj/libmp3lame/.libs/libmp3lame.a
    [ -f "$archive" ] || die "LAME static library not found: $archive"

    nm -g --defined-only "$archive" | awk 'NF == 3 && $2 ~ /^[Tt]$/ { print $3 }' |
        sort -u >"$obj/defined.txt"
    missing=$(grep -vxF -f "$obj/defined.txt" "$funcs" || true)
    [ -z "$missing" ] || die "LAME library lacks exports: $missing"

    echo "=== MP3LAME.ZDL for $arch ==="
    $CC -O2 -I"$obj" -I"$MP3LAME_SRC/include" -I"$MP3LAME_SRC" -I"$PORT" \
        -c "$PORT/lame_zdl.c" -o "$obj/lame_zdl.o"
    (cd "$obj" && $CC -Wl,--start-group lame_zdl.o "$archive" -Wl,--end-group \
        -lm -Wl,--gc-sections -o MP3LAME.ZDL)
    readelf -h "$obj/MP3LAME.elf" | grep -q 'Type:.*DYN' ||
        die "MP3LAME.ZDL is not position independent: $obj/MP3LAME.elf"
    other=$(readelf -r --wide "$obj/MP3LAME.elf" |
        awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort -u)
    [ -z "$other" ] || die "MP3LAME.ZDL has non-relative relocations: $other"

    $STUBS MP3LAME "$funcs" "$obj/libmp3lame-stubs.a"

    echo "=== LAMETEST.APP for $arch ==="
    $CC -O2 -I"$MP3LAME_SRC/include" "$PORT/lametest.c" \
        "$obj/libmp3lame-stubs.a" -o "$obj/LAMETEST.APP"

    install_app "$obj/MP3LAME.ZDL" LIBS_3RD
    for edition in $EDITIONS; do
        rm -f "$ZIGDOS/build/$edition/LIBS_3RD/LAME.ZDL"
    done
    install_app "$obj/LAMETEST.APP" APPS_3RD
    install_file "$obj/libmp3lame-stubs.a" "sdk-ports/lib/$arch" libmp3lame.a
done

install_file "$MP3LAME_SRC/include/lame.h" sdk-ports/include
echo "LAME header and import stubs installed in build/sdk-ports"
