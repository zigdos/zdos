#!/usr/bin/env bash
# DGen/SDL (Sega Genesis emulator): DGEN.APP. A copy of DGen's sources
# (DGEN_SRC=...) in build/dgen/tree gets dgen-zdos.patch and config.h,
# on ZDOS's partial SDL 1.2. Host cc generates Musashi's tables.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/games/dgen
DGEN_SRC=${DGEN_SRC:-$SRC_ROOT/dgen}
BUILD=${DGEN_BUILD:-$ZIGDOS/build/dgen}
TREE=$BUILD/tree
HOSTCC=${HOSTCC:-cc}
[ -f "$DGEN_SRC/md.cpp" ] || die "no DGen in $DGEN_SRC (DGEN_SRC=...)"

# DGen's sources (times kept), patched files fresh when changed:
PATCHED="system.h system.c rc-vars.h rc.cpp main.cpp md.cpp sdl/sdl.cpp vdp.cpp"
mkdir -p "$TREE"
excludes=()
for f in $PATCHED; do excludes+=(--exclude="/$f"); done
(cd "$DGEN_SRC" && rsync -a "${excludes[@]}" ./ "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$DGEN_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/dgen-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$DGEN_SRC/$f" "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/dgen-zdos.patch" || die "dgen-zdos.patch doesn't apply to $DGEN_SRC"
fi
cmp -s "$PORT/config.h" "$TREE/config.h" || cp -p "$PORT/config.h" "$TREE/config.h"

# What make would generate on the host: Musashi's opcode handlers and
# the message bar's fonts:
host=$BUILD/host
mkdir -p "$host"
if [ ! -f "$TREE/musa/m68kops.c" ] || [ "$TREE/musa/m68k_in.c" -nt "$TREE/musa/m68kops.c" ]; then
    $HOSTCC -O2 -w -o "$host/m68kmake" "$TREE/musa/m68kmake.c"
    (cd "$TREE/musa" && "$host/m68kmake" . m68k_in.c >/dev/null)
fi
for font in dgenfont_16x26 dgenfont_8x13 dgenfont_7x5; do
    if [ ! -f "$TREE/sdl/$font.cpp" ] || [ "$TREE/sdl/$font.pbm" -nt "$TREE/sdl/$font.cpp" ]; then
        [ -x "$host/pbm2df" ] || $HOSTCC -O2 -w -o "$host/pbm2df" "$TREE/sdl/pbm2df.c"
        "$host/pbm2df" "$TREE/sdl/$font.pbm" "$TREE/sdl/$font.cpp"
    fi
done

# Makefile.am's sources for this configuration:
SOURCES="rc.cpp romload.c md.cpp mdfr.cpp decode.c vdp.cpp save.cpp graph.cpp fm.c myfm.cpp sn76496.c ras.cpp
    main.cpp mem.cpp ckvp.c joystick.cpp system.c cz80/cz80.c
    musa/m68kcpu.c musa/m68kdasm.c musa/m68kops.c
    scale2x/scale2x.c scale2x/scale3x.c scale2x/scalebit.c
    sdl/font.cpp sdl/sdl.cpp sdl/prompt.c sdl/dgenfont_16x26.cpp sdl/dgenfont_8x13.cpp sdl/dgenfont_7x5.cpp"
INCLUDES="-I$TREE -I$TREE/sdl -I$TREE/cz80 -I$TREE/scale2x -I$ZIGDOS/build/sdk-ports/include/SDL"
DEFS="-include $TREE/config.h"
# -w: upstream's own warnings (old C++, unused results):
CFLAGS="-O2 -w"

for arch in $(arches "$@"); do
    select_arch "$arch"
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL.a" ] || "$ZIGDOS/ports/graphics/sdl12/build.sh" "$arch"
    obj=$BUILD/$arch
    echo "=== DGEN.APP for $arch ==="
    objs=()
    pids=()
    for s in $SOURCES; do
        o=$obj/${s%.*}.o
        objs+=("$o")
        [ "$o" -nt "$TREE/$s" ] && [ "$o" -nt "$TREE/config.h" ] && [ "$o" -nt "$PORT/dgen-zdos.patch" ] && continue
        mkdir -p "$(dirname "$o")"
        case $s in
            *.cpp) $CC $CFLAGS -std=gnu++98 $DEFS $INCLUDES -c "$TREE/$s" -o "$o" & ;;
            *) $CC $CFLAGS -std=gnu99 $DEFS $INCLUDES -c "$TREE/$s" -o "$o" & ;;
        esac
        pids+=($!)
        if [ ${#pids[@]} -ge "$(cpus)" ]; then
            for p in "${pids[@]}"; do wait "$p" || die "compiling failed"; done
            pids=()
        fi
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compiling failed"; done
    ${CC/zdos-cc/zdos-c++} "${objs[@]}" -lSDL -o "$obj/dgen.app"
    install_app "$obj/dgen.app" GAMES DGEN.APP
done
