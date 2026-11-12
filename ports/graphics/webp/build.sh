#!/usr/bin/env bash
# libwebp: WEBP.ZDL, WEBPTEST.APP, headers and -lwebp, -lwebpmux stubs.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/graphics/webp
WEBP_SRC=${WEBP_SRC:-$SRC_ROOT/libwebp}
BUILD=$ZIGDOS/build/webp
[ -f "$WEBP_SRC/configure" ] && [ -f "$WEBP_SRC/src/webp/encode.h" ] &&
    [ -f "$WEBP_SRC/src/webp/mux.h" ] && [ -f "$WEBP_SRC/src/webp/decode.h" ] ||
    die "no libwebp sources in $WEBP_SRC (WEBP_SRC=...)"

mkdir -p "$BUILD"
FUNCS=$BUILD/webp.funcs
sed -n 's/^X(\([^)]*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
[ -s "$FUNCS" ] || die "exports.def has no functions"

for arch in $(arches "$@"); do
    select_arch "$arch"
    case $arch in
        x86) host=i686-linux-gnu ;;
        x86_64) host=x86_64-linux-gnu ;;
        arm64) host=aarch64-linux-gnu ;;
    esac

    obj=$BUILD/$arch
    mkdir -p "$obj"
    flags="$host static-pic threading"
    if [ ! -f "$obj/src/Makefile" ] || [ "$(cat "$obj/.flags" 2>/dev/null)" != "$flags" ] ||
        [ "$WEBP_SRC/configure" -nt "$obj/src/Makefile" ] ||
        [ "$WEBP_SRC/configure.ac" -nt "$obj/src/Makefile" ]; then
        echo "=== configure libwebp for $arch ==="
        (
            cd "$obj"
            CC="$CC" AR="$SDK/bin/zdos-ar" RANLIB="$SDK/bin/zdos-ranlib" \
                "$WEBP_SRC/configure" --host="$host" --disable-shared --enable-static \
                --enable-pic --disable-gl --disable-sdl --prefix=/usr
        ) >"$obj/configure.log" 2>&1 || die "configure failed: $obj/configure.log"
        echo "$flags" >"$obj/.flags"
    fi

    # configure also tests pthread_cleanup_push/pop, which ZDOS lacks; the
    # worker code needs only what is there:
    grep -q '^#define WEBP_USE_THREAD 1$' "$obj/src/webp/config.h" ||
        printf '\n#define WEBP_USE_THREAD 1\n' >>"$obj/src/webp/config.h"
    grep -q '^#define WEBP_USE_THREAD 1$' "$obj/src/webp/config.h" ||
        die "could not enable libwebp threading for $arch"

    echo "=== build libwebp for $arch ==="
    make -s -C "$obj" -j"$(cpus)" >"$obj/make.log" 2>&1 ||
        die "make failed: $obj/make.log"
    WEBP_ARCHIVE=$obj/src/.libs/libwebp.a
    WEBP_MUX_ARCHIVE=$obj/src/mux/.libs/libwebpmux.a
    SHARPYUV_ARCHIVE=$obj/sharpyuv/.libs/libsharpyuv.a
    [ -f "$WEBP_ARCHIVE" ] && [ -f "$WEBP_MUX_ARCHIVE" ] &&
        [ -f "$SHARPYUV_ARCHIVE" ] ||
        die "libwebp static archives were not built for $arch"

    nm -g --defined-only "$WEBP_ARCHIVE" "$WEBP_MUX_ARCHIVE" |
        awk 'NF == 3 && $2 ~ /^[Tt]$/ { print $3 }' | sort -u >"$obj/defined.txt"
    missing=$(grep -vxF -f "$obj/defined.txt" "$FUNCS" || true)
    [ -z "$missing" ] || die "libwebp archives lack exports: $missing"

    echo "=== WEBP.ZDL for $arch ==="
    $CC -O2 -I"$PORT" -c "$PORT/webp_zdl.c" -o "$obj/webp_zdl.o"
    (cd "$obj" && $CC -Wl,--start-group webp_zdl.o "$WEBP_ARCHIVE" \
        "$WEBP_MUX_ARCHIVE" "$SHARPYUV_ARCHIVE" -Wl,--end-group -lm \
        -Wl,--gc-sections -o WEBP.ZDL)
    readelf -h "$obj/WEBP.elf" | grep -q 'Type:.*DYN' ||
        die "WEBP.ZDL is not position independent: $obj/WEBP.elf"
    other=$(readelf -r --wide "$obj/WEBP.elf" |
        awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort -u)
    [ -z "$other" ] || die "WEBP.ZDL has non-relative relocations: $other"

    $STUBS WEBP "$FUNCS" "$obj/libwebp-stubs.a"
    for lib in webp webpmux; do
        cp "$obj/libwebp-stubs.a" "$obj/lib$lib.a"
        install_file "$obj/lib$lib.a" "sdk-ports/lib/$arch"
    done

    echo "=== WEBPTEST.APP for $arch ==="
    $CC -O2 -I"$WEBP_SRC/src" "$PORT/webptest.c" "$obj/libwebp-stubs.a" -o "$obj/WEBPTEST.APP"
    install_app "$obj/WEBP.ZDL" LIBS_3RD
    install_app "$obj/WEBPTEST.APP" APPS_3RD
done

mkdir -p "$ZIGDOS/build/sdk-ports/include/webp"
for header in decode.h encode.h types.h mux.h mux_types.h; do
    install_file "$WEBP_SRC/src/webp/$header" sdk-ports/include/webp
done
echo "libwebp headers and import stubs installed in build/sdk-ports"
