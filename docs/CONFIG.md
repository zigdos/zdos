# SYSTEM.CFG

`\CONF\SYSTEM.CFG` on the boot drive holds the system settings. ZDOS reads it once at startup, after setting its startup variables ([SET](COMMAND.md#set)) and before `AUTOEXEC.CMD` ([Batch files](COMMAND.md#batch-files)). It is an INI file:

```ini
# ZIGDOS system-wide configuration
[Display]
TERM=vt100
[System]
KEYB=EN,ES,FR
```

Every `NAME=value` line becomes a global variable, so batch files and programs see it (`%TERM%`, `getenv("TERM")` in C, `zdos.getVar` in Zig). `[Section]` lines only group the settings. Lines starting with `#` or `;` are comments; spaces around `=` are allowed, and a value may be in double quotes. An empty value (`KEYB=`) sets nothing, as `SET KEYB=` would. `KEYB=` lists the keyboard layouts loaded at startup, the first one active (`EN` if empty or none is known; see [KEYB](COMMAND.md#keyb)). `AUTOEXEC.CMD` can change the variables afterwards. A line ZDOS can't use is reported at startup with its number.

## Shell

`SHELL` or `COMSPEC` names another command interpreter (`SHELL=D:\TOOLS\MYSHELL.APP`, as in DOS's `CONFIG.SYS`); if both are set, the later line counts. ZDOS starts it without switches (`-p` and `-d` are COMMAND.APP's) and sets `COMSPEC` and `SHELL` to its path. One is included: [Ash](ASH.md), a Unix-style shell with grep, sort and awk.

## Screen and text

`FONT=` picks the text font from `SYSTEM\FONTS`: `firmware` (the default), or `spleen` or `terminus`, optionally with a size such as `terminus-16x32` (default 8x16). On UEFI and metal ZDOS draws the text itself in that size, so a bigger font gives fewer columns and rows; the BIOS text screen ignores the size. A font that can't be loaded results in the firmware's font.

`CODEPAGE=` (BIOS only, with a `FONT=` other than `firmware`) picks which character each byte is, from `SYSTEM\FONTS\<CODEPAGE>.zcp`: CP437, CP737, CP850, CP852, CP855, CP857, CP860-CP863, CP865, CP866, CP1251, CP1252, KOI8-R. The font and codepage files are made by `tools/make-fonts.py` and `tools/make-codepages.py`.

`TERM` sets how the screen treats [escape sequences](COMMAND.md#ansi-colors): `zdos` (the default) shows ANSI colors only, `vt100` adds cursor movement and erasing. It is read at startup; changing it later with `SET` doesn't switch the mode.

`SERIAL=` (metal editions) is the serial console: `on` (default) mirrors the screen there and takes keys from it, `out` only mirrors (keys aren't looked for there, so a machine without a PS/2 controller waits for keys without waking), `off` leaves the port alone. Without a screen it stays `on`. Read from C: before leaving the firmware, like `RESOLUTION=`.

`PS2INPUT=` (metal x86_64) is the PS/2 keyboard and mouse: `auto` (default) uses them if they answer at startup and otherwise never polls them, `on` uses them without asking, `off` leaves the controller alone. Read before leaving the firmware, like `SERIAL=`.

`RESOLUTION=` (UEFI and metal editions) picks the screen mode: a size the firmware offers (`RESOLUTION=1280x800`; `SCREEN` lists them) or `max`. Without it the firmware's mode stays. The metal editions read this setting from C: before leaving the firmware, since only the firmware switches modes. BIOS ignores it.

`CLSONSTART=true` clears the screen before the `ZDOS Version` banner (messages about `SYSTEM.CFG` itself stay). Anything else keeps the startup messages visible (useful for kernel debugging).

**Scrollback**: lines that leave the top of the screen are kept, `SCROLLBACK=64KB` of them by default (as UTF-8 text with their colors, without trailing blanks; `SCROLLBACK=1MB` keeps more, `0` none). The mouse wheel and Shift+PgUp / Shift+PgDn move through them, Shift+Home goes to the oldest and Shift+End back; `[-N]` at the top right shows how far back, and any other key returns. New output meanwhile doesn't move the view. `CLS` clears the history. Full-screen programs (KILO, TOP, ZMATRIX, and remote ones in SSH such as `vim`) use the alternate screen, `ESC[?1049h`: the scroll keys and the wheel are theirs there, and the screen before them comes back when they end. Off during graphics and for programs reading the mouse or key presses. On UEFI only with ZDOS's own font (`FONT=` other than `firmware`).

## Mouse

`MOUSESPEED=` scales the mouse's movement for programs, in percent: `MOUSESPEED=150` moves the pointer half as far again, `MOUSESPEED=50` half as far (10-1000, default 100). On metal a USB mouse may move faster or slower than a PS/2 one; this evens it out. It is read on every call, so `SET MOUSESPEED=` changes it at once.

## Memory, cores and real time

`PAGING=` (metal editions only) sets the page size of ZDOS's own page tables: `PAGING=4096`, and on ARM64 also `16384` or `65536` where the CPU has them. Anything that isn't a number (`PAGING=firmware`) keeps the firmware's page tables. Without it: 4096 on x86_64; on ARM64 16384 where the CPU has it, else 4096. BIOS and UEFI ignore it.

`RW_NX=true` (metal x86_64, with ZDOS's own page tables) keeps code and data apart: no memory is both writable and executable. Programs', libraries' and drivers' code becomes read-only, while data, stacks and the heap are never executed, so injected bytes can't be run as code. Default false. Programs built with the compact linker scripts (`*-compac.ld`) keep today's mapping.

`CORES=` (metal, and BIOS where the BIOS left the local APIC on) sets how many CPU cores run tasks; calls into ZDOS take turns. Default: all but the network's own core; `CORES=1` runs every task on core 0. UEFI runs tasks on core 0.

`ISOLCPUS=2,3` (or `2-5`) keeps tasks off those cores unless they ask for them (CPUSET, `sched_setaffinity`), for real-time work; core 0 can't be.

`RTHEAP=16M` takes a pool at startup from which programs' memory comes first, in constant time ([Real-Time](REALTIME.md)).

`IRQPRIO=` (default 30) is the priority of the task IRQ, which does what devices' interrupts leave for later.

## Sound

`VOLUME=` (0-100, default 80) is the sound card's output volume at startup; `VOLUME` changes it later.

## Files and users

`TEMP=` names the folder for temporary files, which POSIX programs see as `/tmp` (`C:\TEMP` if unset).

`LOGIN=true` asks who is there before starting the command interpreter, see [Users](USERS.md). `HOSTNAME=` names the machine (default `zdos`), for LOGIN's prompt, C's `uname` and `gethostname`, and SSHKEY's key comment.

`FATOWNER=` (default `true`) makes up owners and modes on a FAT system drive, which keeps none: `\USERS\<name>` for that user, `\CONF\SHADOW.CFG` for root, and so on (see [Users](USERS.md)). `FATOWNER=false` leaves the whole drive open to every user, as other FAT drives are, also the passwords' file. It is read once at startup, so a program changing the variable changes nothing. Drives with Minix or ext2 keep their own owners either way.

## Network and services

`NETWORK=true` starts the network at boot (see [Network](NETWORK.md); without a card: the loopback, 127.0.0.1, alone), in a `[Network]` section: `IPV4=DHCP` (or no `IPV4=`) gets the address by DHCP; `IPV4=192.168.1.50` sets it, with `NETMASK=` (default 255.255.255.0) and `ROUTER=` (the gateway); `DNS=` names up to 8 DNS servers (`DNS=1.1.1.1,8.8.8.8`), which replace DHCP's. Names in `\CONF\HOSTS.CFG` (`ADDRESS NAME [ALIASES]` per line) are looked up before DNS.

`\CONF\SERVICES.CFG` lists programs ZDOS starts in the background at boot, as root: `SSHD=true` starts the [SSH](SSH.md) server, whose settings are in `\CONF\SSHD.CFG`; `HTTPZ=true` the [web server](HTTPZ.md) (`\CONF\HTTPZ.CFG`); `DHCPD=true` and `DNSD=true` a router's [DHCP and DNS servers](NETWORK.md#dhcp-server) (`\CONF\DHCPD.CFG`, `\CONF\DNSD.CFG`). Their output is dropped; each writes a log only if its file's `LOG=` names one.
