# ZIG-DOS (ZDOS)

A real-time operating system in the spirit of DOS for 64-bit PCs and 64-bit ARM machines with UEFI firmware, written in Zig. It implements partial POSIX support. It also has an edition for old 32-bit BIOS PCs.

```
ZDOS version 0.2 METAL

Drives:
  C:              minix       128 MB
  D:  DATA        ext2        128 MB

Type HELP for a list of commands

C:\>DIR
 Volume in drive C has no label
 Directory of C:\
2026-11-09  23:20  <DIR> APPS
2026-11-09  23:20  <DIR> CONF
2026-11-09  23:20  <DIR> DATA
...
 10 Dir(s), 60,420,096 bytes free
```

---

## Contents

1. [About](#about)
2. [Installation](#installation)
3. [Running programs](#running-programs)
4. [Usage](#usage)
5. [Feature matrix](#feature-matrix)
6. [Further documentation](#further-documentation)

The commands and batch files are described in [docs/COMMAND.md](docs/COMMAND.md).

---

## About

ZIG-DOS or ZDOS is a command-line operating system in the spirit of MS-DOS: drive letters, a current directory per drive, the familiar commands (`DIR`, `CD`, `COPY` ..., with Unix-style aliases `LS`, `CP` ...), batch files, and its own `.APP` programs written in Zig, C, C++, Rust. The shell is a program too, `COMMAND.APP`, like DOS's `COMMAND.COM`. Beyond DOS it has [users](docs/USERS.md) with Unix-style file permissions, a [network](docs/NETWORK.md), hardware drivers, libraries, and various apps and servers: supplied with the OS and ported. Programs can run at the same time, as tasks.

The editions share the kernel, the shell and the program API:

- **x86-64 and ARM64 Metal**: started by the UEFI firmware, ZDOS then leaves it and drives the hardware itself: NVMe, SATA, virtio-blk and USB disks, network cards, USB (and on x86-64 PS/2) keyboards and mice, the framebuffer. They add preemptive tasks on all CPU cores (UEFI's switch only inside ZDOS) and ZDOS's own page tables.
- **x86-64 and ARM64 UEFI**: runs on top of the firmware, which drives devices, the way MS-DOS used the BIOS. The kernel reaches the machine through a small platform layer.
- **x86 BIOS**: for old 32-bit PCs, with its own boot loader and drivers ([docs/BIOS.md](docs/BIOS.md)).
- **Raspberry Pi 4** (also Pi 400, CM4): the ARM64 edition with the Pi's UEFI firmware on an SD card ([docs/ARM64.md](docs/ARM64.md#raspberry-pi-4-also-pi-400-cm4)).


---

## Installation

### System requirements
- **CPU:** BIOS edition: Pentium Pro or later (i686). Metal and UEFI: an x86-64 or 64-bit ARM (ARMv8-A) CPU; machine with UEFI firmware.
- **Cores:** up to 64 (BIOS edition: up to 16); up to 64 tasks and threads together.
- **RAM:** 32 MB or more for the BIOS edition; 64 MB or more for the others.
- **Disk:** 256 MB or more (hard disk, SSD, USB stick, CompactFlash or SD card); the BIOS edition also boots from a 1.44 MB floppy.

### QEMU images

Ready-to-use releases are provided for every edition, either as QEMU images or as installation packages for a USB stick or SD card (see [Releases](#releases)). To try ZDOS, unzip a QEMU image and start its run script, e.g. `./run-uefi-x86_64.sh`; only QEMU is needed.

### Prerequisites

To build ZDOS and its disk images you need Linux (macOS should work with the Homebrew packages) and:
- **Zig 0.14**, from [ziglang.org](https://ziglang.org) (Homebrew: `zig@0.14`).
- **dosfstools** (`mkfs.fat`) and **mtools**, to make the disk images and copy files into them; **e2fsprogs** (`mke2fs`) for the test disks.
- **binutils** (`as`, `ld`, `objcopy`), for the BIOS/x86 edition's boot loader only. On macOS that is `x86_64-elf-binutils`, used as `x86_64-elf-as` ... (`-Dbinutils-prefix=` changes the prefix).
- **zip**, for the release zips only (`dist.sh` also `sha256sum`, from coreutils).

```sh
sudo dnf install dosfstools mtools e2fsprogs binutils zip             # Fedora / Centos
sudo apt install dosfstools mtools e2fsprogs binutils zip coreutils   # Debian / Ubuntu
brew install zig@0.14 dosfstools mtools e2fsprogs x86_64-elf-binutils # macOS
```

`zig build` writes the partition tables and boot sectors itself (`tools/build/`), so it needs no `sfdisk`, `dd` or `truncate` and works on macOS. `./build.sh` does the same with plain commands and needs them (util-linux): Linux only.

To run ZDOS in an emulator you need QEMU and the UEFI firmware for it (OVMF for x86-64, edk2 for ARM64); the BIOS/x86 edition needs only QEMU:

```sh
sudo dnf install qemu-system-x86 edk2-ovmf qemu-system-aarch64 edk2-aarch64 # Fedora / Centos
sudo apt install qemu-system-x86 ovmf qemu-system-arm qemu-efi-aarch64      # Debian / Ubuntu
sudo pacman -S qemu-full edk2-ovmf edk2-aarch64                             # Arch
brew install qemu                                                           # macOS
```

### Building

```sh
zig build               # all editions
zig build uefi-x86_64   # one edition: uefi-x86_64, uefi-arm64, x86 (BIOS); x86_64, arm64: metal
zig build test-disks    # only the extra disks for testing in QEMU, all editions
zig build x86 -Dtest-disks    # an edition with its test disks
./build.sh              # the same with plain commands (Linux)
./build.sh uefi-x86_64  # one edition, the same names
./build.sh x86 --test-disks   # an edition with its test disks
```
The OS building does not include ports.
To build all ports, download their code and set up [the environment](ports/README.md).
```sh
ports/category/name/build.sh # one port
for b in ports/*/*/build.sh; do $b || { echo "FAILED: $b"; break; }; done # all ports
```

`build.zig` only compiles; `tools/build/disks.zig` then makes the images, step by step. `build.sh` is the whole build as one list of commands; its `fill_system()` (`fillSystem()` in `disks.zig`) says what goes onto drive C:.

Each edition has its folder in `build/`: `uefi-x86_64`, `bios-x86`, `uefi-arm64`, `metal-x86_64`, `metal-arm64` (the Raspberry Pi 4 uses the ARM64 one: [ARM64.md](docs/ARM64.md#raspberry-pi-4-also-pi-400-cm4)). In `build/uefi-x86_64/`:

- `BOOTX64.EFI`: ZDOS itself, a UEFI application.
- `system.img`: the system disk: the EFI System Partition (FAT32) with ZDOS (no letter) and the ZDOS partition, C:, a Minix V3 file system (UEFI and metal editions) or FAT32 (the BIOS edition). `disks.zig` formats it with `tools/disk/mkmfs3-host.zig` and fills it through ZDOS's own Minix driver (`tools/build/minix.zig`), so it needs no `mkfs.minix` or root; everything on it is root's, folders and programs mode 0755, other files 0644, `\TEMP` 1777 (see [Users](docs/USERS.md)).
- `sata.img`, `usb.img`, made by `zig build test-disks`: a SATA disk with an empty ext2 partition (D:) and a hidden FAT one (no letter, like a Windows recovery partition), and a USB stick with one FAT16 partition. The run scripts attach them.

The disks are filled as follows. `\EFI\BOOT\BOOTX64.EFI`: ZDOS (on the EFI System Partition). Then drive C: is filled from build folders and the sources, wherever it is written: the system image, a stick (`install.sh`), a release's `files/`. It gets:
- `\APPS`: ZDOS's programs from `build/<edition>/APPS/` (rebuilt every time) and the [ports](ports/README.md)' from `build/<edition>/APPS_3RD/` (kept).
- `\GAMES`: from `build/<edition>/GAMES/` (kept).
- `\LIBS`: libraries from `build/<edition>/LIBS/` and `LIBS_3RD/`.
- `\DATA`: from `build/DATA/` and `data/`, the programs' data, the same for all editions (kept).
- `\SYSTEM`: ZDOS's own files: the fonts from `fonts/terminal/` and codepage maps from `fonts/codepages/` in `\SYSTEM\FONTS`, `keyb/` (keyboard layouts) in `\SYSTEM\KEYB`, drivers in `\SYSTEM\DRIVERS`.
- `\SCRIPTS`, `\CONF`: from `scripts/` (batch files, Python scripts) and `conf/` (`SYSTEM.CFG`).
- `\TEMP`: empty, for temporary files (`TEMP=` in `SYSTEM.CFG`).
- `\DOCS`: this `README.md` and `docs/` that contsains system manuals and `COPYING` that holds related copyright notices and licenses.

### Running in QEMU

Each edition has its own run script, one plain QEMU command:

- `./run-metal-x86_64.sh`, `./run-metal-arm64.sh`: q35 PC or QEMU's "virt" ARM machine (see [docs/ARM64.md](docs/ARM64.md)) with the system disk as an NVMe SSD.
- `./run-uefi-x86_64.sh`: same q35 PC.
- `./run-uefi-arm64.sh`: the same "virt" ARM machine.
- `./run-bios-x86.sh`: an old PC (see [docs/BIOS.md](docs/BIOS.md)); `./run-bios-x86.sh floppy` starts from the boot floppy.

They attach the test disks, if made. Extra arguments go to QEMU: `./run-uefi-x86_64.sh -m 512M`. Where this machine's CPU runs the edition's natively (x86-64 for the x86 and x86-64 editions, ARM64 for the ARM64 ones), they use KVM on Linux and HVF on macOS, else QEMU emulates the CPU; `ZDOS_ACCEL=tcg` (or `kvm`, `hvf`) chooses, as does an `-accel` of your own.

- The firmware's settings are kept in `build/uefi-x86_64/OVMF_VARS.fd`, so changes made in the firmware setup survive between runs. Delete that file to reset them.
- **Screen resolution / text size**: press **Esc** while QEMU boots, then go to *Device Manager -> OVMF Platform Configuration* and pick a resolution.
- The clock follows your local time (`-rtc base=localtime` in the run scripts).

### Tests

ZDOS's test suites are in `tests/`; each script's header gives its usage.

### Releases

```sh
zig build dist -Dversion=0.1     # dist/: the zips and SHA256SUMS-0.1-ZDOS
./dist.sh 0.1                 # the same with plain commands, from what ./build.sh built (Linux)
```

- `zdos-<version>-<platform>-<arch>.zip`: the metal or uefi platform images (`zdos-metal-*.img`, `zdos-uefi-*.img`) for x86_64, arm64 arch, run scripts for QEMU and QEMU's firmware.
- `zdos-<version>-bios-x86.zip`: `zdos-bios-x86.img` and `run-bios-x86.sh`, for QEMU or for writing to a disk.
- `zdos-<version>-usb-<platform>-<arch>.zip`: the metal or uefi editions for a USB stick or the Pi's SD card. when `rpi4u` is used as arch, it is the arm64 arch that comes with the RPi4's firmware.

The Raspberry Pi 4 firmware (https://github.com/pftf/RPi4) is taken from `../RPi4_UEFI_Firmware`, `$ZDOS_PORTS_SRC/RPi4_UEFI_Firmware` or `build/rpi4u-arm64` (or `zig build dist -Drpi4-firmware=<folder>`). Each stick folder has an `edition.txt` that tells `install.sh` what it holds.

In a release folder the run script runs the image beside it, and `install.sh` installs the files beside it without the edition named. The Metal and UEFI run scripts use the firmware installed with QEMU when there is one, else the copy in `firmware/`, which is copied from the machine that builds the release (`edk2-ovmf`, `edk2-aarch64`). The folders the zips are made from are removed once zipped.

### Running on bare metal

ZDOS boots from a FAT32 USB stick or partition; drive C: may be FAT, ext2 or Minix (V3). Drive C: can be on that USB or disk. To create the boot media:
1. Format a USB stick as FAT32 and mount it. Or, to have C: on its own partition, make two: a FAT32 one (a few MB are enough for the boot files) and one with FAT, ext2 (`mkfs.ext2`) or Minix (`mkfs.minix -3`, or `build/host/mkmfs3` from `zig build mkmfs3`), and mount both.
2. Build the edition (`zig build x86_64` or `./build.sh x86_64`), then run `./install.sh metal-x86_64 /run/media/$USER/ZDOS` (example of a folder where the stick is mounted - use your correct path), or with C: apart `sudo ./install.sh metal-x86_64 /run/media/$USER/EFI /run/media/$USER/ZDOS`. It copies system files and drive C:, replacing files already there. It refuses a boot folder that is not on FAT or is this PC's own EFI System Partition. On ext2 or Minix it makes everything root's, with the modes of the images (it must run as root then); macOS can write FAT only.
3. In the PC's firmware setup, **disable Secure Boot** (ZDOS is not signed), then boot from the stick, usually via the boot menu key (F12, F11, Esc or F8 depending on the manufacturer).
4. You can install ZDOS onto an SSD or HDD by calling `SYS` command and copying applications and all other system files of the ZDOS release to the first Minix V3 or ext2 or FAT (non-ESP) patition which will become drive C:.

For a Raspberry Pi 4, use `./install.sh uefi-rpi4u <card>`; see [docs/ARM64.md](docs/ARM64.md#raspberry-pi-4-also-pi-400-cm4).

---

## Running programs

Type the program's name, optionally with a path and arguments:

```
D:\>demo                       runs DEMO from the current directory, or from a PATH folder
D:\>demo.app                   same
D:\>demo api                   with the argument "api"
D:\>tools\myprog a b           runs D:\TOOLS\MYPROG.APP with arguments "a b"
C:\>d:\tools\myprog            from another drive
D:\TOOLS>..\myprog             relative path
```

- Without an extension, ZDOS tries `.APP`, then `.CMD` and `.BAT`.
- Program names are found in any letter case, even on ext2 and Minix drives, where names are case-sensitive: `posixtest` runs `POSIXTEST.APP`.
- A program given **by name only** (no drive, no folder) is looked for in the current directory first, then in each folder of `PATH` (`C:\APPS` unless changed). Put your programs there to run them from anywhere. With a drive or folder in the name, only that place is searched.
- If a program returns a non-zero exit code, ZDOS shows `Program exited with code N`.
- Files a program left open and memory it did not free are released automatically.
- Each program has its own current drive and directories, starting from those of the program that ran it, as each process has on Unix: a change it makes ends with it (in DOS it stayed). See [CD](docs/COMMAND.md#cd).

### Multitasking
ZDOS provides virtual tabs. These tabs are screens each of which shows a running program.
You can run a program with `&`, e.g. `APP.APP &` and it will be rendered into a new tab. To switch to that tab use **Alt+Tab** or **Win/Cmd+Tab**.
This way you can run multiple programs and switch between them with these keys.

### Preinstalled programs

They are in `\APPS`, which is on the `PATH`, so they run from any directory; see [docs/APPS.md](docs/APPS.md).

Programs from other projects are [ports](ports/README.md), built by their own scripts; each port's README says how to use it.

To write your own programs, see [docs/DEVELOPER.md](docs/DEVELOPER.md).

---

## Usage

### Drives

At startup ZDOS finds FAT12/16/32, Minix V3, ext2 partitions and gives them letters:

- **A:, B:** are floppy drives (BIOS/x86 version), as in DOS. Booted from a floppy, ZDOS starts on A: and runs cammand interpreter from there.
- **C:** is the first non-ESP partition that holds `\APPS` and other system files or the USB stick when ZDOS is booted from one. A boot partition that holds only the boot files, with the system on a second partition gives C: to the partition that has `\APPS`, and gets D: itself. Only if there is no normal partition at all does the ESP become C:.
- **D:, E:, ...** are the other normal partitions, in firmware order.
- **No letter** (`--`): **EFI System Partitions** (other than C:), which hold the boot loaders, and partitions flagged "hidden" or "no drive letter", like Windows recovery partitions. This keeps them from being changed by accident. `DRIVES` lists them; `DISKLET` gives them letters when you need them.

The startup list shows the drives with a letter. `DRIVES` also shows the others and marks the partition ZDOS was started from with `(boot)`, ESPs with `(system)` and flagged partitions with `(hidden)`. Programs only see drives with a letter.

Partitions with other file systems (NTFS, ext4 ...) get no letter; `DRIVES` lists them as not readable.

The metal and BIOS editions read every file system, FAT included, with ZDOS's own drivers.

On UEFI the firmware's FAT driver serves FAT partitions and ZDOS's own drivers the others, through their Block I/O (512-byte sectors). On firmware without the Partition Info protocol (older than UEFI 2.7) ESPs and hidden partitions can not be recognized and get ordinary letters.

USB sticks can be plugged in while ZDOS runs: they get the next free letters (on UEFI at the next look at the drives, on the metal editions at once). A stick pulled out keeps its letters, not ready, and gets them back when plugged in again. On the metal editions `EJECT E:` writes out a stick's data first, so it can be pulled out safely.

An ext2 or Minix drive left in the middle of a change (a crash or power cut while ZDOS was writing, or a disk last used by Linux or Minix and not unmounted) is mounted read only; the startup list says so and names the check: `CHKEXT2 D: -F` or `CHKMFS D: -F` repairs it, and after a restart it's writable again. FAT drives are always writable: run `CHKDSK D:` after a crash.

Type a drive letter and a colon to switch drives: `D:`. Each drive remembers its own current directory, as in DOS.

### Paths

- Both `\` and `/` work as separators: `DOCS\WORK` and `DOCS/WORK` are the same.
- `.` is the current directory, `..` the parent, a leading `\` the root of the drive.
- A path can start with a drive: `E:\OLD.TXT`, or `D:REPORT.TXT` (in D:'s current directory). For POSIX comatibility: `/E:/OLD.TXT` works as `E:\OLD.TXT`.
- On FAT drives names are not case-sensitive: `readme.txt` finds `README.TXT`. On ext2 and Minix drives letter case counts, as on Linux: `readme.txt` and `README.TXT` are two files.
- Names on ext2 and Minix drives may hold any character but `\`, `/` and the 0 byte, as on Unix; names on FAT drives can not hold `" * : < > ? |`. A name that starts with one letter and `:` reads as a drive: write `.\a:b`.
- For programs ported from Unix, `/dev/null` is `NUL`, `/dev/tty` the keyboard and screen, `/dev/stdin`, `/dev/stdout` and `/dev/stderr` the program's standard streams, and `/tmp` (and what is in it) the `TEMP` folder (`C:\TEMP` if other `TEMP` is not set).
- **Quotes are optional.** Everything after a command is taken as the name, so `cd My Folder` works. `COPY` and `MOVE` work with two names as well. Quotes may stand anywhere in a name and are simply left out, as in Windows: `"My Folder"\Sub`, `"C:\My Folder"` and `C:\"My Folder"` are the same.

### The command line

Commands are not case-sensitive; a line can be up to 1023 characters.

- **Left** / **Right** arrow keys move the cursor within the line, **Home** / **End** jump to its start / end.
- **Backspace** / **Delete** delete the character before / at the cursor.
- **Up** / **Down** go through the history (the last 32 commands).
- **Tab** completes the command, program, file or folder name being typed (see below).

Typing inserts at the cursor. Going down past the newest command brings back the line you were typing.

**Tab** completion simply takes the alphabetically first match without alternatives. See more on how it works in the [command reference](docs/COMMAND.md#tab-completion).

### Text and encodings

ZDOS works in UTF-8: the shell, the programs and the file names. File contents are never converted: a file holds the bytes its program wrote.

The editions differ in how text reaches the screen:

- **Metal and UEFI** draw the text themselves with the font (`FONT=`), by Unicode code point, so every character the font has shows; `CODEPAGE=` is ignored.
- **BIOS** shows one byte per character, so the characters are converted with the codepage (`CODEPAGE=`, which also sets the bytes typed and shown). A character the codepage lacks shows as `?`. With `FONT=firmware` the screen is CP437 whatever `CODEPAGE=` says.

Typed text is UTF-8 too, so `echo Текст > file.txt` writes UTF-8 on both. A file in another encoding (CP866 from an old DOS tool) shows `?` where its bytes are not valid UTF-8.

### SYSTEM.CFG

`\CONF\SYSTEM.CFG` on the boot drive holds the system settings: an INI file whose every `NAME=value` becomes a global variable. The settings are in [docs/CONFIG.md](docs/CONFIG.md). `\CONF` folder also contains other configurations files.

### Users

ZDOS has users, groups and Unix-style file permissions: [docs/USERS.md](docs/USERS.md).

### Ctrl+C

As in DOS, **Ctrl+C** stops what is running; `^C` is shown at once:

- **At the prompt** it drops the line being typed and shows a new prompt.
- **Commands** stop at their next step: `TYPE`, `DIR` (also `-s`), `COPY` / `MOVE` / `DEL` / `RD` of many files or of trees. What was done stays done: copied files stay copied, deleted ones deleted. A single big file is copied to the end.
- **A pipe** (`A | B | C`) stops as a whole: the commands after it do not run.
- **Programs** end with ERRORLEVEL 255, closing their files, at their next screen output, key read, input read or wait. A program that started another one ends too, unless it takes Ctrl+C as a key.
- **Programs that use Ctrl+C themselves** (an editor copying text) ask ZDOS for it as an ordinary key; then it does not end them.
- **Batch files** ask `Terminate batch job (Y/N)?`.
- A question (`Overwrite ...? (Y/N)`, `PAUSE`) answered with Ctrl+C counts as no and stops the command.

---

## Feature matrix

ZDOS has three editions: BIOS (x86-32), UEFI (x86-64, ARM64) and Metal (x86-64, ARM64). File systems: FAT12/16/32, ext2/ext3 and Minix V3. Core features: C, C++ and Rust SDKs, networking, multitasking, multiprocessor support, real time, multiple users with permissions, graphics and sound. [•] indicates implemented features.

| Feature                 | BIOS | UEFI | Metal |
| ----------------------- | :-:  | :-:  |  :-:  |
| IDE disks               | [•]  | [•]  |   -   |
| SATA disks              | [•]  | [•]  |  [•]  |
| NVMe disks              |  -   | [•]  |  [•]  |
| USB disks               | [•]  | [•]  |  [•]  |
| USB hot-plug            |  -   | [•]  |  [•]  |
| CD/DVD-ROM              |  -   |  -   |   -   |
| Network                 | [•]  | [•]  |  [•]  |
| Keyboard and mouse      | [•]  | [•]  |  [•]  |
| Key releases            | [•]  |  -   |  [•]  |
| True color graphics     |  -   | [•]  |  [•]  |
| Sound cards             | [•]  |  -   |  [•]  |
| Preemptive multitasking | [•]  |  -   |  [•]  |
| Real time               | [•]  |  -   |  [•]  |
| Tasks on all cores      | [•]  |  -   |  [•]  |
| Paging                  |  -   |  -   |  [•]  |
| CPU faults as signals   | [•]  |  -   |  [•]  |
| Memory protection       |  -   |  -   |   -   |

BIOS and UEFI reach some devices through the firmware rather than their own drivers. UEFI multitasking is cooperative, and other cores run only jobs there.

---

## Further documentation

- [docs/COMMAND.md](docs/COMMAND.md): every command, and batch files.
- [docs/APPS.md](docs/APPS.md): the applications: editor, picture viewer, archivers, demos, scripts.
- [docs/DEVELOPER.md](docs/DEVELOPER.md): writing programs for ZDOS in Zig, C or C++, and how ZDOS is built inside.
- [docs/API.md](docs/API.md): the program API reference.
- [docs/BIOS.md](docs/BIOS.md): the 32-bit edition for old BIOS PCs, and how it boots and drives the hardware.
- [docs/ARM64.md](docs/ARM64.md): the ARM64 edition and the Raspberry Pi 4.
- [docs/ASH.md](docs/ASH.md): the optional Unix-style shell.
- [docs/CONFIG.md](docs/CONFIG.md): the settings in `SYSTEM.CFG`.
- [docs/DRIVERS.md](docs/DRIVERS.md): the hardware ZDOS drives: disks, USB, PS/2, network cards, sound.
- [docs/USERS.md](docs/USERS.md): users, groups and permissions.
- [docs/NETWORK.md](docs/NETWORK.md), [docs/SSH.md](docs/SSH.md), [docs/HTTPZ.md](docs/HTTPZ.md): the network, routing and NAT, the DHCP and DNS servers; SSH; the web server.
- [sdk/README.md](sdk/README.md): the C and C++ SDK, its C library, Rust.
- [ports/README.md](ports/README.md): how ports are laid out and built; each port has its own README.
- [docs/DEVLOG.md](docs/DEVLOG.md): what each version has.
- [docs/TODO.md](docs/TODO.md): what is planned.
- [docs/REALTIME.md](docs/REALTIME.md): how the metal and BIOS editions are real-time, and what was measured.
