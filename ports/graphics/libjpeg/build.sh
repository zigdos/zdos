#!/usr/bin/env bash
# libjpeg (IJG's): libjpeg.a and its headers in sdk-ports (-ljpeg).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../libjpeg (LIBJPEG_SRC=...), unchanged; jconfig.h is ours.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/graphics/libjpeg
LIBJPEG_SRC=${LIBJPEG_SRC:-$SRC_ROOT/libjpeg}
[ -f "$LIBJPEG_SRC/jpeglib.h" ] || die "no libjpeg sources in $LIBJPEG_SRC (LIBJPEG_SRC=...)"
BUILD=$ZIGDOS/build/libjpeg
# Makefile.am's LIBSOURCES; jmemnobs: images are decoded in memory:
SRCS="jaricom jcapimin jcapistd jcarith jccoefct jccolor jcdctmgr jchuff jcinit jcmainct jcmarker
    jcmaster jcomapi jcparam jcprepct jcsample jctrans jdapimin jdapistd jdarith jdatadst jdatasrc
    jdcoefct jdcolor jddctmgr jdhuff jdinput jdmainct jdmarker jdmaster jdmerge jdpostct jdsample
    jdtrans jerror jfdctflt jfdctfst jfdctint jidctflt jidctfst jidctint jquant1 jquant2 jutils
    jmemmgr jmemnobs"
FLAGS="-O2 -I$PORT -I$LIBJPEG_SRC"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== libjpeg.a for $arch ==="
    for f in $SRCS; do
        $CC $FLAGS -c "$LIBJPEG_SRC/$f.c" -o "$obj/$f.o"
    done
    rm -f "$obj/libjpeg.a"
    zig ar rcs "$obj/libjpeg.a" $(for f in $SRCS; do echo "$obj/$f.o"; done)
    install_file "$obj/libjpeg.a" "sdk-ports/lib/$arch"
done
for h in "$LIBJPEG_SRC/jpeglib.h" "$LIBJPEG_SRC/jmorecfg.h" "$LIBJPEG_SRC/jerror.h" "$PORT/jconfig.h"; do
    install_file "$h" sdk-ports/include
done
