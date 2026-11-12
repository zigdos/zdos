#!/usr/bin/env bash
# Doom (doomgeneric): DOOM.APP, and Freedoom's freedoom2.wad into
# C:\DATA\DOOM (FREEDOOM=...). doomgeneric's sources (DOOMGENERIC=...)
# are only read; the app is built in build/doom.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
DOOMGENERIC=${DOOMGENERIC:-$SRC_ROOT/doomgeneric}
FREEDOOM=${FREEDOOM:-$SRC_ROOT/freedoom}
[ -f "$DOOMGENERIC/doomgeneric/Makefile" ] || die "no doomgeneric in $DOOMGENERIC (DOOMGENERIC=...)"
[ -f "$FREEDOOM/freedoom2.wad" ] || die "no freedoom2.wad in $FREEDOOM (FREEDOOM=...)"

# As doomgeneric's Makefile lists them, with the ZDOS platform file:
SOURCES=""
for o in $(sed -n 's/^SRC_DOOM = //p' "$DOOMGENERIC/doomgeneric/Makefile"); do
    if [ "$o" = doomgeneric_xlib.o ]; then
        SOURCES="$SOURCES $ZIGDOS/ports/games/doom/doomgeneric_zdos.c"
    else
        SOURCES="$SOURCES $DOOMGENERIC/doomgeneric/${o%.o}.c"
    fi
done

# 320 x 200 in 256 colors: Doom's own picture, shown as it is:
CFLAGS="-O2 -w -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DNORMALUNIX"
# doomgeneric_zdos.c, outside its tree, includes its headers:
CFLAGS="$CFLAGS -I$DOOMGENERIC/doomgeneric"

obj=$ZIGDOS/build/doom
mkdir -p "$obj"
for arch in $(arches "$@"); do
    select_arch "$arch"
    echo "=== DOOM.APP for $arch ==="
    $CC $CFLAGS -o "$obj/doom-$arch.app" $SOURCES
    install_app "$obj/doom-$arch.app" GAMES DOOM.APP
done

# The data, the same for every edition:
install_file "$FREEDOOM/freedoom2.wad" DATA/DOOM
