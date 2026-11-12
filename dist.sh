#!/bin/bash
# The release zips in dist/, as zig build dist does. Linux only.
#   ./dist.sh [VERSION]   default: src/kernel/version.zig's, as 0.2
# Needs zip, QEMU's UEFI firmware and the Pi 4's (pftf/RPi4) in
# ../RPi4_UEFI_Firmware, $ZDOS_PORTS_SRC or build/rpi4u-arm64.
set -e
cd "$(dirname "$0")"
source ./build.sh   # put() and fill_system()
VERSION=${1:-$(sed -n 's/.*{ *\([0-9]*\), *\([0-9]*\),.*/\1.\2/p' src/kernel/version.zig)}
[ -n "$VERSION" ] || { echo "Usage: $0 [version] (none found in src/kernel/version.zig)"; exit 1; }
mkdir -p dist
rm -rf dist/zdos-$VERSION-*

for edition in uefi-x86_64 bios-x86 uefi-arm64 metal-x86_64 metal-arm64; do
    mkdir -p dist/zdos-$VERSION-$edition
    cp run-$edition.sh dist/zdos-$VERSION-$edition/
    cp build/$edition/system.img dist/zdos-$VERSION-$edition/zdos-$edition.img
done

# QEMU's UEFI firmware from this computer, with its license:
FIRMWARE=dist/zdos-$VERSION-uefi-x86_64/firmware
mkdir -p $FIRMWARE
for d in /usr/share/edk2/ovmf /usr/share/OVMF /usr/share/edk2/x64 /usr/share/ovmf; do
    if [ -f $d/OVMF_CODE.fd ] && [ -f $d/OVMF_VARS.fd ]; then
        cp $d/OVMF_CODE.fd $d/OVMF_VARS.fd $FIRMWARE/
        break
    fi
done
[ -f $FIRMWARE/OVMF_CODE.fd ] || { echo "QEMU's UEFI firmware not found (install edk2-ovmf)"; exit 1; }
for f in /usr/share/licenses/edk2-ovmf/License.txt /usr/share/doc/edk2-ovmf/License.txt /usr/share/doc/ovmf/copyright; do
    if [ -f $f ]; then
        cp $f $FIRMWARE/LICENSE.txt
        break
    fi
done

FIRMWARE=dist/zdos-$VERSION-uefi-arm64/firmware
mkdir -p $FIRMWARE
for f in /usr/share/edk2/aarch64/QEMU_EFI.silent.fd /usr/share/edk2/aarch64/QEMU_EFI.fd \
         /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
    if [ -f $f ]; then
        cp $f $FIRMWARE/QEMU_EFI.fd
        break
    fi
done
[ -f $FIRMWARE/QEMU_EFI.fd ] || { echo "QEMU's ARM64 UEFI firmware not found (install edk2-aarch64)"; exit 1; }
for f in /usr/share/licenses/edk2-aarch64/License.txt /usr/share/doc/edk2-aarch64/License.txt /usr/share/doc/qemu-efi-aarch64/copyright; do
    if [ -f $f ]; then
        cp $f $FIRMWARE/LICENSE.txt
        break
    fi
done

for FIRMWARE in dist/zdos-$VERSION-uefi-x86_64/firmware dist/zdos-$VERSION-uefi-arm64/firmware; do
    [ -f $FIRMWARE/LICENSE.txt ] || cat > $FIRMWARE/LICENSE.txt <<EOF
UEFI firmware for QEMU from the EDK II project (TianoCore),
BSD-2-Clause-Patent license:
https://github.com/tianocore/edk2/blob/master/License.txt
EOF
done

cp -R dist/zdos-$VERSION-uefi-x86_64/firmware dist/zdos-$VERSION-metal-x86_64/
cp -R dist/zdos-$VERSION-uefi-arm64/firmware dist/zdos-$VERSION-metal-arm64/

# For a stick or card: install.sh, edition.txt and drive C: in files/;
# for the Pi also its firmware, without Readme.md:
PI_FIRMWARE=""
for d in ../RPi4_UEFI_Firmware "$ZDOS_PORTS_SRC/RPi4_UEFI_Firmware" build/rpi4u-arm64; do
    if [ -f "$d/RPI_EFI.fd" ]; then
        PI_FIRMWARE=$d
        break
    fi
done
[ -n "$PI_FIRMWARE" ] || { echo "The Raspberry Pi 4 UEFI firmware (RPI_EFI.fd) not found"; exit 1; }
stick() { # stick <name> <build folder> <boot file>
    local dir=dist/zdos-$VERSION-usb-$1
    mkdir -p $dir/files
    cp install.sh $dir/
    echo "$1" > $dir/edition.txt
    if [ "${1%rpi4u}" != "$1" ]; then
        for f in "$PI_FIRMWARE"/*; do
            case $(basename "$f") in
                Readme.md | files) ;;
                *) cp -R "$f" $dir/files/ ;;
            esac
        done
    fi
    put $dir/files /EFI/BOOT build/$2/$3
    fill_system $dir/files build/$2
}
stick uefi-x86_64 uefi-x86_64 BOOTX64.EFI
stick uefi-rpi4u uefi-arm64 BOOTAA64.EFI
stick metal-x86_64 metal-x86_64 BOOTX64.EFI
stick metal-rpi4u metal-arm64 BOOTAA64.EFI

cd dist
for name in uefi-x86_64 bios-x86 uefi-arm64 metal-x86_64 metal-arm64 usb-uefi-x86_64 usb-uefi-rpi4u usb-metal-x86_64 usb-metal-rpi4u; do
    rm -f zdos-$VERSION-$name.zip
    zip -qr zdos-$VERSION-$name.zip zdos-$VERSION-$name
    rm -rf zdos-$VERSION-$name
done
sha256sum zdos-$VERSION-*.zip > SHA256SUMS-$VERSION-ZDOS
echo "Made dist/zdos-$VERSION-*.zip and dist/SHA256SUMS-$VERSION-ZDOS"
