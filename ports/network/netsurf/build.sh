#!/usr/bin/env bash
# NetSurf's framebuffer frontend on the ZDOS drawing buffer, no SDL.
#   build.sh [x86|x86_64|arm64]...   (none: all three)

source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/network/netsurf
NETSURF_SRC=${NETSURF_SRC:-$SRC_ROOT/netsurf}
CURL_SRC=${CURL_SRC:-$SRC_ROOT/curl}
BUILD=$ZIGDOS/build/netsurf
STAGED_SRC=$BUILD/src

[ -f "$NETSURF_SRC/Makefile" ] &&
    [ -f "$NETSURF_SRC/netsurf/frontends/framebuffer/Makefile" ] ||
    die "no NetSurf source tree in $NETSURF_SRC (NETSURF_SRC=...)"
[ -f "$CURL_SRC/configure" ] ||
    die "no curl source tree in $CURL_SRC (CURL_SRC=...)"
command -v rsync >/dev/null || die "rsync is required"
command -v gperf >/dev/null || die "gperf is required"

mkdir -p "$STAGED_SRC"
rsync -a --delete "$NETSURF_SRC/" "$STAGED_SRC/"
cp "$PORT/zdos_surface.c" "$STAGED_SRC/libnsfb/src/surface/zdos.c"
cp "$PORT/Makefile.config" "$STAGED_SRC/netsurf/Makefile.config"
cp "$PORT/libdom.config.override" "$STAGED_SRC/libdom/Makefile.config.override"
cp "$PORT/libparserutils.config.override" "$STAGED_SRC/libparserutils/Makefile.config.override"
cp "$SDK/src/zdos_display.c" "$STAGED_SRC/netsurf/frontends/framebuffer/zdos_display.c"
cp "$SDK/src/zdos_input.c" "$STAGED_SRC/netsurf/frontends/framebuffer/zdos_input.c"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/libnsfb-zdos-surface.patch" ||
    die "libnsfb-zdos-surface.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/fb-default-surface.patch" ||
    die "fb-default-surface.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/libparserutils-fallback.patch" ||
    die "libparserutils-fallback.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/fetch-nocurl.patch" ||
    die "fetch-nocurl.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/config-zdos.patch" ||
    die "config-zdos.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/filepath-zdos.patch" ||
    die "filepath-zdos.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/makefile-zdos.patch" ||
    die "makefile-zdos.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/utf8-local-zdos.patch" ||
    die "utf8-local-zdos.patch does not apply to $NETSURF_SRC"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/duktape-zdos.patch" ||
    die "duktape-zdos.patch does not apply to $NETSURF_SRC"
if ! grep -q 'S_FRONTEND += zdos_display.c zdos_input.c' \
    "$STAGED_SRC/netsurf/frontends/framebuffer/Makefile"; then
    patch -s -d "$STAGED_SRC" -p1 <"$PORT/framebuffer-zdos.patch" ||
        die "framebuffer-zdos.patch does not apply to $NETSURF_SRC"
fi
cp "$PORT/zdos_download.c" "$STAGED_SRC/netsurf/frontends/framebuffer/zdos_download.c"
patch -s -d "$STAGED_SRC" -p1 <"$PORT/download-zdos.patch" ||
    die "download-zdos.patch does not apply to $NETSURF_SRC"

# Makefile.config's wheel setting, for libnsfb's zdos surface:
natural_scroll=$(sed -n 's/^override NETSURF_ZDOS_NATURAL_SCROLL := *//p' "$PORT/Makefile.config")
# and its x86 CPU; -mstackrealign as not every entry to a program's code
# is known to keep SSE's 16-byte stack alignment:
x86_cpu=$(sed -n 's/^override NETSURF_ZDOS_X86_CPU := *//p' "$PORT/Makefile.config")

