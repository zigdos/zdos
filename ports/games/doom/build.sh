#!/usr/bin/env bash
# Doom (doomgeneric): DOOM.APP with sound (music by MIDI.ZDL), and
# Freedoom's freedoom2.wad into C:\DATA\DOOM (FREEDOOM=...).
# doomgeneric's sources (DOOMGENERIC=...) are only read; the app is
# built in build/doom.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
DOOMGENERIC=${DOOMGENERIC:-$SRC_ROOT/doomgeneric}
FREEDOOM=${FREEDOOM:-$SRC_ROOT/freedoom}
[ -f "$DOOMGENERIC/doomgeneric/Makefile" ] || die "no doomgeneric in $DOOMGENERIC (DOOMGENERIC=...)"
[ -f "$FREEDOOM/freedoom2.wad" ] || die "no freedoom2.wad in $FREEDOOM (FREEDOOM=...)"

# As doomgeneric's Makefile lists them, with the ZDOS platform file;
# the sound's (FEATURE_SOUND) and mus2mid.c for the music:
SOURCES="$ZIGDOS/ports/games/doom/sound_zdos.c $DOOMGENERIC/doomgeneric/mus2mid.c"
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
# Sound, without SDL_mixer (include/SDL_mixer.h is empty):
CFLAGS="$CFLAGS -DFEATURE_SOUND -I$ZIGDOS/ports/games/doom/include"
# The version, from config.h's PACKAGE_VERSION (0.1):
ver=$(sed -n 's/^#define PACKAGE_VERSION \([0-9][0-9.]*\).*/\1/p' "$DOOMGENERIC/doomgeneric/config.h")
[ -n "$ver" ] || die "no version in $DOOMGENERIC/doomgeneric/config.h"
IFS=. read -r v1 v2 v3 _ <<EOF
$ver
EOF
CFLAGS="$CFLAGS -DZDOS_DOOM_MAJOR=$((10#$v1)) -DZDOS_DOOM_MINOR=$((10#${v2:-0})) -DZDOS_DOOM_PATCH=$((10#${v3:-0}))"

obj=$ZIGDOS/build/doom
mkdir -p "$obj"
for arch in $(arches "$@"); do
    select_arch "$arch"
    need_port media/midi libMIDI.a MIDI.ZDL
    echo "=== DOOM.APP for $arch ==="
    $CC $CFLAGS -o "$obj/doom-$arch.app" $SOURCES -lMIDI
    install_app "$obj/doom-$arch.app" GAMES DOOM.APP
done

# The data, the same for every edition:
install_file "$FREEDOOM/freedoom2.wad" DATA/DOOM
