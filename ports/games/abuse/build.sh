#!/usr/bin/env bash
# Abuse 0.8 (side-scrolling action game): ABUSE.APP and its data
# (C:\DATA\ABUSE), on ZDOS's partial SDL 1.2. A copy of Abuse's
# sources (ABUSE_SRC=...) in build/abuse/tree gets abuse-zdos.patch,
# config.h and sound-zdos.cpp (no SDL_mixer: music by MIDI.ZDL).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/games/abuse
ABUSE_SRC=${ABUSE_SRC:-$SRC_ROOT/abuse}
BUILD=${ABUSE_BUILD:-$ZIGDOS/build/abuse}
TREE=$BUILD/tree
[ -f "$ABUSE_SRC/src/game.cpp" ] || die "no Abuse in $ABUSE_SRC (ABUSE_SRC=...)"

# Abuse's sources (times kept), patched files fresh when changed:
PATCHED=$(sed -n 's|^+++ b/||p' "$PORT/abuse-zdos.patch")
mkdir -p "$TREE"
excludes=()
for f in $PATCHED; do excludes+=(--exclude="/$f"); done
(cd "$ABUSE_SRC" && rsync -a --exclude=/data "${excludes[@]}" ./ "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$ABUSE_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/abuse-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$ABUSE_SRC/$f" "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/abuse-zdos.patch" || die "abuse-zdos.patch doesn't apply to $ABUSE_SRC"
fi
for f in config.h zdos-abuse.cpp sound-zdos.cpp; do
    cmp -s "$PORT/$f" "$TREE/src/$f" || cp -p "$PORT/$f" "$TREE/src/$f"
done

# The version, from configure.ac's AC_INIT:
ver=$(sed -n 's/^AC_INIT(abuse, *\([0-9][0-9.]*\)).*/\1/p' "$ABUSE_SRC/configure.ac")
[ -n "$ver" ] || die "no version in $ABUSE_SRC/configure.ac"
IFS=. read -r v1 v2 v3 _ <<EOF
$ver
EOF
printf '#define PACKAGE_VERSION "%s"\n#define ABUSE_VERSION_MAJOR %d\n#define ABUSE_VERSION_MINOR %d\n#define ABUSE_VERSION_PATCH %d\n' \
    "$ver" "$v1" "${v2:-0}" "${v3:-0}" >"$BUILD/version.h"
cmp -s "$BUILD/version.h" "$TREE/src/version.h" || cp "$BUILD/version.h" "$TREE/src/version.h"

# src/Makefile.am's abuse and its libraries; sound-zdos.cpp instead
# of sdlport/sound.cpp, no abuse-tool:
S=src
SOURCES="$S/lol/matrix.cpp $S/lol/timer.cpp
    $(for f in specache netcfg innet chat endgame loadgame profile cop statbar compiled ant sensor demo lcache \
        nfclient clisp gui transp collide property cache particle objects extend console ability items dev chars \
        level smallfnt automap help intsect loader2 seq points fnt6x13 morpher menu director view configuration \
        game light devsel crc gamma; do echo $S/$f.cpp; done)
    $S/ui/volumewindow.cpp
    $(for f in lisp lisp_opt lisp_gc trig; do echo $S/lisp/$f.cpp; done)
    $(for f in video mouse event timing jdir joystick setup hmi; do echo $S/sdlport/$f.cpp; done)
    $(for f in filter image transimage linked input palette include fonts specs supmorph pcxread jrand keys \
        dprint status pmenu scroller filesel tools guistat sprite jwindow video; do echo $S/imlib/$f.cpp; done)
    $(for f in gserver gclient fileman sock tcpip; do echo $S/net/$f.cpp; done)
    $S/sound-zdos.cpp $S/zdos-abuse.cpp"
INCLUDES="-I$TREE/src -I$TREE/src/lisp -I$TREE/src/imlib -I$TREE/src/net -I$TREE/src/sdlport \
    -I$ZIGDOS/build/sdk-ports/include/SDL"
# -w: upstream's own warnings (old C++); C++98 as written, char signed
# as on x86 (ARM64's is unsigned); the Lisp calls methods on NULL
# (nil) and tests "if (this)": -fno-delete-null-pointer-checks keeps
# the test, which clang would drop:
CFLAGS="-O2 -w -std=gnu++98 -fsigned-char -fwrapv -fno-strict-aliasing -fno-delete-null-pointer-checks -DHAVE_CONFIG_H"

for arch in $(arches "$@"); do
    select_arch "$arch"
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL.a" ] || "$ZIGDOS/ports/graphics/sdl12/build.sh" "$arch"
    need_port media/midi libMIDI.a MIDI.ZDL
    obj=$BUILD/$arch
    echo "=== ABUSE.APP for $arch ==="
    objs=()
    pids=()
    for s in $SOURCES; do
        o=$obj/${s#src/}
        o=${o%.*}.o
        objs+=("$o")
        [ "$o" -nt "$TREE/$s" ] && [ "$o" -nt "$TREE/src/config.h" ] && [ "$o" -nt "$TREE/src/version.h" ] &&
            [ "$o" -nt "$PORT/abuse-zdos.patch" ] && [ "$o" -nt "$PORT/build.sh" ] && continue
        mkdir -p "$(dirname "$o")"
        flags=$CFLAGS
        case $s in */zdos-abuse.cpp | */sound-zdos.cpp) flags=${CFLAGS/-w/-Wall -Wextra} ;; esac
        ${CC/zdos-cc/zdos-c++} $flags $INCLUDES -c "$TREE/$s" -o "$o" &
        pids+=($!)
        if [ ${#pids[@]} -ge "$(cpus)" ]; then
            for p in "${pids[@]}"; do wait "$p" || die "compiling failed"; done
            pids=()
        fi
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compiling failed"; done
    ${CC/zdos-cc/zdos-c++} "${objs[@]}" -lSDL -lMIDI -o "$obj/abuse.app"
    other=$(readelf -r --wide "$obj/abuse.elf" | awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort -u)
    [ -z "$other" ] || die "abuse.app has non-relative relocations: $other"
    install_app "$obj/abuse.app" GAMES ABUSE.APP
done

# The game's data (C:\DATA\ABUSE), the files that changed:
DATA=$ZIGDOS/build/DATA/ABUSE
(cd "$ABUSE_SRC/data" && rsync -a --exclude='Makefile*' ./ "$DATA/")
# The network game's files: the Lisp looked in config/ (not
# shipped), the C++ writes them into addon/deathmat/:
sed -i 's|"config/|"addon/deathmat/|g' "$DATA/addon/deathmat/dstartup.lsp" "$DATA/lisp/startup.lsp" "$DATA/lisp/people.lsp"
echo "Data in build/DATA/ABUSE"
