#!/bin/bash
# Installs ZDOS onto a mounted USB stick or SD card (becomes C:). The
# file systems aren't checked: ZDOS boots from FAT; C: may be FAT, ext2
# or Minix.
#   ./install.sh EDITION BOOT_PARTITION [C_PARTITION]
# Editions: metal-x86_64, metal-rpi4u, uefi-x86_64, uefi-rpi4u.
# C: on a second partition, not FAT: its files are made root's, so
# run it as root.
# In a release folder the edition can be left out.
set -e
here=$(cd "$(dirname "$0")" && pwd)

# A release folder: edition.txt says the edition (older ones: the files do):
release=""
if [ -f "$here/edition.txt" ] && [ -d "$here/files" ]; then
    release=$(tr -d ' \r\n' < "$here/edition.txt")
elif [ -f "$here/files/RPI_EFI.fd" ]; then
    release=uefi-rpi4u
elif [ -f "$here/files/EFI/BOOT/BOOTX64.EFI" ]; then
    release=uefi-x86_64
fi
# Older releases: x86_64 and rpi4u were the UEFI editions:
case "$release" in x86_64 | rpi4u) release=uefi-$release ;; esac

if [ -n "$release" ]; then
    case "$1" in
        "$release") shift ;;
        metal-x86_64 | metal-rpi4u | uefi-x86_64 | uefi-rpi4u) echo "This folder holds the $release edition: ./install.sh <folder where the stick or card is mounted>"; exit 1 ;;
    esac
    edition=$release
else
    case "$1" in
        metal-x86_64 | metal-rpi4u | uefi-x86_64 | uefi-rpi4u) edition=$1; shift ;;
        *) echo "Usage: $0 metal-x86_64|metal-rpi4u|uefi-x86_64|uefi-rpi4u <folder where the stick or card is mounted>"; exit 1 ;;
    esac
fi

# The source folder, and the Pi's firmware beside it, in $ZDOS_PORTS_SRC
# or where earlier builds kept a copy:
if [ -z "$release" ]; then
    case $edition in
        metal-x86_64) build=build/metal-x86_64 boot=BOOTX64.EFI step=x86_64 ;;
        metal-rpi4u) build=build/metal-arm64 boot=BOOTAA64.EFI step=arm64 ;;
        uefi-x86_64) build=build/uefi-x86_64 boot=BOOTX64.EFI step=uefi-x86_64 ;;
        uefi-rpi4u) build=build/uefi-arm64 boot=BOOTAA64.EFI step=uefi-arm64 ;;
    esac
    [ -f "$here/$build/$boot" ] || { echo "$build/$boot missing: run zig build $step (or ./build.sh $step) first"; exit 1; }
    firmware=""
    if [ "${edition%rpi4u}" != "$edition" ]; then
        for d in "$here/../RPi4_UEFI_Firmware" "$ZDOS_PORTS_SRC/RPi4_UEFI_Firmware" "$here/build/rpi4u-arm64"; do
            if [ -f "$d/RPI_EFI.fd" ]; then
                firmware=$d
                break
            fi
        done
        [ -n "$firmware" ] || { echo "The Raspberry Pi 4 UEFI firmware (RPI_EFI.fd) not found in ../RPi4_UEFI_Firmware"; exit 1; }
    fi
fi

DEST=${1%/}
[ -n "$DEST" ] || { echo "Usage: $0 $edition <folder where the stick or card is mounted> [<folder of drive C:>]"; exit 1; }
[ -d "$DEST" ] || { echo "$DEST is not a folder"; exit 1; }
DEST=$(cd "$DEST" && pwd)
SYSTEM=$DEST
if [ -n "$2" ]; then
    [ -d "$2" ] || { echo "$2 is not a folder"; exit 1; }
    SYSTEM=$(cd "${2%/}" && pwd)
fi
# Not this computer's own ESP: its BOOTX64.EFI is the firmware's
# fallback loader.
if [ "$(uname)" != Darwin ]; then
    case "$(findmnt -n -o TARGET --target "$DEST")" in
        /boot | /boot/efi | /efi) echo "$DEST is this computer's EFI System Partition, not a stick or card"; exit 1 ;;
    esac
fi

# A C: other than FAT (ext2, Minix): its files root's
unix_c=""
if [ "$SYSTEM" != "$DEST" ] && [ "$(uname)" != Darwin ]; then
    case "$(stat -f -c %T "$SYSTEM")" in
        msdos | vfat | fat) ;;
        *) unix_c=yes ;;
    esac
    [ -z "$unix_c" ] || [ "$(id -u)" = 0 ] || { echo "Drive C: not on FAT: run it as root (sudo), its files must be root's"; exit 1; }
fi

# The rest is for the firmware (\EFI, the Pi's files):
system_dirs="APPS GAMES LIBS SYSTEM DATA SCRIPTS TEMP DOCS CONF"
is_system() {
    case " $system_dirs " in *" $1 "*) return 0 ;; esac
    return 1
}

if [ "$SYSTEM" = "$DEST" ]; then echo "Installing to $DEST ..."; else echo "Installing to $DEST, drive C: to $SYSTEM ..."; fi
if [ -n "$release" ]; then
    for f in "$here/files/"*; do
        if is_system "$(basename "$f")"; then cp -R "$f" "$SYSTEM/"; else cp -R "$f" "$DEST/"; fi
    done
else
    # "files": what earlier builds put on the card
    if [ -n "$firmware" ]; then
        for f in "$firmware"/*; do
            case $(basename "$f") in
                Readme.md | files) ;;
                *) cp -R "$f" "$DEST/" ;;
            esac
        done
    fi
    cd "$here"
    source ./build.sh   # put() and fill_system()
    put "$DEST" /EFI/BOOT $build/$boot
    fill_system "$SYSTEM" $build
fi
mkdir -p "$SYSTEM/TEMP" # TEMP= in SYSTEM.CFG; older release folders lack it
if [ -n "$unix_c" ]; then
    for d in $system_dirs; do
        [ -e "$SYSTEM/$d" ] || continue
        chown -R 0:0 "$SYSTEM/$d"
        find "$SYSTEM/$d" -type d -exec chmod 755 {} +
        find "$SYSTEM/$d" -type f -exec chmod 644 {} +
        find "$SYSTEM/$d" -type f \( -iname '*.app' \) -exec chmod 755 {} +
    done
    [ -d "$SYSTEM/TEMP" ] && chmod 1777 "$SYSTEM/TEMP"
fi
sync
echo "Done. Unmount it before taking it out."
boot_file=BOOTX64.EFI
[ "${edition%rpi4u}" = "$edition" ] || boot_file=BOOTAA64.EFI
echo "Optional, in ZDOS: ATTRIB +S \\EFI\\BOOT\\$boot_file (protects it from renaming and moving)"
exit 0
