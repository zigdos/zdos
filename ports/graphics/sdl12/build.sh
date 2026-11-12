#!/usr/bin/env bash
# ZDOS's own partial SDL 1.2 on zdos_media.h: libSDL.a, an empty
# libSDLmain.a, headers and sdl-config in sdk-ports (-lSDL).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/graphics/sdl12
BUILD=${SDL12_BUILD:-$ZIGDOS/build/sdl12}
SOURCES="SDL_zdos SDL_zdosvideo SDL_zdosevents SDL_zdosaudio"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    echo "=== libSDL.a (SDL 1.2) for $arch ==="
    mkdir -p "$obj"
    for s in $SOURCES; do
        src=$PORT/src/$s.c
        newer=
        [ -f "$obj/$s.o" ] && newer=$(find "$PORT/include/SDL" "$PORT/src/sdl12_internal.h" -newer "$obj/$s.o" | head -1)
        if [ ! "$obj/$s.o" -nt "$src" ] || [ -n "$newer" ]; then
            $CC -O2 -Wall -Wextra -I"$PORT/include/SDL" -c "$src" -o "$obj/$s.o"
        fi
    done
    rm -f "$obj/libSDL.a" "$obj/libSDLmain.a"
    zig ar rcs "$obj/libSDL.a" "$obj"/*.o
    zig ar rcs "$obj/libSDLmain.a"
    for lib in libSDL.a libSDLmain.a; do install_file "$obj/$lib" "sdk-ports/lib/$arch"; done
done

# As SDL 1.2 installs them (include/SDL/SDL.h ...); sdl-config:
INC=$ZIGDOS/build/sdk-ports/include/SDL
mkdir -p "$INC"
for h in "$PORT"/include/SDL/*.h; do
    cmp -s "$h" "$INC/$(basename "$h")" || cp -p "$h" "$INC/"
done
mkdir -p "$ZIGDOS/build/sdk-ports/bin"
cp "$PORT/sdl-config" "$ZIGDOS/build/sdk-ports/bin/sdl-config"
chmod +x "$ZIGDOS/build/sdk-ports/bin/sdl-config"
echo "Headers in build/sdk-ports/include/SDL, sdl-config in build/sdk-ports/bin"
