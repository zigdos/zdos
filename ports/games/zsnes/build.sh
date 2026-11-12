#!/usr/bin/env bash
# ZSNES 2: ZSNES.APP. A COPY OF ZSNES'S SOURCES (ZSNES_SRC=...) IN
# build/zsnes/tree gets zsnes-zdos.patch and config.h, on SDL 2 through
# SDL3/SDL.h here; parsegen.py (python3) makes the .psr tables. x86
# (BIOS) builds unix/sw_draw_vga.c instead of unix/sw_draw.c: the latter
# with zsnes-zdos-vga.patch (VGA mode 13h).
#   build.sh [x86|x86_64|arm64]...   (none: all three)
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/games/zsnes
ZSNES_SRC=${ZSNES_SRC:-$SRC_ROOT/zsnes}
BUILD=${ZSNES_BUILD:-$ZIGDOS/build/zsnes}
TREE=$BUILD/tree
PYTHON=${PYTHON:-python3}
[ -f "$ZSNES_SRC/cpu/c_65816d.c" ] || die "no ZSNES in $ZSNES_SRC (ZSNES_SRC=...)"

# ZSNES's sources (times kept), patched files fresh when changed:
PATCHED=$(sed -n 's|^+++ b/||p' "$PORT/zsnes-zdos.patch" | sed 's/[[:space:]].*//')
mkdir -p "$TREE"
excludes=(--exclude=/.git --exclude=/server --exclude=/win --exclude=/macos)
for f in $PATCHED; do excludes+=(--exclude="/$f"); done
(cd "$ZSNES_SRC" && rsync -a "${excludes[@]}" ./ "$TREE/")
stale=0
for f in $PATCHED; do
    if [ ! -f "$TREE/$f" ] || [ "$ZSNES_SRC/$f" -nt "$TREE/$f" ] || [ "$PORT/zsnes-zdos.patch" -nt "$TREE/$f" ]; then stale=1; fi
done
if [ $stale = 1 ]; then
    for f in $PATCHED; do cp "$ZSNES_SRC/$f" "$TREE/$f"; done
    patch -s -d "$TREE" -p1 <"$PORT/zsnes-zdos.patch" || die "zsnes-zdos.patch doesn't apply to $ZSNES_SRC"
fi
# BIOS's copy of the software video, next to the original:
VGA=$TREE/unix/sw_draw_vga.c
if [ ! -f "$VGA" ] || [ "$TREE/unix/sw_draw.c" -nt "$VGA" ] || [ "$PORT/zsnes-zdos-vga.patch" -nt "$VGA" ]; then
    patch -s -o "$VGA" "$TREE/unix/sw_draw.c" <"$PORT/zsnes-zdos-vga.patch" ||
        die "zsnes-zdos-vga.patch doesn't apply to unix/sw_draw.c"
fi
cmp -s "$PORT/config.h" "$TREE/config.h" || cp -p "$PORT/config.h" "$TREE/config.h"
mkdir -p "$TREE/SDL3"
sync_files "$PORT/SDL3" "$TREE/SDL3"

# The config file readers and writers, a C file and header for each
# .psr (the same for every CPU):
gen=$TREE/gen
mkdir -p "$gen"
PSRS="cfg input md"
for p in $PSRS; do
    if [ ! -f "$gen/$p.c" ] || [ "$TREE/$p.psr" -nt "$gen/$p.c" ] || [ "$TREE/parsegen.py" -nt "$gen/$p.c" ]; then
        (cd "$TREE" && "$PYTHON" ./parsegen.py -D__UNIXSDL__ -DNO_PNG -DNO_DEBUGGER \
            -cheader "gen/$p.h" -fname "$p" "gen/$p.c" "$p.psr") || die "parsegen.py failed for $p.psr"
    fi
done

