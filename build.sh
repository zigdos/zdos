#!/bin/bash
# Builds ZDOS with plain commands, as zig build does. Linux only.
#   ./build.sh [EDITION...] [--test-disks]
# Editions: x86_64 (metal), arm64 (metal), uefi-x86_64, uefi-arm64, x86 (BIOS).
# Needs zig 0.14, dosfstools, mtools, util-linux (sfdisk);
# for x86 binutils, for the test disks e2fsprogs.
# install.sh and dist.sh use put() and fill_system() from here.
set -e
shopt -s nullglob    # an empty folder gives no names
LC_COLLATE=C         # names in byte order, as zig build copies them
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p build/DATA
SYS_DISK_SIZE=512

# APPS

# The programs from apps/ and games/ as .APP files
programs() {
    rm -rf $OUT/APPS
    mkdir -p $OUT/APPS $OUT/APPS_3RD $OUT/GAMES

    # ZIG APPS AND GAMES
    for source in apps/*.zig; do
        name=$(basename $source .zig)
        # SYS and FDISK of the BIOS edition embed its boot code:
        deps=""
        modules=""
        if [ $edition = x86 ] && [ $name = sys ]; then
            deps="--dep vbr16.bin --dep vbr32.bin"
            modules="-Mvbr16.bin=$OUT/vbr16.bin -Mvbr32.bin=$OUT/vbr32.bin"
        fi
        if [ $edition = x86 ] && [ $name = fdisk ]; then
            deps="--dep mbr.bin"
            modules="-Mmbr.bin=$OUT/mbr.bin"
        fi
        # Argon2 compiles std.Thread unless single-threaded:
        threads=""
        case $name in login | passwd | adduser | su | sudo | sshd | sshtest) threads="-fsingle-threaded" ;; esac
        zig build-exe $TARGET -O ReleaseSmall -fPIE -fno-unwind-tables -fentry=zdos_entry -T $LD -femit-bin=$OUT/$name.elf $threads \
            --dep abi $deps -Mroot=$source -Mabi=src/kernel/abi.zig $modules
        zig objcopy -O binary $OUT/$name.elf $OUT/APPS/${name^^}.APP
        rm -f $OUT/$name.elf $OUT/$name.elf.o
    done
    for source in apps/*.c; do
        name=$(basename $source .c)
        zig cc $TARGET -Os -ffreestanding -fPIE -fno-stack-protector -fno-asynchronous-unwind-tables -fno-unwind-tables -nostdlib \
            -Wl,-e,zdos_entry -Wl,-T,$LD -o $OUT/$name.elf -Isdk/src $source
        zig objcopy -O binary $OUT/$name.elf $OUT/APPS/${name^^}.APP
        rm -f $OUT/$name.elf
    done
    # C APPS (on the C SDK)
    local arch=${LD##*app-}
    arch=${arch%.ld}
    for source in apps/posix/*.c; do
        name=$(basename $source .c)
        sdk/bin/zdos-cc --arch=$arch -Os -fno-builtin $source -o $OUT/APPS/${name^^}.APP
        rm -f $OUT/APPS/${name^^}.elf
    done
    for source in games/*.zig; do
        name=$(basename $source .zig)
        zig build-exe $TARGET -O ReleaseSmall -fPIE -fno-unwind-tables -fentry=zdos_entry -T $LD -femit-bin=$OUT/$name.elf \
            --dep zdos --dep abi -Mroot=$source --dep abi -Mzdos=apps/zdos/zdos.zig -Mabi=src/kernel/abi.zig
        zig objcopy -O binary $OUT/$name.elf $OUT/GAMES/${name^^}.APP
        rm -f $OUT/$name.elf $OUT/$name.elf.o
    done
    # LIBRARIES (.ZDL) AND DRIVERS (.SYS)
    rm -rf $OUT/LIBS $OUT/DRIVERS
    mkdir -p $OUT/LIBS $OUT/DRIVERS
    for source in libs/*.zig; do
        name=$(basename $source .zig)
        threads=""
        case $name in zcrypt) threads="-fsingle-threaded" ;; esac  # Argon2, as for the password programs
        zig build-exe $TARGET -O ReleaseSmall -fPIE -fno-entry -T ${LD/app-/lib-} -femit-bin=$OUT/$name.elf $threads \
            --dep zdos --dep abi -Mroot=$source --dep abi -Mzdos=apps/zdos/zdos.zig -Mabi=src/kernel/abi.zig
        zig objcopy -O binary $OUT/$name.elf $OUT/LIBS/${name^^}.ZDL
        rm -f $OUT/$name.elf $OUT/$name.elf.o
    done
    for source in sys/*.zig; do
        name=$(basename $source .zig)
        zig build-exe $TARGET -O ReleaseSmall -fPIE -fentry=zdos_driver_init -T ${LD/app-/sys-} -femit-bin=$OUT/$name.elf \
            --dep drv -Mroot=$source -Mdrv=src/kernel/drv.zig
        zig objcopy -O binary $OUT/$name.elf $OUT/DRIVERS/${name^^}.SYS
        rm -f $OUT/$name.elf $OUT/$name.elf.o
    done
}

# DISK HELPERS

# put <drive> <folder> <file or folder>...
# Copies into a folder of a FAT image (mtools) or a folder.
# Into an image in name order: ZDOS lists some folders
# (SYSTEM\KEYB) in the order their files were written.
put() {
    local drive=$1 to=$2 path="" part f
    shift 2
    if [[ $drive == *.img ]]; then
        for part in ${to//\// }; do
            path=$path/$part
            mdir -i $drive ::$path >/dev/null 2>&1 || mmd -i $drive ::$path
        done
        for f in "$@"; do
            if [ -d "$f" ]; then
                put $drive $to/$(basename "$f") "$f"/*
            else
                mcopy -D o -i $drive "$f" ::$to/
            fi
        done
    else
        mkdir -p "$drive$to"
        [ $# = 0 ] || cp -R "$@" "$drive$to/"
    fi
}

# TrueType and OpenType fonts for \SYSTEM\TTF (disks.zig's ttfFonts):
# fonts/TTF's and $ZDOS_PORTS_SRC/TTF's (unset: ../TTF), at any depth;
# not variable ones.
ttf_fonts() {
    local d
    for d in fonts/TTF "${ZDOS_PORTS_SRC:-..}/TTF"; do
        [ -d "$d" ] || continue
        find "$d" -type f \( -iname '*.ttf' -o -iname '*.otf' \) ! -iname '*variable*' | LC_ALL=C sort
    done
}

# fill_system <drive> <build folder> [floppy]
# The floppy has room only for one command interpreter.
fill_system() {
    if [ "$3" = floppy ]; then
        for app in COMMAND SYS; do put "$1" /APPS "$2/APPS/$app.APP"; done
        put "$1" /CONF conf/SYSTEM.CFG
        put "$1" /SCRIPTS scripts/AUTOEXEC.CMD
    else
        put "$1" /APPS $2/APPS/* $2/APPS_3RD/*
        put "$1" /GAMES $2/GAMES/*
        put "$1" /LIBS $2/LIBS/* $2/LIBS_3RD/*
        put "$1" /SYSTEM/DRIVERS $2/DRIVERS/*
        put "$1" /DATA build/DATA/*
        put "$1" /DATA data/*
        put "$1" /SYSTEM/FONTS fonts/terminal/*.zfn fonts/codepages/*.zcp
        local fonts=() f
        while IFS= read -r f; do fonts+=("$f"); done < <(ttf_fonts)
        put "$1" /SYSTEM/TTF ${fonts[@]+"${fonts[@]}"}
        put "$1" /SYSTEM/KEYB keyb/*.ZKB
        put "$1" /SCRIPTS scripts/*
        put "$1" /CONF conf/*
        put "$1" /DOCS README.md docs/*
    fi
    put "$1" /TEMP # TEMP= in SYSTEM.CFG
}

# Makes a FAT image bootable for the BIOS edition; the BPB stays.
# ZIGDOS.SYS must be the first root entry, as IO.SYS.
#   FAT12/16: vbr16.bin into the boot sector (BPB: bytes 3-61)
make_bootable() {
    dd if=$OUT/vbr16.bin of=$1 bs=1 count=3 conv=notrunc status=none
    dd if=$OUT/vbr16.bin of=$1 bs=1 skip=62 seek=62 count=450 conv=notrunc status=none
    mcopy -i $1 $OUT/ZIGDOS.SYS ::/ZIGDOS.SYS
    mattrib -i $1 +s +h +r ::/ZIGDOS.SYS
}
#   FAT32: vbr32.bin part 1 into the boot sector (BPB: bytes 3-89)
#          and its backup (sector 6), part 2 into sectors 2 and 8
make_bootable32() {
    for boot in 0 6; do
        dd if=$OUT/vbr32.bin of=$1 bs=1 count=3 seek=$((boot * 512)) conv=notrunc status=none
        dd if=$OUT/vbr32.bin of=$1 bs=1 skip=90 seek=$((boot * 512 + 90)) count=422 conv=notrunc status=none
        dd if=$OUT/vbr32.bin of=$1 bs=512 skip=1 seek=$((boot + 2)) count=1 conv=notrunc status=none
    done
    mcopy -i $1 $OUT/ZIGDOS.SYS ::/ZIGDOS.SYS
    mattrib -i $1 +s +h +r ::/ZIGDOS.SYS
}

# Only the functions above when sourced:
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

# lwIP's files the kernel uses (build.zig lists the same):
LWIP_SOURCES="core/def.c core/dns.c core/inet_chksum.c core/init.c core/ip.c core/mem.c core/memp.c
    core/netif.c core/pbuf.c core/raw.c core/stats.c core/tcp.c core/tcp_in.c core/tcp_out.c core/timeouts.c
    core/udp.c core/ipv4/dhcp.c core/ipv4/etharp.c core/ipv4/icmp.c core/ipv4/ip4.c core/ipv4/ip4_addr.c
    core/ipv4/ip4_frag.c netif/ethernet.c"

# TEST DISKS

# test_disks <edition>: extra disks for QEMU, as zig build test-disks
test_disks() {
case $1 in
x86)
    OUT=build/bios-x86
    mkdir -p $OUT
    rm -f $OUT/data.img $OUT/p?.img
    # bios-x86/data.img (MBR):
    #    p1 ext2 -> D:
    #    p5 FAT16, logical, of a "hidden" type -> no letter
    mke2fs -q -F -t ext2 -L DATA $OUT/p1.img $((64 * 1024))k
    mkfs.fat -F 16 -n RECOVERY -C $OUT/p5.img $((16 * 1024)) >/dev/null
    echo "Recovery data" > $OUT/RECOVER.TXT
    mcopy -i $OUT/p5.img $OUT/RECOVER.TXT ::/

    truncate -s 84M $OUT/data.img
    sfdisk -q $OUT/data.img <<EOF
label: dos
start=2048, size=131072, type=83
start=133120, size=34816, type=5
start=135168, size=32768, type=16
EOF
    dd if=$OUT/p1.img of=$OUT/data.img bs=512 seek=2048 conv=notrunc status=none
    dd if=$OUT/p5.img of=$OUT/data.img bs=512 seek=135168 conv=notrunc status=none
    rm $OUT/p1.img $OUT/p5.img $OUT/RECOVER.TXT
    echo "Built $OUT/data.img"
    ;;

uefi-x86_64 | x86_64)
    # Metal x86_64 gets the same disks:
    OUT=build/uefi-x86_64
    [ $1 = x86_64 ] && OUT=build/metal-x86_64
    mkdir -p $OUT
    rm -f $OUT/sata.img $OUT/usb.img $OUT/p?.img
    # sata.img (GPT):
    #   p1 ext2 -> D:
    #   p2 GPT attributes 62, 63 (hidden, no letter) -> no letter
    mke2fs -q -F -t ext2 -L DATA $OUT/p1.img $((64 * 1024))k
    mkfs.fat -F 16 -n RECOVERY -C $OUT/p2.img $((16 * 1024)) >/dev/null
    echo "Recovery data" > $OUT/RECOVER.TXT
    mcopy -i $OUT/p2.img $OUT/RECOVER.TXT ::/
    truncate -s 82M $OUT/sata.img
    sfdisk -q $OUT/sata.img <<EOF
label: gpt
start=2048, size=131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Data"
start=133120, size=32768, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Recovery", attrs="GUID:62,63"
EOF
    dd if=$OUT/p1.img of=$OUT/sata.img bs=512 seek=2048 conv=notrunc status=none
    dd if=$OUT/p2.img of=$OUT/sata.img bs=512 seek=133120 conv=notrunc status=none

    # USB stick:
    mkfs.fat -F 16 -n USB -C $OUT/p3.img $((16 * 1024)) >/dev/null
    echo "A USB stick" > $OUT/USB.TXT
    mcopy -i $OUT/p3.img $OUT/USB.TXT ::/
    truncate -s 20M $OUT/usb.img
    sfdisk -q $OUT/usb.img <<EOF
label: dos
start=2048, size=32768, type=6
EOF
    dd if=$OUT/p3.img of=$OUT/usb.img bs=512 seek=2048 conv=notrunc status=none
    rm $OUT/p1.img $OUT/p2.img $OUT/p3.img $OUT/RECOVER.TXT $OUT/USB.TXT
    echo "Built $OUT/sata.img, usb.img"
    ;;

uefi-arm64 | arm64)
    OUT=build/uefi-arm64
    [ $1 = arm64 ] && OUT=build/metal-arm64
    mkdir -p $OUT
    rm -f $OUT/data.img $OUT/p?.img
    # data.img (GPT):
    mke2fs -q -F -t ext2 -L DATA $OUT/p1.img $((64 * 1024))k
    truncate -s 66M $OUT/data.img
    sfdisk -q $OUT/data.img <<EOF
label: gpt
start=2048, size=131072, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="Data"
EOF
    dd if=$OUT/p1.img of=$OUT/data.img bs=512 seek=2048 conv=notrunc status=none
    rm $OUT/p1.img
    echo "Built $OUT/data.img"
    ;;
esac
}

# EDITIONS

# --test-disks (anywhere among the arguments):
with_test_disks=no
editions=""
for arg in "$@"; do
    if [ "$arg" = --test-disks ]; then with_test_disks=yes; else editions="$editions $arg"; fi
done

for edition in ${editions:-x86 uefi-x86_64 uefi-arm64 x86_64 arm64}; do
case $edition in

x86)
    OUT=build/bios-x86
    TARGET="-target x86-freestanding -mcpu=i686"  # no MMX / SSE: every CPU from the Pentium Pro on
    LD=sdk/linkers/app-x86.ld
    mkdir -p $OUT
    rm -f $OUT/system.img $OUT/floppy.img $OUT/p?.img

    # BIOS KERNEL
    # At 1 MiB, LZ4-compressed. ZIGDOS.SYS is loaded to 0x8000 and
    # must end below 0x80000: 4 KiB of stage 2 plus at most 952
    # sectors of compressed kernel.
    zig build-exe src/main_bios.zig $TARGET -O ReleaseSmall -T src/boot/bios/kernel.ld --name kernel -femit-bin=$OUT/kernel.elf \
        -Isrc/net/port -Isrc/net/lwip/include -cflags -ffreestanding -fno-stack-protector -- src/net/glue.c src/net/nat.c $(for f in $LWIP_SOURCES; do printf ' src/net/lwip/%s' $f; done)
    ENTRY=$(readelf -h $OUT/kernel.elf | awk '/Entry point/ {print $4}')
    [ "$ENTRY" = 0x100000 ] || { echo "the kernel's entry is $ENTRY, not 0x100000"; exit 1; }
    objcopy -O binary $OUT/kernel.elf $OUT/kernel.bin
    zig build-exe -O ReleaseSafe tools/build/lz4.zig -femit-bin=build/lz4-tool
    build/lz4-tool $OUT/kernel.bin $OUT/kernel.lz4
    KERNEL_PACKED=$(stat -c %s $OUT/kernel.lz4)
    [ $KERNEL_PACKED -le $((952 * 512)) ] || { echo "the kernel is too large ($KERNEL_PACKED bytes, compressed)"; exit 1; }

    # BIOS BOOT CODE
    # Stage 2. Only .text: as adds a .note.gnu.property section that
    # would bloat it (the same for the boot sectors):
    as --32 --defsym KERNEL_PACKED=$KERNEL_PACKED src/boot/bios/stage2.s -o $OUT/stage2.o
    ld -m elf_i386 -Ttext 0x8000 -e _start $OUT/stage2.o -o $OUT/stage2.elf
    objcopy -O binary -j .text $OUT/stage2.elf $OUT/stage2.bin
    [ $(stat -c %s $OUT/stage2.bin) -le 4096 ] || { echo "stage2.bin is larger than 4 KiB"; exit 1; }

    # ZIGDOS.SYS = stage 2 padded to 4 KiB + the kernel:
    truncate -s 4096 $OUT/stage2.bin
    cat $OUT/stage2.bin $OUT/kernel.lz4 > $OUT/ZIGDOS.SYS

    # The boot sectors:
    as --32 src/boot/bios/mbr.s -o $OUT/mbr.o
    ld -m elf_i386 -Ttext 0x0600 -e _start $OUT/mbr.o -o $OUT/mbr.elf
    objcopy -O binary -j .text $OUT/mbr.elf $OUT/mbr.bin
    [ $(stat -c %s $OUT/mbr.bin) -eq 440 ] || { echo "mbr.bin is not 440 bytes"; exit 1; }
    as --32 src/boot/bios/vbr16.s -o $OUT/vbr16.o
    ld -m elf_i386 -Ttext 0x7C00 -e _start $OUT/vbr16.o -o $OUT/vbr16.elf
    objcopy -O binary -j .text $OUT/vbr16.elf $OUT/vbr16.bin
    [ $(stat -c %s $OUT/vbr16.bin) -eq 512 ] || { echo "vbr16.bin is not 512 bytes"; exit 1; }
    as --32 src/boot/bios/vbr32.s -o $OUT/vbr32.o
    ld -m elf_i386 -Ttext 0x7C00 -e _start $OUT/vbr32.o -o $OUT/vbr32.elf
    objcopy -O binary -j .text $OUT/vbr32.elf $OUT/vbr32.bin
    [ $(stat -c %s $OUT/vbr32.bin) -eq 1024 ] || { echo "vbr32.bin is not 1024 bytes"; exit 1; }
    rm -f $OUT/*.o $OUT/*.elf $OUT/stage2.bin $OUT/kernel.bin $OUT/kernel.lz4

    # BIOS APPS
    programs

    # FAT SYSTEM DISK
    # MBR, p1 FAT32, active -> C:. The boot sector needs -h =
    # the partition's start; mkfs.fat leaves sectors 2 and 8
    # free for part 2 of the boot code:
    mkfs.fat -F 32 -n ZDOS -h 2048 -C $OUT/p1.img $((SYS_DISK_SIZE * 1024)) >/dev/null
    make_bootable32 $OUT/p1.img
    fill_system $OUT/p1.img $OUT

    truncate -s $((SYS_DISK_SIZE + 2))M $OUT/system.img
    sfdisk -q $OUT/system.img <<EOF
label: dos
start=2048, size=$((SYS_DISK_SIZE * 2048)), type=c, bootable
EOF
    dd if=$OUT/mbr.bin of=$OUT/system.img bs=440 count=1 conv=notrunc status=none
    dd if=$OUT/p1.img of=$OUT/system.img bs=512 seek=2048 conv=notrunc status=none
    rm $OUT/p1.img

    # BOOT FLOPPY
    # 1.44 MB, FAT12, no partition table:
    mkfs.fat -F 12 -n ZIGDOS -C $OUT/floppy.img 1440 >/dev/null
    make_bootable $OUT/floppy.img
    fill_system $OUT/floppy.img $OUT floppy

    echo "Built $OUT: ZIGDOS.SYS, system.img, floppy.img"
    ;;

x86_64 | arm64 | uefi-x86_64 | uefi-arm64)
    PLATFORM=metal
    MAIN=src/main.zig
    if [ ${edition#uefi-} != $edition ]; then
        PLATFORM=uefi
        MAIN=src/main_uefi.zig
    fi
    if [ ${edition#uefi-} = x86_64 ]; then
        OUT=build/$PLATFORM-x86_64
        BOOT=BOOTX64
        KERNEL_TARGET=x86_64-uefi
        TARGET="-target x86_64-freestanding -mno-red-zone"
        LD=sdk/linkers/app-x86_64.ld
    else
        OUT=build/$PLATFORM-arm64
        BOOT=BOOTAA64
        KERNEL_TARGET=aarch64-uefi
        TARGET="-target aarch64-freestanding"
        LD=sdk/linkers/app-arm64.ld
    fi
    mkdir -p $OUT
    rm -f $OUT/system.img $OUT/p?.img

    # UEFI AND METAL KERNEL
    NET_FLAGS="-ffreestanding -fno-stack-protector"
    # Metal takes interrupts on the kernel's stack: no red zone.
    [ $PLATFORM = metal ] && [ $BOOT = BOOTX64 ] && NET_FLAGS="$NET_FLAGS -mno-red-zone"
    NET="-Isrc/net/port -Isrc/net/lwip/include -cflags $NET_FLAGS -- src/net/glue.c src/net/nat.c"
    for f in $LWIP_SOURCES; do NET="$NET src/net/lwip/$f"; done
    KERNEL="$NET $MAIN"
    if [ $PLATFORM = metal ]; then
        KERNEL="$NET --dep default_font.zfn -Mroot=$MAIN -Mdefault_font.zfn=fonts/terminal/spleen-12x24.zfn"
        [ $BOOT = BOOTX64 ] && KERNEL="-mno-red-zone $KERNEL"
    fi
    zig build-exe -target $KERNEL_TARGET -O ReleaseSmall --name $BOOT -femit-bin=$OUT/$BOOT.EFI $KERNEL 

    # UEFI AND METAL APPS
    programs

    # MINIX SYSTEM DISK
    # GPT: p1 EFI System Partition (FAT32), only \EFI\BOOT -> no letter;
    # p2 Minix V3, made by tools/build/disks.zig -> C:
    mkfs.fat -F 32 -n EFI -C $OUT/p1.img $((64 * 1024)) >/dev/null
    put $OUT/p1.img /EFI/BOOT $OUT/$BOOT.EFI
    mattrib -i $OUT/p1.img +s ::/EFI/BOOT/$BOOT.EFI
    zig build-exe -O ReleaseSafe --dep zdos_fs --dep mkmfs3 -Mroot=tools/build/disks.zig \
        -Mzdos_fs=src/host_fs.zig -Mmkmfs3=tools/disk/mkmfs3-host.zig --name disks -femit-bin=build/disks-tool
    build/disks-tool minix-system ${OUT#build/} $OUT/p2.mfs

    truncate -s $((SYS_DISK_SIZE + 66))M $OUT/system.img
    sfdisk -q $OUT/system.img <<EOF
label: gpt
start=2048, size=131072, type=U, name="EFI System"
start=133120, size=$((SYS_DISK_SIZE * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="zdos"
EOF
    dd if=$OUT/p1.img of=$OUT/system.img bs=512 seek=2048 conv=notrunc status=none
    dd if=$OUT/p2.mfs of=$OUT/system.img bs=512 seek=133120 conv=notrunc status=none
    rm $OUT/p1.img $OUT/p2.mfs

    echo "Built $OUT: $BOOT.EFI, system.img"
    ;;

*)
    echo "Usage: $0 [--test-disks] [x86_64] [arm64] [uefi-x86_64] [uefi-arm64] [x86]"
    exit 1
    ;;
esac
if [ $with_test_disks = yes ]; then test_disks $edition; fi
done
