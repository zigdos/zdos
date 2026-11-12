#!/bin/bash
# Runs the metal edition for x86-64 in QEMU, the serial console
# on this terminal.
#   ./run-metal-x86_64.sh [QEMU options]
# Quit: close the window, or Ctrl+A then X.
set -e
here=$(cd "$(dirname "$0")" && pwd)

if [ -f "$here/zdos-metal-x86_64.img" ]; then
    dir=$here
    disk=$here/zdos-metal-x86_64.img
else
    dir=$here/build/metal-x86_64
    disk=$dir/system.img
fi
[ -f "$disk" ] || { echo "$disk missing: run zig build x86_64 first"; exit 1; }

code=""
for d in /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/edk2/x64 /usr/share/ovmf; do
    if [ -f "$d/OVMF_CODE.fd" ] && [ -f "$d/OVMF_VARS.fd" ]; then
        code=$d/OVMF_CODE.fd
        vars=$d/OVMF_VARS.fd
        break
    fi
done
brew=$(brew --prefix 2>/dev/null || true)/share/qemu
if [ -z "$code" ] && [ -f "$brew/edk2-x86_64-code.fd" ]; then
    code=$brew/edk2-x86_64-code.fd
    vars=$brew/edk2-i386-vars.fd
fi
if [ -z "$code" ] && [ -f "$here/firmware/OVMF_CODE.fd" ]; then
    code=$here/firmware/OVMF_CODE.fd
    vars=$here/firmware/OVMF_VARS.fd
fi
[ -n "$code" ] || { echo "UEFI firmware for QEMU not found: install edk2-ovmf / ovmf"; exit 1; }
[ -f "$dir/OVMF_VARS.fd" ] || cp "$vars" "$dir/OVMF_VARS.fd"

test_disks=()
if [ -f "$dir/sata.img" ]; then
    test_disks+=(-drive "file=$dir/sata.img,if=none,id=sata0,format=raw" -device ide-hd,drive=sata0,bus=ide.0)
fi
if [ -f "$dir/usb.img" ]; then
    test_disks+=(-drive "file=$dir/usb.img,if=none,id=usb0,format=raw" -device usb-storage,drive=usb0)
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
# Accelerated, the host's CPU (SSSE3, SSE4): -cpu among the arguments wins
cpu=host
for a in "$@"; do
    case "$a" in
        -accel | --accel | -enable-kvm | --enable-kvm) accel="" cpu="" ;;
        -cpu | --cpu) cpu="" ;;
    esac
done
accel_args=()
[ -n "$accel" ] && accel_args=(-accel "$accel")
[ -n "$cpu" ] && [ "$accel" != tcg ] && accel_args+=(-cpu "$cpu")

if [ "$(uname)" = Darwin ]; then display=cocoa audio=coreaudio; else display=sdl audio=pa; fi

exec qemu-system-x86_64 \
    "${accel_args[@]}" \
    -machine q35,i8042=off -smp 4 -m 1G \
    -drive "if=pflash,format=raw,readonly=on,file=$code" \
    -drive "if=pflash,format=raw,file=$dir/OVMF_VARS.fd" \
    -drive "file=$disk,if=none,id=nvme0,format=raw" \
    -device nvme,serial=ZDOS0001,drive=nvme0,bootindex=0 \
    -device qemu-xhci -device usb-kbd -device usb-mouse \
    "${test_disks[@]}" \
    -vga std -display $display \
    -serial mon:stdio \
    -netdev user,id=net0 -device e1000e,netdev=net0,romfile= \
    -audiodev $audio,id=snd -machine pcspk-audiodev=snd \
    -device intel-hda -device hda-duplex,audiodev=snd \
    -rtc base=localtime \
    "$@"
