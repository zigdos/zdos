# Preinstalled Applications

The applications that come with ZDOS, in `C:\APPS`, and the scripts in `C:\SCRIPTS`. Shell commands and the system and disk tools are in [COMMAND.md](COMMAND.md).

## Contents

[ARP](NETWORK.md#tools)  
[ASH](ASH.md)  
[DEMO](#demo)  
[DEMOC](#democ)  
[DEVICES](#devices)  
[DHCPD](NETWORK.md#dhcp-server)  
[DNSD](NETWORK.md#dns-server)  
[FETCH](NETWORK.md#tools)  
[HTTPTEST](#httptest)  
[HTTPZ](HTTPZ.md)  
[IPCONFIG](NETWORK.md#tools)  
[IRCZ](#ircz)  
[KILO](#kilo)  
[NETSPEED](#netspeed)  
[NETSTAT](NETWORK.md#tools)  
[NETTEST](#nettest)  
[NSLOOKUP](NETWORK.md#tools)  
[PICTVIEW](#pictview)  
[PING](NETWORK.md#tools)  
[PLAY](#play)  
[POSIXTEST](#posixtest)  
[RTLAT](#rtlat)  
[SCP](SSH.md#client)  
[SSH](SSH.md#client)  
[SSHD](SSH.md#server)  
[SSHKEY](SSH.md#client)  
[SSHTEST](#sshtest)  
[TAR](#tar)  
[TERM](#term)  
[VOLUME](#volume)  
[ZC](#zc)  
[ZDLTEST](#zdltest)  
[ZIP](#zip)  
[ZMATRIX](#zmatrix)  
[Scripts:](#scripts)  
 - [archives.sh](#archivessh)  
 - [colortest.cmd](#colortestcmd)  
 - [demoa.sh](#demoash)  
 - [DEMOB.CMD](#demobcmd)  
 - [gcstress.py](#gcstresspy)  
 - [luademo.lua](#luademolua)  
 - [realtime.sh](#realtimesh)  
 - [stest.sh](#stestsh)  
 - [vttest.cmd](#vttestcmd)  

## DEMO

`DEMO [GROUP [ARGUMENTS]]` (`apps/demo.zig`) shows and tests the program API. Alone it opens a menu of its groups; with a group's name it runs that one. Each group works both ways:

- `DEMO API [SECTION...]` tests the API: time, memory, files, screen, programs, system, drives, keyb, tasks, cores, net, sound (all, or the sections named). The exit code is the number of failures. It works in a `DEMOTEST` folder of the current one.
- `DEMO COLORS` shows the 16 colors and the screen; `DEMO TREE` the current folder's tree.
- `DEMO KEYBOARD` shows each key typed (Esc twice ends); `DEMO KEYS` every press and release with its scan code (BIOS and metal editions; Esc ends).
- `DEMO MOUSE` moves the arrow cursor with the mouse in graphics (buttons color the background, the wheel moves a bar; Esc ends).
- `DEMO GFX` shows a 256-color picture until a key, then the frames per second; from the command line it ends without switching back (ZDOS brings the text back). `DEMO RGB` a moving true-color picture at half the screen's size, scaled up; `DEMO RGB 1` at the screen's own size (UEFI and metal editions).
- `DEMO SOUND` plays a tune on the PC speaker (x86), as a square wave, then soft, then as samples on a sound card if a driver found one.
- `DEMO TASKS` runs three counting tasks at once, then shows priority inheritance (the high task waits about as long as the low one's work, not the middle one's).
- `DEMO CORES [N]` computes the Mandelbrot set on one core, then on all (at most `N`), with both times and the picture; both results must be equal.

For its own tests: `DEMO UPPER` (a filter for pipes: input in capitals), `DEMO VAR NAME` (a variable as programs see it), `DEMO CHILD`, `DEMO EXIT` and `DEMO TASK ...`.


## DEMOC

`DEMOC` (`apps/democ.c`): the C side of the API without a C library: each group called at least once, its structs as `zdos.h` lays them out (`DEMO API` tests the behaviour). The exit code is the number of failures; it works in a `DEMOC.TMP` folder.

## DEVICES

`DEVICES`: the CPU (name, speed, cores), the disks and drives, and the network cards.

## HTTPTEST

`HTTPTEST SETUP` (as root): the ZDOS side of `tests/net/httpz-tests.py`, installs the test files from the drive labelled `NETLOG`. As a CGI program it prints its variables, user and request body (see [HTTPZ](HTTPZ.md)).

## IRCZ

`IRCZ [-k] [-p] [-n NICK] [-u USER] [-w PASSWORD] SERVER[:PORT] [#CHAN ...]`: an IRC client, TLS on port 6697; `-p` or port 6667: plain text. `-k`: the certificate isn't checked against `CACERT.PEM`; `-w`: the password for SASL PLAIN (account NICK) and PASS. Tabs: Alt+1..9, Alt+0, Ctrl+N, Ctrl+P or `/win N`; `/help` lists the commands.

## KILO

`KILO [FILE]`: a text editor (kilo, ported to Zig): Ctrl+S saves, Ctrl+Q quits, Ctrl+F finds, Ctrl+C, Ctrl+X, Ctrl+V copy, cut and paste, Ctrl+Z undoes. CRLF line ends are kept. C, C++, shell, Python, Zig, Java, JavaScript, Rust, Lua and batch files are colored by their extension.

## NETSPEED

`NETSPEED [host] [seconds] [send] [recv] [rr] [udp] [pause]`: measures the network against `tests/net/netspeed.py` on `host` (default `10.0.2.2`): TCP's speed both ways, round trips of one byte, and UDP datagrams lost; each test runs `seconds` (default 10); without test names all four run; `pause`: a second between tests. Results also go to `NETSPEED.LOG` on the drive labelled `NETLOG`.

## NETTEST

`NETTEST [host]`: the ZDOS side of `tests/net/net-tests.py`; results go to `NETTEST.LOG` on the drive labelled `NETLOG`, the exit code is the number of failures (see [Network](NETWORK.md#tools)).

## PICTVIEW

`PICTVIEW file`: shows a BMP, GIF, PNG or JPEG picture over the whole screen, made smaller if it doesn't fit. Without true color (BIOS: 320 x 200, 256 colors) a fixed palette, dithered; GIFs and 8-bit BMPs keep their own. Animated GIFs play. Left and right arrows show the previous or next picture in the same folder, Esc ends.

## PLAY

`PLAY file.wav [volume]`: plays a WAV file on the sound card: PCM of 8 to 32 bits or float, mono or stereo, more channels as their first two (24 and 32 bits are played as 16). `volume` sets the volume for every program, as VOLUME. Metal and BIOS editions, with a sound driver.

## POSIXTEST

`POSIXTEST [net [HOST] | net -L [ADDRESS]]` (`apps/posix/posixtest.c`): tests the C SDK's POSIX layer: tasks, threads, signals, pipes, terminals; what an edition lacks is skipped. `net` (lowercase) tests the C library's sockets against `tests/net/net-tests.py`'s servers, `net -L` on the loopback. The exit code is the number of failures.

## RTLAT

`RTLAT [-t THREADS] [-i US] [-l LOOPS] [-p PRIO] [-r] [-a CORE] [-h US] [-q]`: how late periodic wake-ups run, as Linux's cyclictest (see [Real-Time](REALTIME.md)). Times are in microseconds.

- `-t`: threads (1).
- `-i`: the period (1000).
- `-l`: wake-ups per thread (10000; 0: until Ctrl+C).
- `-p`: the priority, 0-31 (28); `-r` RR instead of FIFO.
- `-a`: thread n on core CORE+n.
- `-h`: a histogram with buckets that wide.
- `-q`: only the summary.

## SSHTEST

`SSHTEST SETUP | CLIENT`: the ZDOS side of `tests/net/ssh-tests.py`; files from and results to the drive labelled `NETLOG`, the exit code is the number of failures (see [SSH](SSH.md#server)).

## TAR

`TAR C [-gz] path`, `TAR X [-gz|-xz] archive`: `C` makes `path.tar`, with `-gz` a gzipped `path.tgz`; `X` unpacks `.tar`, `.tgz` / `.gz` and `.txz` / `.xz` into the current folder (chosen by the extension, or by `-gz` / `-xz`). xz is unpack only.

With wildcards (`TAR C -gz DOCS\*.MD`) the matching files go into one `ARCHIVE.TAR` or `ARCHIVE.TGZ` in their folder. Absolute names in an archive (`/home/...`) are unpacked under the current folder.

## TERM

`TERM [font]`: another console in a tab of its own, running the command interpreter (`COMSPEC`) as a VT terminal; Alt+Tab or Win+Tab switches tabs. `font` is one of ZDOS's fonts (`spleen-8x16`, `terminus-12x24` ...). On BIOS 640 x 480 in 16 colors. See [API](API.md#graphics-game-keys-and-mouse-gfxzig).

## VOLUME

`VOLUME [0-100]`: shows or sets the sound card's output volume, for every program.

## ZC

`ZC [FOLDER]`: a two-panel file manager in the manner of Norton Commander. Two folders side by side, files colored by type as in the shells; copying, moving and deleting files and whole folders (merged into ones that exist, with progress; Esc stops), a command line, and the screen of commands under the panels (Ctrl+O). F1 lists the keys. It has a text viewer and nothing else of its own: other files open with the programs `ZC.CFG` names.

`%HOME%\ZC.CFG` is made on the first start. Commands in it run in the panel's folder through the command interpreter; `%f` is the file at the cursor.

- `[options]`: `viewer=` (`internal` or a command, for F3), `editor=` (F4), `frames=` (`auto`, `double`, `single`, `ascii`; `auto` takes single lines or ASCII on BIOS codepages without the frame characters), `humansize=` (sizes in KB, MB, GB), `theme=` (`blue`, `dark`), `textfiles=` (extensions Enter opens in the viewer).
- `[open]`: `EXT,EXT=command`, what Enter runs for a file.
- `[menu]`: `title=command`, F2's entries.

## ZDLTEST

`ZDLTEST`: tests loading a `.ZDL` library with ZCRYPT, then each of its functions against Zig's own crypto; the exit code is the number of failures.

## ZIP

`ZIP C path`, `ZIP X archive.zip`: `C` makes `path.zip` from a file or a folder, `X` unpacks it into the current folder.

With wildcards (`ZIP C *.TXT`) the matching files go into one `ARCHIVE.ZIP` in their folder. Absolute names in an archive (`/home/...`) are unpacked under the current folder.

## ZMATRIX

`ZMATRIX [-u]`: fills the screen with falling green characters, as cmatrix; any key ends it. `-u` adds katakana, math and block characters, if the font has them.

## Scripts

The scripts in `C:\SCRIPTS` (from `scripts/`), besides `AUTOEXEC.CMD` ([Batch files](COMMAND.md#batch-files)) and `ashrc.sh` ([Ash](ASH.md)).

### archives.sh

ZIP and TAR (also `-gz`) round trips (`ash /C:/SCRIPTS/archives.sh`): a folder packed, unpacked elsewhere, its files compared. Exit code 1 if any failed.

### colortest.cmd

Shows all the ANSI colors, see [ANSI colors](COMMAND.md#ansi-colors).

### demoa.sh

A self test of ash, module by module (`ash /C:/SCRIPTS/demoa.sh`), exit code 1 if any failed, see [Ash](ASH.md#tests).

### DEMOB.CMD

A self test of the batch interpreter: prints `[OK]` or `[FAIL]` per test, the exit code is the number of failures. Don't press keys while it runs.

### gcstress.py

A MicroPython garbage collector stress test (`MICROPYTHON C:\SCRIPTS\GCSTRESS.PY [rounds]`), see [its README](../ports/coding/micropython/README.md).

### luademo.lua

Checks the Lua port (`LUA C:\SCRIPTS\LUADEMO.LUA`), see [its README](../ports/coding/lua/README.md).

### realtime.sh

The real-time measurement: RTLAT alone, then under disk copies, DEMO graphics, HTTP over the loopback and all at once (`ash realtime.sh [THREADS] [SECONDS] [PRIORITY] [FOLDER]`; RTLAT's priority, 28 by default), see [Real-Time](REALTIME.md).

### stest.sh

A small file system stress test (`ash stest.sh`): writes 1000 files into `bulk` in the current folder.

### vttest.cmd

Tests the VT100 cursor and erase sequences (needs `TERM=vt100`), see [ANSI colors](COMMAND.md#ansi-colors).
