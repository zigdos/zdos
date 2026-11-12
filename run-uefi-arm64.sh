#!/bin/bash
# Runs ZDOS for ARM64 UEFI in QEMU (virt, Cortex-A57, 256 MB, virtio).
#   ./run-uefi-arm64.sh [QEMU options]
set -e
here=$(cd "$(dirname "$0")" && pwd)

if [ -f "$here/zdos-uefi-arm64.img" ]; then
    dir=$here
    disk=$here/zdos-uefi-arm64.img
else
    dir=$here/build/uefi-arm64
    disk=$dir/system.img
fi
[ -f "$disk" ] || { echo "$disk missing: run zig build uefi-arm64 first"; exit 1; }

# pflash keeps the resolution chosen in the firmware setup:
firmware=""
code=""
brew=$(brew --prefix 2>/dev/null || true)/share/qemu
for pair in "/usr/share/edk2/aarch64/QEMU_EFI-silent-pflash.raw /usr/share/edk2/aarch64/vars-template-pflash.raw" \
            "/usr/share/AAVMF/AAVMF_CODE.fd /usr/share/AAVMF/AAVMF_VARS.fd" \
            "$brew/edk2-aarch64-code.fd $brew/edk2-arm-vars.fd"; do
    read -r c v <<< "$pair"
    if [ -f "$c" ] && [ -f "$v" ]; then
        code=$c
        [ -f "$dir/AAVMF_VARS.fd" ] || cp "$v" "$dir/AAVMF_VARS.fd"
        break
    fi
done
if [ -z "$code" ]; then
    for f in /usr/share/edk2/aarch64/QEMU_EFI.silent.fd \
             /usr/share/edk2/aarch64/QEMU_EFI.fd \
             /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
             "$here/firmware/QEMU_EFI.fd"; do
        if [ -f "$f" ]; then
            firmware=$f
            break
        fi
    done
    [ -n "$firmware" ] || { echo "ARM64 UEFI firmware not found: install edk2-aarch64 / qemu-efi-aarch64"; exit 1; }
fi
if [ -n "$code" ]; then
    boot=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$dir/AAVMF_VARS.fd")
else
    boot=(-bios "$firmware")
fi

test_disks=()
if [ -f "$dir/data.img" ]; then
    test_disks+=(-drive "file=$dir/data.img,if=none,id=data,format=raw" -device virtio-blk-pci,drive=data)
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
accel=$(pick_accel arm64)
for a in "$@"; do
    case "$a" in -accel | --accel | -enable-kvm | --enable-kvm) accel="" ;; esac
done
accel_args=()
[ -n "$accel" ] && accel_args=(-accel "$accel")

# Natively the CPU is the host's, and the GIC the host has:
if [ -z "$accel" ] || [ "$accel" = tcg ]; then
    machine=virt cpu=cortex-a57
elif [ "$accel" = kvm ]; then
    machine=virt,gic-version=max cpu=host
else
    machine=virt cpu=host
fi

if [ "$(uname)" = Darwin ]; then display=cocoa audio=coreaudio; else display=sdl audio=pa; fi

exec qemu-system-aarch64 \
    "${accel_args[@]}" \
    -machine $machine -cpu $cpu -smp 4 -m 1G \
    "${boot[@]}" \
    -drive "file=$disk,if=none,id=sys,format=raw" \
    -device virtio-blk-pci,drive=sys,bootindex=0 \
    "${test_disks[@]}" \
    -device virtio-gpu-pci \
    -device qemu-xhci -device usb-kbd -device usb-mouse \
    -display $display \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0,romfile= \
    -audiodev $audio,id=snd \
    -device intel-hda -device hda-duplex,audiodev=snd \
    -rtc base=localtime \
    "$@"
