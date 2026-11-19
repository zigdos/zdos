# ZDOS TODO List

## Kernel and system
- [ ] Improve real-time performance.
- [ ] Memory protection, simplified - under question.
- [ ] `fork` for forking servers (after memory protection).
- [ ] Per-task variables.
- [ ] Smaller stacks, for mcrocontroller editions.
- [ ] Random bytes from ZDOS where the CPU has no RDRAND.
- [ ] Timezones support.
- [ ] ACPI power off and restart on Metal and BIOS without APM.
- [x] Shared library code (partial).
- [ ] Virtual consoles and terminals (tty).
- [ ] Serial ports for programs (`COM1`), with the UART's interrupt.
- [ ] Event queue filters - under question.
- [ ] BIOS: Run DOS programs and games on the real CPU - under question.
- [ ] Run programs compiled for some other OS.
- [ ] `GROUPADD`, `GROUPDEL`.
- [ ] Real and retro hardware tests: Pentium II / III / IV; ARM64; network cards, HDA codecs, USB hubs.

## Screen and input
- [ ] Graphical user interface.
- [ ] Freetype fonts.
- [x] VESA modes on BIOS.
- [ ] Keyboard layouts: Japanese (input method), Hebrew and Arabic (right-to-left).
- [ ] USB hubs and hot-plugging check on real hardware.

## Audio
- [ ] Several programs mixing (music in a background tab); sound for Doom.
- [ ] virtio-sound (ARM64 on QEMU); ES1370 / ES1371, Trident.
- [ ] HDA on real machines (Realtek ALC: jacks, amplifiers, quirks).
- [ ] Sound recording.

## Disks and file systems
- [ ] Cache sizes in SYSTEM.CFG - under consideration.
- [ ] Robust filesystem caching - under consideration.
- [ ] 4Kn disks (4096-byte logical sectors).
- [ ] exFAT, read and write.
- [ ] ISO 9660 with Joliet and Rock Ridge, read only, with ATAPI for real drives.
- [ ] ZFS filesystem simplified support.
- [ ] GPT disk (partition) editor in FDISK (or GDISK).
- [ ] SD cards (Raspberry Pi).

## Network
- [ ] IPv6.
- [ ] RPi 4's GENET.
- [ ] RTL8169 interrupts on real cards tests.
- [ ] Sockets as standard streams.
- [ ] Virtio and Amazon ENA driver tests on Cloud VMs and EC2 instance.
- [ ] DHCP leases kept across restarts, IP_PKTINFO / `recvmsg` for C programs.
- [ ] DNS over TCP.
- [ ] NAT as a firewall, hairpin NAT.
- [ ] Multiple default routers (`LWIP_HOOK_IP4_ROUTE_SRC`); `choose_default()` on link changes.
- [ ] IPCONFIG / NETSTAT showing NAT's table and the leases.
- [ ] A promiscuous switch for drivers' cards, ICMP redirects and network unreachable, a spanning tree.
- [ ] Improve speed and robustness of network stack.
- [ ] More cards: PCnet, Intel 8255x, 3c905, eepro100, etc.
- [ ] HTTPZ: RSA keys, HTTP/2, gzip on free cores, longer variables for CGI.
- [ ] Wi-Fi support.

## Apps and SDK
- [ ] NetSurf: SVG; uploads and downloads - GUI Pickers.
- [x] File locks between programs (SQLite too).
- [ ] SQLite: WAL (shared memory).
- [ ] `SDL2.ZDL` testing.
- [ ] TinyGL / PortableGL: several cores, a 16-bit TinyGL for BIOS, PortableGL demos: nuklear or models - under question.
- [ ] FFmpeg: text subtitles in ffplay (libass, FreeType), encoders.
- [ ] DOSBox: MIDI device, x86, arm64 and the recompilers check.
- [ ] MicroPython build folder as for other ports; now builds inside its repo.
- [ ] Quake II (yquake2) - under question.
- [ ] From Minix / BSD: curses, terminfo, nvi, less, more; tr, tee, seq, paste, join, split, fold, fmt, column, comm, cmp, rev, nl ... as ash built-ins or programs; bzip2, xz, libarchive, libedit.
- [ ] C:`setjmp` saving FPU control state; file creation and access times.
- [ ] C++: `std::filesystem` with ZDOS paths, a tz database, smaller programs (`iostream`).
- [ ] Console in event queues and `socketpair` (Rust terminal programs) - under question.
- [ ] QuickJS-ng with web server and database clients (SQL, Mongo, Redis).
- [ ] File manager: terminal and GUI.
- [ ] MPlayer or other player.
- [ ] Graphical text editors or word processors.
- [ ] Spreadsheets app.
- [ ] Picture editor.
- [ ] PDF viewer.
- [ ] Antivirus.

## Platforms
- [ ] RISC-V UEFI edition.
- [ ] RISC-V Metal edition.
- [ ] ESP32 mini edition.
- [ ] STM32 mini edition.
