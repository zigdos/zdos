# ZDOS for BIOS PCs

The edition for old PCs that boot with a BIOS: **32-bit, any i686 CPU (Pentium Pro, Pentium II and later)**. The kernel, the program API and `COMMAND.APP` are the same as on UEFI; the boot loader, the platform backend and the drivers are its own.

```
ZDOS version 0.2 BIOS

Drives:
  A:  ZIGDOS      FAT12         1 MB
  C:  ZDOS        FAT32       126 MB   (boot)

Type HELP for a list of commands
```

## Contents

1. [Status](#status)
2. [Building and running](#building-and-running)
3. [Installing on a real PC](#installing-on-a-real-pc)
4. [How it works](#how-it-works)
5. [Programs](#programs)

## Status

- [x] QEMU (SeaBIOS) booted from FAT12, FAT16 and FAT32, from hard disks, USB sticks and floppies.
- [x] ext2 and Minix V3 partitions as further drives, read and write (ZDOS boots from FAT only).
- [ ] Retro hardware (Pentium II / III / IV): not tested yet.
- [x] Keyboard: full support, with key releases and modifier keys on their own (UEFI can't do either). Num Lock starts as the BIOS left it.
- [x] PS/2 mouse with wheel; USB keyboards and mice through the BIOS's legacy emulation.
- [x] Graphics for programs: the VESA BIOS's modes (VBE 2.0 and up, linear framebuffer) in 256 colors and true color, and VGA mode 13h, 320 x 200 in 256 colors; without VESA, mode 12h, 640 x 480 in 16, for larger pictures.
- [x] Screen: 80 x 25 text, background colors 0-7 only.
- [x] Long file names (case-insensitive for ASCII letters only); no 260-character path limit.
- [x] Floppy changes are noticed ([below](#changing-floppies)).
- [x] Preemptive tasks on all cores ([Real-Time](REALTIME.md#the-bios-edition)), the network on Intel e1000 cards (interrupts, else polled).
- [x] CPU faults in a program's code are signals, as on metal (no paging: null pointers and stray writes don't fault).
- [x] Drivers from `\SYSTEM\DRIVERS` ([API](API.md#drivers-sys)): the Realtek network cards (`RTL8139.SYS`, `RTL8169.SYS`) and sound (`SB16.SYS`, `AC97.SYS`, `HDA.SYS`).
- [ ] Power off on machines without APM (needs ACPI): switch off by hand after `SHUTDOWN`.
- [ ] Write cache: writes go straight to the disk, slow on real floppies.
- [ ] Memory above 4 GiB (32-bit without paging).
- [ ] Disks plugged in after startup (except floppies).

## Building and running

```sh
zig build x86               # needs binutils too (see the README)
./run-bios-x86.sh           # QEMU: i440FX PC, Pentium 4, 4 cores, 1 GB, IDE disk, the boot floppy as A:
./run-bios-x86.sh floppy    # the same, booting from the floppy
```

QEMU has no Pentium 4 model: `run-bios-x86.sh` makes one from its Pentium III with SSE2. Extra arguments go to QEMU, e.g. `./run-bios-x86.sh -m 16M`.

`zig build x86` makes in `build/bios-x86/`:

- `ZIGDOS.SYS`: ZDOS itself, stage 2 of the boot loader followed by the kernel (LZ4).
- `system.img`: the boot disk, an MBR and one active FAT32 partition (C:) with `ZIGDOS.SYS` and the usual folders (see [Building](../README.md#building)).
- `floppy.img`: a bootable 1.44 MB floppy (FAT12), a showcase: `ZIGDOS.SYS`, `COMMAND.APP` and `SYS.APP`, `\CONF` and `\SCRIPTS\AUTOEXEC.CMD`. Booted from, it is A: and ZDOS sets `PATH=A:\APPS`.
- `mbr.bin`, `vbr16.bin`, `vbr32.bin`: the boot code, for installing by hand (below).
- `data.img`, made by `zig build test-disks`, `zig build x86 -Dtest-disks` or `./build.sh x86 --test-disks`: a second disk with an empty ext2 partition (D:) and a hidden FAT16 logical partition (no letter, shown by `DRIVES`).

## Installing on a real PC

ZDOS boots like DOS: the MBR starts the active partition, whose boot sector loads `ZIGDOS.SYS` from the root directory.

**Whole disk** (hard disk, CompactFlash card or USB stick; everything on it is replaced):

```sh
sudo dd if=build/bios-x86/system.img of=/dev/sdX bs=1M conv=fsync
```

**Floppy:** `sudo dd if=build/bios-x86/floppy.img of=/dev/fd0`.

**An existing FAT partition**, like DOS's `SYS`. From ZDOS itself, `SYS D:` does it. From Linux: the partition must have been formatted with its start sector as "hidden sectors" (`mkfs.fat -h START` does that), then:

1. Write the boot code, keeping the partition's BPB.
   - FAT12 / FAT16:
     ```sh
     sudo dd if=build/bios-x86/vbr16.bin of=/dev/sdX1 bs=1 count=3 conv=notrunc
     sudo dd if=build/bios-x86/vbr16.bin of=/dev/sdX1 bs=1 skip=62 seek=62 count=450 conv=notrunc
     ```
   - FAT32: part 1 into the boot sector and its backup (sector 6), part 2 into sectors 2 and 8. Check first that FSInfo is in sector 1 and the backup in 6 (`mkfs.fat` and Windows do it so):
     ```sh
     for b in 0 6; do
       sudo dd if=build/bios-x86/vbr32.bin of=/dev/sdX1 bs=1 count=3 seek=$((b*512)) conv=notrunc
       sudo dd if=build/bios-x86/vbr32.bin of=/dev/sdX1 bs=1 skip=90 seek=$((b*512+90)) count=422 conv=notrunc
       sudo dd if=build/bios-x86/vbr32.bin of=/dev/sdX1 bs=512 skip=1 seek=$((b+2)) count=1 conv=notrunc
     done
     ```
2. Copy `ZIGDOS.SYS` to the root directory.
3. Mark the partition active, with an MBR that starts it (any DOS / Windows MBR, or the 440 bytes of `mbr.bin` in the disk's first sector). GRUB or Windows' boot menu can chain-load the partition instead.

**Updating ZDOS** is copying a new `ZIGDOS.SYS` over the old one. It is read-only, system and hidden, and ZDOS refuses to overwrite, delete, rename or move it until `ATTRIB` clears that:

```
C:\>attrib -r -s -h zigdos.sys
C:\>copy d:\new\zigdos.sys c:\
C:\>attrib +r +s +h zigdos.sys
```

## How it works

### Boot

```
BIOS -> MBR -> boot sector of the active FAT partition -> ZIGDOS.SYS: stage 2 -> kernel
```

1. The **MBR** (`src/boot/bios/mbr.s`) moves itself to `0000:0600`, loads the active partition's first sector to `0000:7C00` and jumps to it. A floppy has no MBR; the BIOS loads its boot sector directly.
2. The **boot sector** finds `ZIGDOS.SYS` in the root directory and loads it, fragmented or not, to `0000:8000`. It uses LBA reads, or cylinder / head / sector where the BIOS has no LBA (it then trusts the BPB's geometry, as DOS did), with retries for floppies.
   - `vbr16.s`, FAT12 and FAT16: one sector.
   - `vbr32.s`, FAT32: the boot sector has room for 420 bytes of code only, so it first loads a second code sector from the reserved sector 2, as Microsoft's FAT32 boot code does.
3. **Stage 2** (`stage2.s`, the first 4 KiB of `ZIGDOS.SYS`) sets 80 x 25 text mode, enables A20 (BIOS, keyboard controller, port 0x92), collects the memory map (E820, E801, 88h), switches to protected mode, unpacks the kernel to 1 MiB and jumps to it, telling it which partition it came from (C:).
4. The **kernel** (`src/main_bios.zig`) clears its `.bss`, installs the CPU exception handlers, turns on the FPU and SSE, and starts `COMMAND.APP` from `A:\APPS` after booting from a floppy, else from `C:\APPS`.

### Low memory while ZDOS runs

| Address    | Contents                                                     |
| ---------- | ------------------------------------------------------------ |
| `0x01000`  | memory map from the BIOS                                     |
| `0x02000`  | scratch area for BIOS calls (disk address packets ...)       |
| `0x07C00`  | top of the stack used during BIOS calls                      |
| `0x08000`  | stage 2: GDT and `bios_call` stay in use                     |
| `0x09000`  | other cores' start-up code (first: the packed kernel)        |
| `0x10000`  | 64 KiB bounce buffer for disk transfers                      |
| `0x100000` | the kernel, its `.bss`, stack, page bitmap; then free memory |

### BIOS calls and interrupts

Stage 2 keeps `bios_call`, which switches back to real mode, runs a BIOS interrupt and returns. ZDOS uses it for floppies and disks without its own driver (int 13h), the graphics mode (int 10h) and power off (APM); data goes through the bounce buffer. BIOS calls run on core 0, with the BIOS's interrupt setup put back for their time. IDE disks go through ZDOS's own ATA driver and AHCI disks through its SATA driver, matched to the BIOS's disks by size and first sectors.

Tasks switch preemptively on every core where the BIOS left the local APIC on (else core 0 only), each with its one-shot local APIC timer (else the PIT). Other cores are found in ACPI's MADT or the MultiProcessor table. The network runs on the last core when there are two or more.

A CPU fault in a program's code becomes a signal, as on metal; one in ZDOS's own code, or in a job on another core, shows the registers and halts.

The VGA text screen holds one byte per character, so the console turns each UTF-8 character into the active code page's byte (437 unless `CODEPAGE=` loads another), or `?` when the code page lacks it.

### Changing floppies

Floppy drives always have their letter, also when empty (`DRIVES` shows `(no disk)`). ZDOS checks a drive's change line once per command that uses it, once per file call of a program, and in `DRIVES`; never in the background. When the line reports a change (SeaBIOS always does), ZDOS compares the boot sector with the one it knows:

- Same disk: its cached sectors and free space are forgotten.
- Another disk: mounted anew with the geometry from its boot sector (a 1.44 MB disk in a 2.88 MB drive works). The drive goes back to its root; files still open on the old disk fail.
- No disk: `Drive A: is not ready (no disk?)`.

In QEMU, swap floppies in the monitor (Ctrl+Alt+2): `change floppy0 other.img raw`, or `eject -f floppy0`.

### Sources

- `src/boot/bios/`: the MBR, the boot sectors, stage 2 with `bios_call`, and `kernel.ld` (the kernel at 1 MiB).
- `src/main_bios.zig`: the kernel's entry point.
- `src/platform/bios/`: the edition's backend; BIOS calls in `realmode.zig`, int 13h disks in `disk.zig`.
- `src/arch/x86.zig`: 32-bit x86.

## Programs

The same sources, built for 32-bit x86 with `sdk/linkers/app-x86.ld`. The API uses the 32-bit C calling convention (cdecl) here; `apps/zdos/zdos.zig` and `sdk/src/zdos.h` pick it themselves.

```sh
zig build-exe -target x86-freestanding -mcpu=i686 -O ReleaseSmall -fPIE \
    -fentry=zdos_entry -T sdk/linkers/app-x86.ld -femit-bin=hello.elf \
    --dep abi -Mroot=hello.zig -Mabi=src/kernel/abi.zig
zig objcopy -O binary hello.elf HELLO.APP
```

Zig's `@sin`, `@cos` ... need the x87 at double precision (no SSE here): `zdos.zig` sets it at a program's start and in `tlsStart`; a job on another core calls `zdos.fpuForZig()` first. C programs keep extended precision (`long double`).

C, with the SDK's C library (a program with `main()`): `sdk/bin/zdos-cc --arch=x86 hello.c -o HELLO.APP`, see `sdk/README.md`. A 32-bit `.APP` (`ZAP3`) is refused by the 64-bit editions with "Not a ZDOS program", and the other way round.
