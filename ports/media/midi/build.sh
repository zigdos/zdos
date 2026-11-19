#!/usr/bin/env bash
# MIDI: MIDI.ZDL (General MIDI on FM or a SoundFont), midi.h,
# libMIDI.a (stubs), and C:\DATA\MIDI\GM.SF2 from FluidR3_GM.sf2.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources, only read: TinySoundFont (TSF_SRC=...), Nuked-OPL3
# (OPL3_SRC=...), GENMIDI out of Freedoom's freedoom2.wad
# (FREEDOOM=...), FluidR3_GM.sf2 (SF2_SRC=...) made a SoundFont
# of at most MIDI_SF2_MB megabytes (8), stereo (MIDI_SF2_MONO=1:
# mono).
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/media/midi
TSF_SRC=${TSF_SRC:-$SRC_ROOT/TinySoundFont}
OPL3_SRC=${OPL3_SRC:-$SRC_ROOT/Nuked-OPL3}
FREEDOOM=${FREEDOOM:-$SRC_ROOT/freedoom}
SF2_SRC=${SF2_SRC:-/usr/share/soundfonts/FluidR3_GM.sf2}
MIDI_SF2_MB=${MIDI_SF2_MB:-8}
MIDI_SF2_MONO=${MIDI_SF2_MONO:-}
BUILD=$ZIGDOS/build/midi
[ -f "$TSF_SRC/tsf.h" ] && [ -f "$TSF_SRC/tml.h" ] || die "no TinySoundFont in $TSF_SRC (TSF_SRC=...)"
[ -f "$OPL3_SRC/opl3.c" ] || die "no Nuked-OPL3 in $OPL3_SRC (OPL3_SRC=...)"
WAD=$FREEDOOM/freedoom2.wad
[ -f "$WAD" ] || die "no freedoom2.wad in $FREEDOOM (FREEDOOM=...)"
mkdir -p "$BUILD"

# GENMIDI: the lump found in the WAD's directory (each entry offset,
# size and an 8-byte name), as a C array:
read -r lumps dir <<EOF2
$(od -An -t u4 -j 4 -N 8 "$WAD")
EOF2
read -r at size <<EOF2
$(od -An -v -t u1 -j "$dir" -N $((lumps * 16)) "$WAD" | tr -s ' \n' '\n\n' | grep . | awk '
    { b[n++ % 16] = $1 }
    n % 16 == 0 {
        name = ""
        for (i = 8; i < 16 && b[i] != 0; i++) name = name sprintf("%c", b[i])
        if (name == "GENMIDI") {
            print b[0] + 256 * (b[1] + 256 * (b[2] + 256 * b[3])), b[4] + 256 * (b[5] + 256 * (b[6] + 256 * b[7]))
            exit
        }
    }')
EOF2
[ -n "${size:-}" ] || die "no GENMIDI lump in $WAD"
dd if="$WAD" of="$BUILD/genmidi.lmp" bs=1 skip="$at" count="$size" 2>/dev/null
[ "$(head -c 8 "$BUILD/genmidi.lmp")" = "#OPL_II#" ] && [ "$size" -ge $((8 + 175 * 36)) ] ||
    die "$WAD: GENMIDI is not an OPL bank"
od -An -v -t u1 "$BUILD/genmidi.lmp" | awk '
    BEGIN { print "/* Freedoom'"'"'s GENMIDI lump, made by build.sh */"; print "static const unsigned char genmidi_lump[] = {" }
    NF { s = "   "; for (i = 1; i <= NF; i++) s = s " " $i ","; print s }
    END { print "};" }' >"$BUILD/genmidi.h.new"
cmp -s "$BUILD/genmidi.h.new" "$BUILD/genmidi.h" || mv "$BUILD/genmidi.h.new" "$BUILD/genmidi.h"
rm -f "$BUILD/genmidi.h.new"

# The version, from tsf.h's first line ("TinySoundFont - v0.9"):
read -r vmaj vmin <<EOF2
$(sed -n '1s/.*TinySoundFont - v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p' "$TSF_SRC/tsf.h")
EOF2
[ -n "${vmin:-}" ] || die "no version in $TSF_SRC/tsf.h"
FLAGS="-O2 -I$PORT -I$BUILD -I$TSF_SRC -I$OPL3_SRC -DTSF_VERSION_MAJOR=$vmaj -DTSF_VERSION_MINOR=$vmin"

# MIDI.ZDL
for arch in $(arches "$@"); do
    select_arch "$arch"
    obj=$BUILD/$arch
    mkdir -p "$obj"
    echo "=== MIDI.ZDL for $arch ==="
    $CC $FLAGS -w -c "$OPL3_SRC/opl3.c" -o "$obj/opl3.o"
    $CC $FLAGS -Wall -c "$PORT/fm.c" -o "$obj/fm.o"
    $CC $FLAGS -Wall -Wno-unused-function -c "$PORT/midi.c" -o "$obj/midi.o"
    (cd "$obj" && $CC midi.o fm.o opl3.o -lm -Wl,--gc-sections -o MIDI.ZDL)
    readelf -h "$obj/MIDI.elf" | grep -q 'Type:.*DYN' || die "MIDI.ZDL is not position independent"
    other=$(readelf -r --wide "$obj/MIDI.elf" | awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort -u)
    [ -z "$other" ] || die "MIDI.ZDL has non-relative relocations: $other"
    $STUBS MIDI "$PORT/exports.def" "$obj/libMIDI.a"
    install_app "$obj/MIDI.ZDL" LIBS_3RD
    install_file "$obj/libMIDI.a" "sdk-ports/lib/$arch"
done
install_file "$PORT/midi.h" sdk-ports/include

# GM.SF2, made again when the script, the source or the size change:
SF2=$BUILD/GM.SF2
if [ ! -f "$SF2_SRC" ]; then
    echo "No $SF2_SRC (SF2_SRC=...): no GM.SF2, MIDI.ZDL plays FM only" >&2
else
    if [ ! -f "$SF2" ] || [ "$PORT/sf2reduce.py" -nt "$SF2" ] || [ "$SF2_SRC" -nt "$SF2" ] ||
        [ "$(cat "$BUILD/GM.size" 2>/dev/null)" != "$MIDI_SF2_MB${MIDI_SF2_MONO:+ mono}" ]; then
        echo "=== GM.SF2 (about $MIDI_SF2_MB MB${MIDI_SF2_MONO:+, mono}) ==="
        stereo=--stereo
        [ -n "$MIDI_SF2_MONO" ] && stereo=
        python3 "$PORT/sf2reduce.py" "$SF2_SRC" "$SF2" --size "$MIDI_SF2_MB" $stereo || die "sf2reduce.py failed"
        echo "$MIDI_SF2_MB${MIDI_SF2_MONO:+ mono}" >"$BUILD/GM.size"
    fi
    install_file "$SF2" DATA/MIDI
fi