for arch in $(arches "$@"); do
    select_arch "$arch"
    case $arch in
        x86) host=i686-unknown-linux-musl ;;
        x86_64) host=x86_64-unknown-linux-musl ;;
        arm64) host=aarch64-unknown-linux-musl ;;
    esac
    obj=$BUILD/$arch
    mkdir -p "$obj"
    netsurf_cc=$SDK/bin/zdos-cc
    if [ "$arch" = x86 ] && [ -n "$x86_cpu" ] && [ "$x86_cpu" != i686 ]; then
        # A command of its own: NetSurf's make runs `which $(CC)`,
        # which takes flags in CC as its options:
        netsurf_cc=$obj/zdos-cc-$x86_cpu
        printf '#!/bin/sh\nexec "%s" -mcpu=%s -mstackrealign "$@"\n' \
            "$SDK/bin/zdos-cc" "$x86_cpu" >"$netsurf_cc"
        chmod +x "$netsurf_cc"
    fi
    prefix=$obj/install
    SRC=$obj/src
    curl_obj=$obj/curl
    curl_prefix=$curl_obj/install
    mkdir -p "$obj"
    mkdir -p "$SRC"
    rsync -a --delete "$STAGED_SRC/" "$SRC/"
    echo "=== NetSurf framebuffer for $arch ==="
    mkdir -p "$curl_obj"
    # zlib, for gzip pages: without it curl fails them:
    "$ZIGDOS/ports/libs/zlib/build.sh" "$arch" >"$obj/zlib-build.log" 2>&1 ||
        die "zlib build failed for $arch; see $obj/zlib-build.log"
    zlib_prefix=$curl_obj/zlib
    mkdir -p "$zlib_prefix/include" "$zlib_prefix/lib"
    cp "$ZIGDOS/build/sdk-ports/include/zlib.h" "$ZIGDOS/build/sdk-ports/include/zconf.h" "$zlib_prefix/include/"
    cp "$ZIGDOS/build/sdk-ports/lib/$arch/libz.a" "$zlib_prefix/lib/"
    # PNG, JPEG and curl's TLS from sdk-ports (built first if missing):
    lib=$ZIGDOS/build/sdk-ports/lib/$arch
    [ -f "$lib/libpng.a" ] || "$ZIGDOS/ports/graphics/libpng/build.sh" "$arch"
    [ -f "$lib/libjpeg.a" ] || "$ZIGDOS/ports/graphics/libjpeg/build.sh" "$arch"
    [ -f "$lib/libmbedtls.a" ] || "$ZIGDOS/ports/libs/mbedtls/build.sh" "$arch"
    # WebP: always, as older WEBP.ZDLs lack the decoder (incremental):
    "$ZIGDOS/ports/graphics/webp/build.sh" "$arch" >"$obj/webp-build.log" 2>&1 ||
        die "libwebp build failed for $arch; see $obj/webp-build.log"
    (
        cd "$curl_obj"
        export ZDOS_ARCH=$arch
        "$CURL_SRC/configure" --host="$host" --build="$(gcc -dumpmachine)" \
                --prefix="$curl_prefix" --enable-static --disable-shared \
                --with-mbedtls --with-ca-bundle=C:/CONF/CACERT.PEM --without-ca-path \
                --disable-ftp --disable-file --disable-ldap \
                --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
                --disable-tftp --disable-pop3 --disable-imap --disable-smb \
                --disable-smtp --disable-gopher --disable-mqtt --disable-ipv6 \
                --disable-threaded-resolver --disable-unix-sockets \
                --with-zlib="$zlib_prefix" --without-brotli --without-zstd --without-libpsl \
                --without-libidn2 --without-nghttp2 --without-nghttp3 \
                --without-quiche --without-ngtcp2 --without-libssh2 \
                --without-librtmp --disable-manual --disable-docs \
                CC="$SDK/bin/zdos-cc" AR="$SDK/bin/zdos-ar" \
                RANLIB="$SDK/bin/zdos-ranlib"
        make -j"$(cpus)"
        make install
        # libcurl.pc requires zlib's: one beside it, for the zlib port:
        printf 'Name: zlib\nDescription: zlib port\nVersion: 1.3.2\nLibs: -L%s/lib -lz\nCflags: -I%s/include\n' \
            "$zlib_prefix" "$zlib_prefix" >"$curl_prefix/lib/pkgconfig/zlib.pc"
        # NetSurf finds libpng by pkg-config:
        printf 'Name: libpng\nDescription: libpng port\nVersion: 1.6\nRequires: zlib\nLibs: -lpng\nCflags:\n' \
            >"$curl_prefix/lib/pkgconfig/libpng.pc"
        printf 'Name: libwebp\nDescription: libwebp port\nVersion: 1.6\nLibs: -lwebp\nCflags:\n' \
            >"$curl_prefix/lib/pkgconfig/libwebp.pc"
        grep -q '^#define USE_MBEDTLS 1' lib/curl_config.h || { echo "curl configured without mbedTLS"; exit 1; }
    ) >"$curl_obj/build.log" 2>&1 ||
        die "curl build failed for $arch; see $curl_obj/build.log"
    # nsgenbind runs on this machine: built with cc, as make would pass
    # its command line's CC=zdos-cc on to it; NSBUILD_TARG= then skips it:
    (
        cd "$SRC"
        make install --directory=buildsystem PREFIX="$SRC/inst-framebuffer" DESTDIR=
        make install --directory=nsgenbind HOST="$(cc -dumpmachine)" CC=cc \
            PREFIX="$SRC/inst-framebuffer" DESTDIR=
    ) >"$obj/nsgenbind-build.log" 2>&1 ||
        die "nsgenbind build failed; see $obj/nsgenbind-build.log"
    (
        cd "$SRC"
        ZDOS_ARCH=$arch \
        PKG_CONFIG_LIBDIR="$curl_prefix/lib/pkgconfig:$SRC/inst-framebuffer/lib/pkgconfig" \
            make -j"$(cpus)" TARGET=framebuffer HOST="$host" BUILD="$(cc -dumpmachine)" \
                CC="$netsurf_cc" AR="$SDK/bin/zdos-ar" BUILD_CC=cc PREFIX="$prefix" \
                NSLIB_SVGTINY_TARG= NSBUILD_TARG= ZDOS_NATURAL_SCROLL="$natural_scroll" \
                VARIANT=release install
    ) >"$obj/build.log" 2>&1 ||
        die "NetSurf build failed for $arch; see $obj/build.log"

    app="$prefix/bin/netsurf-fb"
    [ -s "$app" ] || die "NetSurf build produced no frontend at $app"
    "$ZDOS_CC" --arch="$arch" --app "$app" "$obj/NETSURF.APP"
    install_app "$obj/NETSURF.APP" APPS_3RD
    dest=$ZIGDOS/build/DATA/NETSURF
    mkdir -p "$dest"
    cp -R "$prefix/share/netsurf/." "$dest/"
done
