#!/bin/bash
# Runs ZDOS for BIOS PCs in QEMU: i440FX, Pentium 4, 4 cores, 1 GB, IDE.
#   ./run-bios-x86.sh [floppy] [QEMU options]
set -e
here=$(cd "$(dirname "$0")" && pwd)

if [ -f "$here/zdos-bios-x86.img" ]; then
    dir=$here
    disk=$here/zdos-bios-x86.img
else
    dir=$here/build/bios-x86
    disk=$dir/system.img
fi
[ -f "$disk" ] || { echo "$disk missing: run zig build x86 first"; exit 1; }

boot=c
if [ "$1" = floppy ]; then
    boot=a
    shift
    [ "$dir" = "$here" ] && { echo "A release has no boot floppy: start from the source folder"; exit 1; }
    [ -f "$dir/floppy.img" ] || { echo "$dir/floppy.img missing: run zig build x86 first"; exit 1; }
fi

other_disks=()
if [ -f "$dir/floppy.img" ]; then
    other_disks+=(-drive "file=$dir/floppy.img,format=raw,if=floppy,index=0")
fi
if [ -f "$dir/data.img" ]; then
    other_disks+=(-drive "file=$dir/data.img,format=raw,if=ide,index=1")
fi

# KVM (Linux) or HVF (macOS), else emulation. ZDOS_ACCEL=tcg|kvm|hvf picks one.
# -accel or -enable-kvm among the arguments wins.
host_cpu() {
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then echo arm64; return; fi # also under Rosetta
    case "$(uname -m)" in
        x86_64 | amd64 | i?86) echo x86 ;;
        arm64 | aarch64) echo arm64 ;;
        *) echo other ;;
    esac
}
pick_accel() { # the guest's CPU family: x86 or arm64
    if [ -n "${ZDOS_ACCEL:-}" ]; then echo "$ZDOS_ACCEL"; return; fi
    if [ "$(host_cpu)" = "$1" ]; then
        if [ "$(uname)" = Darwin ]; then
            [ "$(sysctl -n kern.hv_support 2>/dev/null)" = 1 ] && { echo hvf; return; }
        elif [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            echo kvm; return
        fi
    fi
    echo tcg
}
accel=$(pick_accel x86)
for a in "$@"; do
    case "$a" in -accel | --accel | -enable-kvm | --enable-kvm) accel="" ;; esac
done
accel_args=()
[ -n "$accel" ] && accel_args=(-accel "$accel")

# QEMU has no Pentium 4: a Pentium III with SSE2 as constructed Pentium 4:
cpu="pentium3,+sse2,vendor=GenuineIntel,family=15,model=2,stepping=9,xlevel=0x80000004,model-id=Intel(R) Pentium(R) 4 CPU 2.80GHz"

if [ "$(uname)" = Darwin ]; then display=cocoa audio=coreaudio; else display=sdl audio=pa; fi

exec qemu-system-i386 \
    "${accel_args[@]}" \
    -machine pc -cpu "$cpu" -smp 4 -m 1G \
    -drive "file=$disk,format=raw,if=ide,index=0" \
    "${other_disks[@]}" \
    -boot $boot \
    -vga std -display $display \
    -serial mon:stdio \
    -rtc base=localtime \
    -netdev user,id=net0 -device e1000e,netdev=net0 \
    -audiodev $audio,id=snd -machine pcspk-audiodev=snd \
    -device ac97,audiodev=snd \
    "$@"

# note: soundblaster 16 does not work with display sdl
# and generally not compatible with qemu