# The Makefile's sources for __UNIXSDL__ without OpenGL and debugger:
SOURCES="c_init.c c_vcache.c chips/7110emu.c chips/7110proc.c chips/msu1emu.c chips/msu1regs.c chips/c4emu.c
    chips/c4proc.c chips/c_dsp2proc.c chips/c_sa1regs.c chips/c_sfxproc.c chips/c_fxdata.c chips/c_fxops.c
    chips/c_fxtable.c chips/dsp1emu.c chips/dsp1proc.c chips/dsp2proc.c chips/dsp3emu.c chips/dsp3proc.c
    chips/dsp4emu.c chips/dsp4proc.c chips/obc1emu.c chips/obc1proc.c chips/sa1emu.c chips/c_sa1proc.c
    chips/c_sa1data.c chips/sa1regs.c chips/sdd1emu.c chips/seta10.c chips/seta11.c chips/sfxproc.c
    chips/st10proc.c chips/st11proc.c
    cpu/c_65816d.c cpu/c_dma.c cpu/c_dsp.c cpu/c_dspproc.c cpu/c_execute.c cpu/c_execloop.c cpu/c_execdata.c
    cpu/c_irq.c cpu/c_memory.c cpu/c_memops.c cpu/c_ops65816.c cpu/c_ops65816_sa1.c cpu/c_ops65816_dbg.c
    cpu/c_sflags.c cpu/c_execirq.c cpu/c_regsdata.c cpu/c_regswdata.c cpu/c_regs.c cpu/c_regsppu.c
    cpu/c_regsw.c cpu/c_rewind.c cpu/c_spc700.c cpu/c_spcdata.c cpu/c_table.c cpu/c_tablec.c cpu/dma.c
    cpu/dspproc.c cpu/firtable.c cpu/executec.c cpu/memtable.c cpu/c_stable.c
    effects/burn.c effects/smoke.c effects/water.c endmem.c
    gui/c_gui.c gui/c_guiwindp.c gui/c_gui_data.c gui/guicheat.c gui/guicombo.c gui/guiarena.c gui/guifuncs.c
    gui/guikeys.c gui/guimisc.c gui/guimouse.c gui/guitools.c gui/menu.c
    net/packet.c net/netplay.c net/znp.c
    initdata.c initc.c mmlib/mm.c patch.c ui.c ver.c
    video/2xsaiw.c video/c_2xsaiw.c video/c_makev16b.c video/c_makevid.c video/tilecache.c video/sprites.c
    video/vcache_data.c video/c_mode716.c video/c_mode716data.c video/c_mode716calc.c video/c_mode716ext2.c
    video/c_mode716start.c video/c_mode716win.c video/c_mode716bw.c video/c_mode716proc.c video/c_procwin.c
    video/c_m716gate.c video/c_mv16draw.c video/c_mv16msgate.c video/c_mode716draw.c video/c_mode716gate.c
    video/c_mv16tms.c video/c_mv16tsms.c video/c_mv16tm7.c video/c_mv16tclr.c video/c_mv16bclr.c
    video/c_mv16tspr.c video/c_mv16tsprt.c video/c_mv16tsprp.c video/c_mv16t8bt.c video/c_mv16t16bt.c
    video/c_mv16t8t.c video/c_mv16t16t.c video/c_mv16t8to.c video/c_mv16thi.c video/c_mv16tline.c
    video/c_ngmosaic.c video/c_ngprocbg.c video/c_ngline.c video/c_ngspr.c video/c_ng2gate.c video/c_ng2tile.c
    video/c_ngbg.c video/c_ngframe.c video/c_ngtransp.c video/c_makev16tdata.c video/c_newgfx16data.c
    video/c_hqx.c video/c_newgfx16.c video/copyvwin.c video/crt.c video/filter.c video/makevid.c
    video/mode716b.c video/newgfx.c video/ntsc.c video/procvid.c video/procvidc.c video/sw_draw.c
    zdir.c zip/zipread.c zip/zpng.c main.c saveload.c zmovie.c zpath.c zstate.c ztimec.c zcompat.c miniz.c
    unix/audio.c unix/battery.c unix/c_sdlintrf.c unix/lib.c unix/safelib.c unix/sdl_render.c unix/sdllink.c
    unix/net_transport.c unix/sw_draw.c mmlib/linux.c
    gen/cfg.c gen/input.c gen/md.c"
INCLUDES="-I$TREE -I$gen -I$ZIGDOS/build/sdk-ports/include/SDL2"
DEFS="-include $TREE/config.h"
# -w: upstream's warnings are for gcc's -W set; no strict aliasing, as
# the assembler-born code reads memory through other types:
CFLAGS="-O2 -w -std=gnu11 -fno-strict-aliasing"

for arch in $(arches "$@"); do
    select_arch "$arch"
    [ -f "$ZIGDOS/build/sdk-ports/lib/$arch/libSDL2.a" ] || "$ZIGDOS/ports/graphics/SDL/build.sh" "$arch"
    obj=$BUILD/$arch
    echo "=== ZSNES.APP for $arch ==="
    objs=()
    pids=()
    for s in $SOURCES; do
        [ "$arch" = x86 ] && [ "$s" = unix/sw_draw.c ] && s=unix/sw_draw_vga.c
        o=$obj/${s%.c}.o
        objs+=("$o")
        [ "$o" -nt "$TREE/$s" ] && [ "$o" -nt "$TREE/config.h" ] && [ "$o" -nt "$PORT/zsnes-zdos.patch" ] &&
            [ "$o" -nt "$TREE/SDL3/SDL.h" ] && continue
        mkdir -p "$(dirname "$o")"
        $CC $CFLAGS $DEFS $INCLUDES -c "$TREE/$s" -o "$o" &
        pids+=($!)
        if [ ${#pids[@]} -ge "$(cpus)" ]; then
            for p in "${pids[@]}"; do wait "$p" || die "compiling failed"; done
            pids=()
        fi
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || die "compiling failed"; done
    $CC "${objs[@]}" -lSDL2 -lm -o "$obj/zsnes.app"
    install_app "$obj/zsnes.app" GAMES ZSNES.APP
done
