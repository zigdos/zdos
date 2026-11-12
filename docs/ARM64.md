# ZDOS for ARM64 (UEFI)

ZDOS also runs on 64-bit ARM machines with UEFI firmware. It is the same kernel and UEFI backend as on x86-64; only the CPU code (`src/arch/arm64.zig`) and the program format differ.

```sh
zig build uefi-arm64  # build/uefi-arm64/
./run-uefi-arm64.sh   # QEMU "virt" machine, Cortex-A57 (emulated) or the host CPU
```

QEMU needs the ARM64 UEFI firmware: `edk2-aarch64` on Fedora, `qemu-efi-aarch64` on Debian / Ubuntu. `system.img` is laid out as on x86-64 (see [Building](../README.md#building)); `zig build test-disks` adds `data.img` with one empty ext2 partition (D:).

The metal edition is built with `zig build arm64` into `build/metal-arm64/`: started by the firmware, ZDOS leaves it and drives the machine itself (NVMe, SATA, virtio-blk and USB disks, USB keyboard and mouse, the framebuffer, e1000, virtio-net and ENA network cards; HD Audio and Realtek cards through drivers), with tasks on all cores (woken by the GIC's software interrupts) and its own page tables (16 KiB pages where the CPU has them). `./run-metal-arm64.sh` runs it on the same QEMU machine, `./install.sh metal-rpi4u <card>` puts it on a Pi's card.

## Status

- [x] QEMU `virt` machine.
- [ ] Real ARM64 hardware: not tested. Should work on machines with UEFI firmware: Ampere servers, Windows-on-ARM laptops (Secure Boot off), a Raspberry Pi with community UEFI firmware.
- [x] Raspberry Pi 4: the card is built (below).
- [ ] Raspberry Pi 4 needs testing on a real Pi. QEMU can't run it: its `raspi4b` machine can't start the Pi's GPU firmware.

## Raspberry Pi 4 (also Pi 400, CM4)

```sh
./install.sh uefi-rpi4u /run/media/$USER/ZDOS    # the mounted SD card (or USB drive)
```

Build the ARM64 edition first (`zig build uefi-arm64` or `./build.sh uefi-arm64`): `install.sh` copies its drive C: from that build and the sources. `metal-rpi4u` puts the metal edition on the card instead (`zig build arm64`).

The firmware ([pftf/RPi4](https://github.com/pftf/RPi4)) comes from `../RPi4_UEFI_Firmware` next to the ZDOS folder, `$ZDOS_PORTS_SRC/RPi4_UEFI_Firmware`, or `build/rpi4u-arm64/` (for the release zip also `-Drpi4-firmware=<folder>`). `install.sh` copies it to the root of the card, with the edition's drive C: beside it.

The card needs an MBR and a FAT32 partition first, type `0x0C` (the firmware's Readme suggests `0xEF` if a Pi doesn't start):

```sh
sudo parted /dev/sdX --script mklabel msdos mkpart primary fat32 1MiB 100%
sudo mkfs.fat -F 32 -n ZDOS /dev/sdX1
```

Plug the monitor into HDMI 0 (next to the power socket) and connect a USB keyboard. The Pi shows a coloured screen, then its logo (Esc: firmware setup, e.g. the screen resolution), then ZDOS with the card as C:. If it stops in the firmware, start `\EFI\BOOT\BOOTAA64.EFI` from its UEFI shell or put the card first in the boot order.

## How it differs from x86-64

|                        | x86-64              | ARM64                        |
| ---------------------- | ------------------- | ---------------------------- |
| UEFI boot file         | `BOOTX64.EFI`       | `BOOTAA64.EFI`               |
| API calling convention | Microsoft x64       | standard ARM64 (AAPCS64)     |
| `.APP` magic           | `ZAP6`              | `ZAPA`                       |
| Linker script          | `app-x86_64.ld`     | `app-arm64.ld`               |
| Relocations            | `R_X86_64_RELATIVE` | `R_AARCH64_RELATIVE`         |
| Millisecond counter    | TSC (`rdtsc`)       | generic timer (`CNTVCT_EL0`) |
| After loading          | nothing             | caches synced                |

The linker scripts are in `sdk/linkers/`. After loading a program, ARM64 writes the data cache back and invalidates the instruction cache (`arch.syncCode`).

## Programs

The same sources, built for `aarch64-freestanding` with `sdk/linkers/app-arm64.ld`:

```sh
zig build-exe -target aarch64-freestanding -O ReleaseSmall -fPIE \
    -fentry=zdos_entry -T sdk/linkers/app-arm64.ld -femit-bin=hello.elf \
    --dep abi -Mroot=hello.zig -Mabi=src/kernel/abi.zig
zig objcopy -O binary hello.elf HELLO.APP
```

```sh
zig cc -target aarch64-freestanding -Os -ffreestanding -fPIE -fno-stack-protector -nostdlib \
    -Wl,-e,zdos_entry -Wl,-T,sdk/linkers/app-arm64.ld -I sdk/src -o hello.elf hello.c
zig objcopy -O binary hello.elf HELLO.APP
```

With the SDK's C library, a program with `main()` instead of `zdos_entry`: `sdk/bin/zdos-cc --arch=arm64 hello.c -o HELLO.APP` (see `sdk/README.md`).

`apps/zdos/zdos.zig` and `sdk/src/zdos.h` pick the calling convention themselves. An x86 `.APP` is refused with "Not a ZDOS program", and the other way round.
