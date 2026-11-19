#!/usr/bin/env bash
# DOSBox 0.74-3: DOSBOX.APP. A copy of DOSBox's sources (DOSBOX_SRC=...)
# in build/dosbox/tree gets dosbox-zdos.patch and config.h, on ZDOS's
# partial SDL 1.2.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/games/dosbox
DOSBOX_SRC=${DOSBOX_SRC:-$SRC_ROOT/dosbox}
BUILD=${DOSBOX_BUILD:-$ZIGDOS/build/dosbox}
TREE=$BUILD/tree
[ -f "$DOSBOX_SRC/src/dosbox.cpp" ] || die "no DOSBox in $DOSBOX_SRC (DOSBOX_SRC=...)"

# DOSBox's sources (times kept), patched files fresh when changed:
PATCHED=$(sed -n 's|^+++ b/||p' "$PORT/dosbox-zdos.patch")
mkdir -p "$TREE"
excludes=()
for f in $PATCHED; do excludes+=(--exclude="/$f"); done
(cd "$DOSBOX_SRC" && rsync -a "${excludes[@]}" ./ "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$DOSBOX_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/dosbox-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$DOSBOX_SRC/$f" "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/dosbox-zdos.patch" || die "dosbox-zdos.patch doesn't apply to $DOSBOX_SRC"
fi
# dosbox.h includes it:
cmp -s "$PORT/config.h" "$TREE/include/config.h" || cp -p "$PORT/config.h" "$TREE/include/config.h"
# midi.cpp includes it (the patch):
cmp -s "$PORT/midi_zdos.h" "$TREE/src/gui/midi_zdos.h" || cp -p "$PORT/midi_zdos.h" "$TREE/src/gui/midi_zdos.h"
# The version, from configure.ac's AC_INIT (0.74-3: 0.74.3):
ver=$(sed -n 's/^AC_INIT(dosbox, *\([0-9][0-9.-]*\)).*/\1/p' "$DOSBOX_SRC/configure.ac")
[ -n "$ver" ] || die "no version in $DOSBOX_SRC/configure.ac"
IFS=.- read -r v1 v2 v3 _ <<EOF
$ver
EOF
printf '#define VERSION "%s"\n#define DOSBOX_VERSION_MAJOR %d\n#define DOSBOX_VERSION_MINOR %d\n#define DOSBOX_VERSION_PATCH %d\n' \
    "$ver" "$((10#$v1))" "$((10#${v2:-0}))" "$((10#${v3:-0}))" >"$BUILD/version-zdos.h"
cmp -s "$BUILD/version-zdos.h" "$TREE/include/version-zdos.h" || cp "$BUILD/version-zdos.h" "$TREE/include/version-zdos.h"

# Makefile.am's sources (what isn't configured compiles to nothing):
S=src
SOURCES="$S/dosbox.cpp
    $(for f in callback cpu flags modrm core_full paging core_normal core_simple core_prefetch core_dyn_x86 core_dynrec; do echo $S/cpu/$f.cpp; done)
    $(for f in debug debug_gui debug_disasm debug_win32; do echo $S/debug/$f.cpp; done)
    $(for f in dos dos_devices dos_execute dos_files dos_ioctl dos_memory dos_misc dos_classes dos_programs dos_tables \
        drives drive_virtual drive_local drive_cache drive_fat drive_iso dos_mscdex dos_keyboard_layout \
        cdrom cdrom_ioctl_win32 cdrom_aspi_win32 cdrom_ioctl_linux cdrom_image cdrom_ioctl_os2; do echo $S/dos/$f.cpp; done)
    $S/fpu/fpu.cpp
    $(for f in sdlmain sdl_mapper render render_scalers midi sdl_gui; do echo $S/gui/$f.cpp; done)
    $(for f in adlib dma gameblaster hardware iohandler joystick keyboard memory mixer pcspeaker pic sblaster tandy_sound \
        timer vga vga_attr vga_crtc vga_dac vga_draw vga_gfx vga_other vga_memory vga_misc vga_seq vga_xga vga_s3 \
        vga_tseng vga_paradise cmos disney gus mpu401 ipx ipxserver dbopl; do echo $S/hardware/$f.cpp; done)
    $S/hardware/mame/saa1099.cpp $S/hardware/mame/sn76496.cpp
    $(for f in directserial libserial serialdummy serialport softmodem misc_util nullmodem; do echo $S/hardware/serialport/$f.cpp; done)
    $(for f in mouse xms ems int10 int10_char int10_memory int10_misc int10_modes int10_vesa int10_pal int10_put_pixel \
        int10_video_state int10_vptable bios bios_disk bios_keyboard; do echo $S/ints/$f.cpp; done)
    $(for f in cross messages programs setup support; do echo $S/misc/$f.cpp; done)
    $(for f in shell shell_batch shell_cmds shell_misc; do echo $S/shell/$f.cpp; done)
    $S/libs/gui_tk/gui_tk.cpp"
INCLUDES="-I$TREE/include -I$ZIGDOS/build/sdk-ports/include/SDL"
# -w: upstream's own warnings (old C++); C++03 as written:
CFLAGS="-O2 -w -std=gnu++98 -fno-strict-aliasing"

for arch in $(arches "$@"); do
    select_arch "$arch"
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL.a" ] || "$ZIGDOS/ports/graphics/sdl12/build.sh" "$arch"
    need_port media/midi libMIDI.a MIDI.ZDL
    obj=$BUILD/$arch
    echo "=== DOSBOX.APP for $arch ==="
    objs=()
    pids=()
    for s in $SOURCES; do
        o=$obj/${s#src/}
        o=${o%.*}.o
        objs+=("$o")
        [ "$o" -nt "$TREE/$s" ] && [ "$o" -nt "$TREE/include/config.h" ] && [ "$o" -nt "$TREE/include/version-zdos.h" ] && [ "$o" -nt "$TREE/src/gui/midi_zdos.h" ] && [ "$o" -nt "$PORT/dosbox-zdos.patch" ] && continue
        mkdir -p "$(dirname "$o")"
        ${CC/zdos-cc/zdos-c++} $CFLAGS $INCLUDES -I"$(dirname "$TREE/$s")" -c "$TREE/$s" -o "$o" &
        pids+=($!)
        if [ ${#pids[@]} -ge "$(cpus)" ]; then
            for p in "${pids[@]}"; do wait "$p" || die "compiling failed"; done
            pids=()
        fi
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compiling failed"; done
    ${CC/zdos-cc/zdos-c++} "${objs[@]}" -lSDL -lMIDI -o "$obj/dosbox.app"
    install_app "$obj/dosbox.app" GAMES DOSBOX.APP
done
