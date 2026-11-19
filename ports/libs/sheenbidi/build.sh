#!/usr/bin/env bash
# SheenBidi: SHNBIDI.ZDL, FriBidi's functions on it (fribidi_sheen.c),
# their header (fribidi.h) and libsheenbidi.a, the stubs.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: ../SheenBidi (SHEENBIDI_SRC=...), only read.
# Built in build/sheenbidi.
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/libs/sheenbidi
SHEENBIDI_SRC=${SHEENBIDI_SRC:-$SRC_ROOT/SheenBidi}
[ -f "$SHEENBIDI_SRC/Source/SheenBidi.c" ] || die "no SheenBidi sources in $SHEENBIDI_SRC (SHEENBIDI_SRC=...)"
BUILD=$ZIGDOS/build/sheenbidi
mkdir -p "$BUILD"

FUNCS=$BUILD/shnbidi.funcs
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"
# One compile unit: SheenBidi's sources (SB_CONFIG_UNITY) and the
# functions on them. No scratch memory: its pool is thread_local, and a
# library has no thread_local data of its own (malloc instead):
FLAGS="-O2 -DSB_CONFIG_UNITY -DSB_CONFIG_DISABLE_SCRATCH_MEMORY -I$PORT -I$SHEENBIDI_SRC/Headers -I$SHEENBIDI_SRC/Source"

for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== SHNBIDI.ZDL for $arch ==="
    $CC $FLAGS -w -c "$PORT/fribidi_sheen.c" -o "$obj/fribidi_sheen.o"
    $CC $FLAGS -c "$PORT/sheenbidi_zdl.c" -o "$obj/sheenbidi_zdl.o"
    # --gc-sections: of the C library and runtime only what is used:
    $CC "$obj/fribidi_sheen.o" "$obj/sheenbidi_zdl.o" -Wl,--gc-sections -o "$obj/SHNBIDI.ZDL"
    ! readelf -lW "$obj/SHNBIDI.elf" | grep -qw TLS || die "SHNBIDI.ZDL has thread_local data: $obj/SHNBIDI.elf"
    $STUBS SHNBIDI "$FUNCS" "$obj/libsheenbidi.a"
    install_app "$obj/SHNBIDI.ZDL" LIBS_3RD
    install_file "$obj/libsheenbidi.a" "sdk-ports/lib/$arch"
done
# The header (include/sheenbidi):
inc=$ZIGDOS/build/sdk-ports/include/sheenbidi
rm -rf "$inc"
mkdir -p "$inc"
cp "$PORT/fribidi.h" "$inc/"
echo "Copied to build/sdk-ports/include/sheenbidi"
