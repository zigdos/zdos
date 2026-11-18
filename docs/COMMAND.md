# ZDOS Commands and Batch Files

The commands of ZDOS's command interpreter `COMMAND.APP`, the system and disk tools, and how to write batch files. Applications (the editor, archivers, demos) are in [APPS.md](APPS.md); for installing and using ZDOS, see the [README](../README.md).

Most commands are built into `COMMAND.APP`. Those marked *(program)* are `.APP` programs in `C:\APPS`.

The disk tools (`CHKDSK`, `CHKMFS`, `CHKEXT2`, `FORMAT`, `MKE2FS`, `MKMFS3`, `FDISK`, `SYS`, `DISKLET`) are for root only, since they work on the disk's sectors, past every file's permissions; so is setting a label (see [Users](USERS.md)).

## Contents

[ADDUSER](USERS.md#commands)  
[ATTRIB](#attrib)  
[CALL](#call)  
[CD](#cd)  
[CHKDSK](#chkdsk)  
[CHKEXT2](#chkext2)  
[CHKMFS](#chkmfs)  
[CHOICE](#choice)  
[CLS](#cls)  
[COMMAND](#command)  
[COMP](#comp)  
[COPY / CP / XCOPY](#copy--cp--xcopy)  
[CPUSET](#cpuset)  
[DATE](#date)  
[DEL / RM / ERASE](#del--rm--erase)  
[DELUSER](USERS.md#commands)  
[DIR / LS](#dir--ls)  
[DISKLET](#disklet)  
[DRIVES](#drives)  
[ECHO](#echo)  
[EJECT](#eject)  
[EXIT](#exit)  
[FC](#fc)  
[FDISK](#fdisk)  
[FIND](#find)  
[FINDSTR](#findstr)  
[FORMAT](#format)  
[HELP](#help)  
[ID](USERS.md#commands)  
[KEYB](#keyb)  
[KILL](#kill)  
[LABEL](#label)  
[LOGIN](USERS.md#commands)  
[MD / MKDIR](#md--mkdir)  
[MEM](#mem)  
[MKE2FS](#mke2fs)  
[MKFILE](#mkfile)  
[MKMFS3](#mkmfs3)  
[MORE](#more)  
[MOVE / MV / REN](#move--mv--ren)  
[PASSWD](USERS.md#commands)  
[PATH](#path)  
[PAUSE](#pause)  
[PS](#ps)  
[RD / RMDIR / DELTREE](#rd--rmdir--deltree)  
[REBOOT](#reboot)  
[RTPRIO](#rtprio)  
[SCREEN](#screen)  
[SET](#set)  
[SHUTDOWN](#shutdown)  
[SORT](#sort)  
[SU](USERS.md#commands)  
[SUDO](USERS.md#commands)  
[SYS](#sys)  
[TOP](#top)  
[TYPE / CAT](#type--cat)  
[USERMOD](USERS.md#commands)  
[VER](#ver)  
[VOL](#vol)  
[WAIT](#wait)  
[WHERE](#where)  
[WHOAMI](USERS.md#commands)  
[X:](#x)  
[Terminal:](#terminal)  
 - [ANSI colors](#ansi-colors)  
 - [Tab completion](#tab-completion)
 - [Background tasks](#background-tasks)  
 - [Names with spaces in COPY and MOVE](#names-with-spaces-in-copy-and-move)  
 - [Redirection and pipes](#redirection-and-pipes)  
 - [Running programs](#running-programs)  
 - [Wildcards](#wildcards)  
[Batch files](#batch-files)  
 - [Arithmetic](#arithmetic)  
 - [Differences from DOS](#differences-from-dos)  

## ATTRIB

`ATTRIB [+-RASH] [path]` *(program)*

Shows or changes the attributes of files and directories:

- `R`, read-only: can't be changed or deleted.
- `A`, archive: set whenever the file is written ("changed since the last backup").
- `S`, system: can't be renamed or moved (protects the boot files `ZIGDOS.SYS` and `BOOTX64.EFI`).
- `H`, hidden: not listed by `DIR` and not deleted by `DEL` / `RD` (unless `-a` or `-a:h`).

```
C:\>attrib zigdos.sys
A  SHR     C:\ZIGDOS.SYS
C:\>attrib +r +h docs\report.txt
C:\>attrib -a *.txt
```

- `+X` sets an attribute, `-X` clears it; several can be given (`+R +H`, also `+RH`), before or after the path. Without them, the attributes are shown.
- It is **never recursive**: on a directory it shows or changes that directory's own attributes, not those of what is inside (`ATTRIB +H DOCS` hides `DOCS`; its files keep theirs).
- [Wildcards](#wildcards) select several entries; without a path (or with the root, which has no attributes of its own), `ATTRIB` works on the entries of that directory, one level.
- For a whole tree, go over the full paths `DIR -s -b` lists, with [`FOR -f`](#batch-files): `FOR -f %%f IN ('DIR DOCS -s -b') DO ATTRIB +R "%%f"` (at the prompt `%f`).
- The UEFI firmware's FAT driver sets the archive bit of a directory whenever it changes one of its attributes, so `-A` doesn't stick on directories in the UEFI versions.

## CALL

`CALL file [args]`: runs another batch file, or any command, and continues afterwards. Starting a batch file without `CALL` returns too (see [Differences from DOS](#differences-from-dos)).

## CD

`CD [path]` (`CHDIR`): shows or changes the current directory.

```
C:\>cd docs\work
C:\DOCS\WORK>cd ..
C:\DOCS>cd \
C:\>cd
C:\
```

- With no argument it shows the current directory.
- `CD..` and `CD\` (without a space) also work, as in DOS.
- `CD E:\X` changes E:'s current directory and switches to E: (DOS stays on the current drive); `CD E:` alone only shows E:'s current directory.
- Each program has its own current directories and drive, starting from those of the program that ran it (as each process has on Unix): a program's `CD` doesn't change COMMAND's after it ends (on DOS it did). A batch file runs inside COMMAND, so its `CD` stays.

## CHKDSK

`CHKDSK X: [-F|-A]`, `CHKDSK [disk [partition] [-F|-A]]` *(program)*: checks a FAT12, FAT16 or FAT32 volume and, with `-F`, repairs it. It reads the sectors directly, so it also checks volumes that can't be mounted.

```
C:\>CHKDSK D:                  checks drive D:
C:\>CHKDSK D: -F               checks and repairs it
C:\>CHKDSK                     lists the disks
C:\>CHKDSK 1                   lists disk 1's partitions
C:\>CHKDSK 1 2 -F              checks and repairs partition 2 of disk 1
```

- `<disk> <partition>`: also for volumes without a letter. On MBR the four primary entries come first, then the logical partitions (an extended partition has a number of its own); on GPT the entry slots, as Linux numbers them. A disk with no partition table is partition 1.
- Without `-F` nothing is written. `-F` asks before repairing, then checks again.
- `-A`: repairs without asking (for `AUTOEXEC.CMD`). A drive with a letter is then restarted after 10 seconds (a key cancels), unless problems remain.
- After repairs on a drive with a letter, CHKDSK offers a restart: programs may have files open on it.

**Checked:** the two FAT copies match; FAT entries stay inside the volume; each chain ends where the file's size says; clusters used twice (cross-links); clusters no file reaches (lost); FAT32's free count in FSInfo; long-name entries without their short entry (orphans). Folders at any depth. Clusters marked bad are counted and left alone.

**Repaired by `-F`:** FAT 2 is copied from FAT 1; a broken or too long chain is cut and the size set to match; of a cross-link the first owner keeps the clusters, the other's data goes to a `.CHK` file (a folder's entries to `FOUND.000\DIRnnnn`); lost chains become `FOUND.000\FILEnnnn.CHK` (`FOUND.001` ... if taken); FSInfo's count is set; orphan long names are deleted.

- Copy the disk before `-F`: repairs write to it directly.
- The disk ZDOS started from can be repaired too. If ZDOS won't start, start it from another disk and repair from there.
- Files are named by their short names (`MYLONG~1.HTM`).
- Limits: 512-byte sectors; long-name checksums aren't checked; lost files' names and sizes aren't recovered.

## CHKEXT2

`CHKEXT2 X: [-F|-D|-A]`, `CHKEXT2 [disk [partition] [-F|-D|-A]]` *(program)*: checks an ext2 volume (ext3 too, when its journal is clean), and with `-F` repairs it; see [CHKMFS](#chkmfs), which works the same way.

## CHKMFS

`CHKMFS X: [-F|-D|-A]`, `CHKMFS [disk [partition] [-F|-D|-A]]` *(program)*

`CHKMFS` checks a Minix 3 volume, `CHKEXT2` an ext2 volume (ext3 too, when its journal is clean). They work like [CHKDSK](#chkdsk): the same command line (`X:`, or disk and partition, and `-F`; `-D` is theirs alone, below; `-A` as CHKDSK's), the same `Y/N` question, the second check after a repair and the restart question, and exit code 0 only when nothing is wrong. Their checks follow Minix's fsck.mfs and NetBSD's fsck_ext2fs.

```
C:\>CHKEXT2 D:
Checking the ext2 volume of drive D:
1024 bytes per block, 16384 blocks, 4096 inodes, 2 groups
  inode 13 (file, 70000 bytes) is in no folder: -F links it into \lost+found as #13
  the superblock says 1234 free blocks and 4038 free inodes, counted 12165 and 4038 (set)
...
```

**What is checked:** the superblock; every inode's block (zone) pointers: inside the volume, and no block used twice; the folders from the root: `.` and `..`, entries that name unused or damaged inodes, a second link to a folder, damaged ext2 records; inodes in use that no folder names; link counts; the block and inode maps; ext2's free counts in the superblock and the group descriptors, and its inodes' block counts; ext2's backup superblocks and descriptors (Minix has none): their sizes, UUID and table places must be the primary's; the clean flag.

**What `-F` repairs:** maps, free counts, link counts and block counts are set from what the check found; bad entries are removed (after a damaged ext2 record, the rest of its block: the files it named then go to `\lost+found`); a wrong `.` or `..` is set; a pointer outside the volume is cleared (when an inode has more than 8 of them, nothing of it is changed); a lost file or folder is linked into `\lost+found` as `#inode` (made when missing); an inode no folder names and with no links left is freed, as are ext2 inodes of an unknown type and Minix inodes not in use that weren't cleared; of a block used by two files (cross-linked), the file found second gets its own copy, of an indirect block with all it names, so both stay where they are (what that file held there is lost: its copy has the other file's data); backup superblocks that differ are rewritten from the primary; the volume is marked clean when everything was fixed.

**`-D`** repairs as `-F` does and also deletes the files no repair can save, so nothing is left unfixed and the volume is clean (writable) again: an inode whose block pointers are garbage (more than 8 outside the volume), and a cross-linked file when there is no room for its copy. Their own blocks are freed, blocks they shared stay with the other file, a deleted folder's files go to `\lost+found`. Without `-D` such files are listed with `(-D deletes this file)`. The root folder and ext2's reserved inodes (the journal ...) are never deleted.

**`-A`** does what `-D` does without asking, then restarts, as `CHKDSK -A`: for unattended runs.

**Not checked (the volume is left alone):** ext2 features ZDOS's driver doesn't have (ext4's extents, 64-bit, checksums, `uninit_bg` ...), a journal that needs recovery, an orphan list; Minix block sizes other than 1024 to 4096 bytes, and zones larger than blocks.

## CHOICE

`CHOICE [-c keys] [-n] [-cs] [-t:key,seconds] [-m text | text]`

Asks for one key and sets `ERRORLEVEL` to its position in the list (1 for the first), as DOS's `CHOICE`:

```
C:\>choice -c ync Save changes
Save changes [Y,N,C]?N                       ERRORLEVEL is now 2
```

- `-c keys` (also `-c:keys`): the keys to choose from (default `YN`).
- `-n`: don't show `[Y,N]?`.
- `-cs`: letter case counts (`y` and `Y` are different keys).
- `-t:key,seconds`: take `key` if nothing is pressed in time (DOS 6's form): `-t:N,10`.
- `-m text`: the text (or simply the words after the switches).

Other keys are ignored. In a batch file, test the highest number first: `IF ERRORLEVEL 3 (...) ELSE IF ERRORLEVEL 2 (...) ELSE ...`.

## CLS

`CLS`: clears the screen, and the scrollback (see [SYSTEM.CFG](CONFIG.md)).

## COMMAND

`COMMAND [-c line]` *(program)*

The command interpreter, `C:\APPS\COMMAND.APP`. ZDOS starts it after booting; it shows the drives, runs `AUTOEXEC.CMD` (see [Batch files](#batch-files)) and shows the prompt. It can be started again:

```
C:\>command                 a second command interpreter; EXIT returns to the first
C:\>command -c dir *.txt    runs one command line, then ends with its ERRORLEVEL
```

- `-c line`: run the line and end; the exit code is the `ERRORLEVEL` afterwards. Programs run commands this way (`run_command`, `system()` in C).
- `-p`: permanent, the first one, started by ZDOS. `EXIT` doesn't end it; it shows the drives and runs `AUTOEXEC.CMD`.
- `-l`: a login shell, started by `LOGIN.APP` (see [Users](USERS.md)): runs `AUTOEXEC.CMD` (not with `-d`), then `%HOME%\LOGIN.CMD` if there is one; `EXIT` logs out.
- `-a`: runs `AUTOEXEC.CMD` and ends (`LOGIN.APP` runs it so at startup, as root).
- `-d`: with `-p`, without `AUTOEXEC.CMD` (ZDOS starting it again after it ended).

Should it end, ZDOS starts it again (`COMMAND -p -d`); if it is missing or damaged, ZDOS asks for its path. Another command interpreter can be set in [SYSTEM.CFG](CONFIG.md).

## COMP

`COMP file1 file2`: compares bytes: each difference with its offset (hex) and both bytes, at most 10. Files of different sizes aren't compared.

It sets `ERRORLEVEL`: 0 the same, 1 different, 2 an error.

## COPY / CP / XCOPY

`COPY [-y] [-a|-a:h] from to`, `COPY CON file`

Copies a file, or a directory with all its files and subdirectories.

- If the destination is an **existing directory**, the source is copied **into** it: `COPY README.TXT DOCS` creates `DOCS\README.TXT`.
- Otherwise the destination is the **new name**: `COPY DOCS BACKUP` creates `BACKUP` as a copy of `DOCS`.
- Copying over an existing file asks `Overwrite ...? (Y/N)` (answer + **Enter**); `COPY -y` overwrites without asking (DOS's `/Y`). Copying a directory onto an existing directory merges them.
- It works between drives (`COPY D:\DOCS E:\`).
- Copying a directory into itself is refused.
- With a [wildcard](#wildcards), every match is copied into the destination, which must be an existing directory: `COPY *.TXT E:\`. Hidden matches (attribute `H`) are skipped, as by `DEL`, and `COPY` says how many: `-a` copies them too, `-a:h` only them. A hidden file named without a wildcard (`COPY SECRET.TXT E:\`) is copied, and a copied directory always takes everything inside it, hidden entries included.
- Copied files keep their modification date; directories get the time of copying. Attributes aren't copied: a new file gets the archive bit. An overwritten file keeps its own attributes on BIOS and metal, and starts fresh on UEFI (the firmware replaces it). A read-only destination can't be overwritten.
- A single file only gets the count; with a wildcard or a directory, each file is listed, then the count:

```
D:\>copy *.txt e:\
D:\LETTER.TXT
D:\NOTES.TXT
2 file(s) copied
```
- `COPY CON file` creates a text file from what you type, as in DOS: type the lines (each ended with Enter), then **Ctrl+Z** or **F6**, which shows `^Z`; text typed before it on that line is kept. Ctrl+C cancels, and nothing is written. Lines get DOS line ends (`\r\n`); an existing file is only replaced after asking (`COPY -y CON file` doesn't ask). With `< file` or a pipe the input is copied instead, up to its end or a Ctrl+Z character:

```
C:\>copy con notes.txt
First line
Second line^Z
1 file(s) copied
```

## CPUSET

`CPUSET -c LIST PROGRAM [ARGS]`, `CPUSET -p [-c LIST] ID` *(program)*: runs or changes a task on the cores in LIST (`2,3`, `1-3`), Metal.

## DATE

`DATE [new]`: shows or sets the date and time (setting: admins only).

```
C:\>date
Current date is Sun 2026-10-11
Current time is 09:40:50
Enter new date and time (yyyy-mm-dd hh:mm[:ss][am|pm])
  or simply press enter: 2025-12-24 09:15
```

- Press **Enter** to keep the current values, or type new ones. Invalid input is rejected and asked again.
- `DATE value` sets it directly, without asking.
- Accepted formats: `2025-12-24 14:30` (24-hour), `2025-12-24 2:30pm` or `2:30 PM` (12-hour), `2025-12-24` (date only, time unchanged), `23:59` (time only, date unchanged), `23:59:30` or `11:59:30pm` (with seconds).
- With `am`/`pm` the hour must be 1–12; `12:05am` is 00:05 and `12:00pm` is 12:00.
- Seconds are optional; a time without them sets the seconds to 0.
- The clock is the PC's hardware clock, so the change survives a reboot on a real PC.

## DEL / RM / ERASE

`DEL [-a|-a:h] [-q] path`

Deletes a file, or a directory **including everything inside it**. No switches are needed, but it always asks first:

```
D:\>del docs
Delete D:\DOCS? (Y/N) y
```

Type `Y` (or `YES`) and press **Enter** to confirm; anything else cancels. Deleting the root directory is refused. If you delete the directory you are in, the current directory moves to its parent.

With a [wildcard](#wildcards) it deletes every match, files and directories, after one question:

```
D:\>del *.tmp
Delete 3 file(s) and 1 dir(s) matching D:\*.tmp? (Y/N) y
```

**Hidden entries** (attribute `H`, see [`ATTRIB`](#attrib)) are left alone, as in DOS, and `DEL` says how many it kept. A directory that is deleted still goes with everything inside it, hidden entries included.

- `-a` deletes hidden entries too.
- `-a:h` (or `-ah`) deletes only hidden ones: `DEL -a:h DOCS\*`.

```
D:\>del docs\*
Delete 4 file(s) matching D:\DOCS\*? (Y/N) y
1 hidden file(s) or dir(s) kept; use -a to delete them too
D:\>del secret.txt
D:\secret.txt is hidden (use -a)
```

Read-only entries are never deleted (clear `R` with `ATTRIB` first). `DEL -q` deletes without asking (for batch files).

## DIR / LS

`DIR [-a|-a:h] [-w] [-b] [-s] [-o[:]keys] [-p] [path]`

```
D:\>dir
 Volume in drive D is DATA
 Directory of D:\
2026-10-11  08:41  <DIR> DOCS
2026-10-11  08:41  <DIR> My Folder
2026-10-11  08:41     29 LETTER.TXT
2026-10-11  08:41  2,048 NOTES.TXT
 2 File(s), 2,077 bytes
 2 Dir(s), 65,891,328 bytes free
```

`DIR` lists the current directory, `DIR path` another one (`DIR E:`, `DIR ..\X`). Directories come first, then files, each sorted by name without regard to case. With a [wildcard](#wildcards) only matching entries are listed: `DIR *.TXT`, `DIR C:\APPS\*.APP`. A file name lists just that file (`DIR NOTES.TXT`). If nothing matches, `DIR` says `File not found`, as in DOS.

Entries with the hidden attribute ([`ATTRIB +H`](#attrib)) are left out; system files are listed. Switches (DOS's, written with `-`), before or after the path:

- `-a`: all entries, hidden ones too.
- `-a:h` (or `-ah`): only hidden entries (`DEL` and `RD` take `-a` / `-a:h` too).
- `-w`: wide: names only, in columns; folders as `[NAME]`.
- `-b`: bare: names only, one per line, no header and totals; with `-s` full paths (handy for pipes and `FOR`).
- `-s`: also every folder below, each with its own totals, and `Total files listed` at the end.
- `-o[:]keys`: sorted: `N` name, `E` extension, `S` size, `D` date and time, `G` folders first; `-` before a key reverses it (`-o:-S` biggest first, `-o:D` oldest first). Without `-o`, and with `-o` alone, it is `-o:GN`: folders first, then names. Entries equal in every key keep the order they are stored on the disk.
- `-p`: page by page (the same as `| MORE`).

```
D:\>dir -o:-s *.txt          biggest text files first
D:\>dir \ -s -b > all.txt    every file of the drive, one full path per line
```

The totals count only the entries listed.

On the screen, names are colored: folders always light blue; programs and batch files (`.APP`, `.CMD`, `.BAT`, `.EXE`, `.SH`) light green; files with the system attribute yellow; files with the archive attribute (set on new and changed files, see [`ATTRIB`](#attrib)) light red. When more than one applies, the first in this order wins. `DIR -p` keeps the colors, as `MORE` shows them; into a file or another pipe (`DIR > LIST.TXT`, `DIR | MORE`) `DIR` writes plain text, like `ls` on Unix.

## DISKLET

`DISKLET` *(program)*: gives every drive without a letter (`--`) one, after the highest letter in use, and shows the list:

```
C:\>disklet
Drives:
  C:  ZDOS        FAT32        62 MB
  D:  DATA        ext2         62 MB
  E:  EFI         FAT16        62 MB   (boot)   (system)
  F:  RECOVERY    FAT16        15 MB   (hidden)
```

The letters last until ZDOS restarts. Use it to work on an EFI System Partition or a hidden partition, e.g. to update `\EFI\BOOT\BOOTX64.EFI`; careful, they hold other systems' boot and recovery files. Exit code 0 when it gave letters, 1 when every drive had one.

## DRIVES

`DRIVES` *(program)*: lists the drives like the startup screen, plus the ones without a letter (`--`), with their file system:

```
C:\>drives
Drives:
  C:  ZDOS        FAT32        62 MB
  D:  DATA        ext2         62 MB
  --  EFI         FAT16        62 MB   (boot)   (system)
  --  RECOVERY    FAT16        15 MB   (hidden)
  --              NTFS        120 MB   (not readable)
```

Partitions no driver reads (NTFS, ext4 ...) are listed as `(not readable)`, with what they seem to hold; they never get a letter.

On UEFI, USB sticks plugged in since the last listing are added, and a removed stick or a card taken out of a reader shows `(no disk)`; it keeps its letter for when it comes back.

On the metal editions a USB stick plugged in gets its letters at once (`USB: E: (FAT32, 7.5 GB)` on the screen); pulled out, its drives are not ready (`USB: E: removed`) and keep their letters: plugged in again (the same stick, by its vendor, product and serial number), it gets them back. Files still open there give errors. See [EJECT](#eject).

## ECHO

`ECHO text`, `ECHO.`, `ECHO ON|OFF`

Prints everything after it, spaces included. `ECHO.` prints an empty line. `ECHO OFF` / `ECHO ON` set whether [batch files](#batch-files) show their commands; `ECHO` alone shows the setting. To print `>` or `|`, quote it: `echo "a > b"` (the quotes are printed too).

```
C:\>echo Hello world
Hello world
C:\>echo first line > notes.txt
C:\>echo second line >> notes.txt
C:\>type notes.txt
first line
second line
```

## EJECT

`EJECT X:` *(program)*: writes out what ZDOS holds back for a USB stick's drives and lets it go, so it can be pulled out safely; it refuses while a file is open for writing there, and for the disk ZDOS runs from. Metal editions (see [DRIVES](#drives)).

## EXIT

`EXIT [code]`: leaves the batch file it is in (`EXIT 3` also sets the exit code, see `ERRORLEVEL`). At the prompt of a second command interpreter ([COMMAND](#command)) it ends that one, returning to where it was started (`EXIT 3`: with exit code 3). The first one, which ZDOS started, can't be left: there it only says to use `SHUTDOWN`.

## FC

`FC [-i] file1 file2`: compares two text files line by line. For each place where they differ it shows both files' lines, with the matching line before and the one where they match again, as DOS's FC does; `-i` ignores letter case. A difference may be up to 100 lines long before the files are counted as matching again.

It sets `ERRORLEVEL`: 0 the same, 1 different, 2 an error.

## FDISK

`FDISK [disk] [-MBR]` *(program)*: makes, changes and deletes the partitions of an MBR disk. BIOS edition only.

- `FDISK`: lists the disks.
- `FDISK <disk>`: the disk's partitions and a menu: `1` create (primary, extended, or logical inside the extended one), `2` make a primary partition active, `3` delete (a logical one before its extended partition), `4` list, `0` exit.
- `FDISK <disk> -MBR`: writes ZDOS's boot code to the MBR, keeping the table and the disk signature; also on the disk ZDOS started from. A disk that is one FAT, NTFS or exFAT volume (no partition table) is refused.
- Numbered as [CHKDSK](#chkdsk), [FORMAT](#format) and [SYS](#sys) number them: the primary slots, then the logical partitions. Partitions start on megabyte boundaries, a logical one's boot record a megabyte before it; primary and extended ones start below 2 TB.
- Changes are written at once. A new partition's first sector is cleared: it gets a letter once formatted. A deleted one loses its letter.
- The menu refuses GPT disks and the disk ZDOS started from.

## FIND

`FIND [-v] [-c] [-n] [-i] "text" [file ...]`

A filter: it reads the files named, or its input (`DIR | FIND "TXT"`, `FIND "x" < LIST.TXT`), a line at a time, and prints what it finds. File names may have wildcards (`*.TXT`).

`FIND "text"` prints the lines that contain the text (quotes needed only around spaces; a quoted `"-x"` is text, not a switch). With files, each starts with `---------- NAME`, as in DOS.

- `-v`: the lines without the text.
- `-c`: only how many lines.
- `-n`: line numbers: `[3]text`.
- `-i`: any letter case.

FIND sets `ERRORLEVEL`: 0 when a line was found, 1 when none was, 2 on an error, for batch files: `FIND "error" LOG.TXT > NUL` then `IF ERRORLEVEL 1 ECHO no errors`.

```
C:\>dir | find "TXT"
```

## FINDSTR

`FINDSTR [-v] [-c] [-n] [-i] [-l] pattern [file ...]`

`FINDSTR pattern` works like grep: the pattern is a small regular expression. With more than one file (or a wildcard) each line starts with its file's name (`NOTES.TXT:line`). It reads files or its input as [FIND](#find) does; switches as for FIND, plus `-l` (only the names of the files with a match); `-n` gives `3:line`.

In a pattern:

- `.` matches any character.
- `[abc]`, `[a-z]` match one of them, `[^0-9]` none of them.
- `*`, `+`, `?` after something: it any number of times, at least once, at most once.
- `^` and `$` are the start and the end of the line.
- `a|b` is either (the whole pattern; quote it, or `|` makes a pipe).
- `\x` is x itself: `\.` a dot, `\*` a star.

Characters are bytes: `.` matches half of `ä`, and `-i` knows only A-Z.

It sets `ERRORLEVEL` as [FIND](#find) does.

```
C:\>findstr -n "^[0-9]+ " *.log
C:\>findstr -i -l "todo|fixme" src\*.zig
```

## FORMAT

`FORMAT` *(program)*: makes a new, empty FAT file system on a partition or a floppy.

```
FORMAT X: [-T 12|16|32] [-C bytes] [-L label] [-F]
FORMAT <disk> <partition> [-T 12|16|32] [-C bytes] [-L label] [-F]
```

- `<disk> <partition>`: as `CHKDSK <disk>` lists them, also for partitions without a letter; a disk with no partition table is partition 1. On GPT, the entry slots (`MKE2FS <disk>` lists them).
- `-T`: the FAT type. Without it, FAT12 up to 2 MB, FAT16 where its cluster count fits, else FAT32. A type that doesn't fit the partition is refused.
- `-C`: the cluster size, 512 to 32768 bytes, a power of two; without it, from the volume size.
- `-L`: the label, up to 11 characters.
- `-F`: a full format: every sector is zeroed first, so the old files can't be recovered. Without it only the file system's own areas are written, and the ext2 and ZFS signatures cleared.
- Refused: the drive ZDOS started from, extended partitions, a partition past the end of the disk, volumes over 2 TB. An EFI system partition gets a warning first.
- Afterwards the partition's type is FAT's (MBR `01`, `06`, `0C`; GPT "Microsoft basic data"); an EFI system partition keeps its type.
- Floppies: 160 KB to 2.88 MB, in their standard geometry; a blank one works too.
- Not bootable afterwards: `SYS` does that.
- UEFI: restart ZDOS afterwards, since the firmware keeps its file system caches.

## HELP

`HELP`: lists the commands.

## KEYB

`KEYB [-l | EN,ES,FR]` *(program)*

Shows and sets the keyboard layouts.

- `KEYB` shows the active layout, the loaded layouts (the active one marked) and the available ones.
- `KEYB -l` lists the available layouts, one per line.
- `KEYB EN,ES,FR` loads these layouts now, the keys are typed with the first, and asks `Save KEYB=EN,ES,FR in C:\CONF\SYSTEM.CFG (Y/N)?`. Y rewrites that file: its `KEYB=` line in `[System]` is replaced (or added there); every other line and comment stays as it is.

`KEYB -l` lists the layouts (`EN`, `DE`, `FR`, `RU` ...). Each is a `<NAME>.ZKB` file in `SYSTEM\KEYB` on the boot disk (`EN` is also built in), made by `tools/make-keyb.py` from the X11 keyboard definitions.

On UEFI the firmware reports US keys, and ZDOS types the active layout's character at that place; AltGr combinations don't come through there.

The characters show on UEFI whatever the codepage; on BIOS they need a `CODEPAGE=` that has them (`CP866` for Russian), else `?` (see [Text and encodings](../README.md#text-and-encodings)).

**Switching the layout:** **Ctrl + Space** goes to the next loaded layout; on BIOS **Left Alt + Shift** too (UEFI doesn't report it). AltGr is left alone, since it types characters such as `@` on DE.

**Dead keys:** on most of these layouts some keys are dead: they type nothing alone, and the next letter gets the accent (`´` then `e` gives `é`, `^` then `o` gives `ô`, `¨` then `u` gives `ü`). Pressed twice, or before a letter that does not take the accent, the accent is typed alone (then the letter).

At startup `KEYB=` in `SYSTEM.CFG` loads the layouts (see [SYSTEM.CFG](CONFIG.md)). A name ZDOS does not have is left out with the message `KEYB=XX is not available: left out`; if none is known, `KEYB=XX is not available: using EN`.

## KILL

`KILL [-SIGNAL | -s SIGNAL] TASK...` *(program)*: sends a signal to tasks; SIGNAL is a number (`-9`) or a name (`-KILL`, `-SIGKILL`), default TERM. `KILL -l` lists the signals. Only your own tasks (root: any).

## LABEL

`LABEL X: [label]` *(program)*: sets or removes a drive's label; without one it shows the label and asks for a new one.

```
C:\>label d: backup          sets the label of D: (stored in capitals)
C:\>label c:                 shows C:'s label and asks for a new one; Enter alone
                             offers to remove it
```

- At most 11 characters, none of `* ? . , ; : / \ | + = < > [ ] "`; letters in capitals. BIOS: only code page 437 characters. UEFI: the firmware's FAT driver drops spaces (`MY DISK` gives `MYDISK`).
- Stored in the root directory; the boot sector's copy isn't changed.

## MD / MKDIR

`MD path`: creates one directory. The directories leading to it must already exist.

## MEM

`MEM` *(program)*

Shows the CPU and the memory:

```
C:\>mem
CPU                 GenuineIntel Pentium II (family 6, model 5, stepping 2)
CPU speed           about 400 MHz
CPU cores           1
Total memory           65,023 KB
Free memory            63,156 KB
Largest free block     63,156 KB
```

- **CPU** from `CPUID` on x86, the core's name on ARM; **CPU speed** (x86 only) from the time stamp counter, the nominal clock.
- **Free memory** is what programs can get, the **largest free block** the most one allocation can get.

## MKE2FS

`MKE2FS` *(program)*: makes a new, empty ext2 file system.

```
MKE2FS X: [-b size] [-L label]
MKE2FS <disk> <partition> [-b size] [-L label]
MKE2FS <disk>
```

- `MKE2FS <disk>` lists the partitions: on MBR the four entries, then the logical ones; on GPT the entry slots, as Linux numbers them. A disk with no partition table is partition 1. Partitions without a letter are given this way.
- `-b`: the block size, 1024 to 65536 bytes, a power of two; without it 1024 below 512 MB, else 4096. Linux mounts up to 4096.
- `-L`: the label, up to 16 bytes.
- Features: `filetype`, `sparse_super`, `large_file`; 256-byte inodes, one per 4 KB below 512 MB, else per 16 KB.
- Refused: the drive ZDOS started from, extended partitions. Afterwards the partition's type is Linux (MBR `83`, GPT "Linux filesystem data").

## MKFILE

`MKFILE file`: creates one empty file, like `MD` for directories: `MKFILE my notes.txt`. The directories leading to it must already exist, and nothing with that name may exist yet.

## MKMFS3

`MKMFS3 X: [-b size] [-i inodes]`, `MKMFS3 <disk> <partition> [...]`, `MKMFS3 <disk>` *(program)*: makes a new, empty Minix V3 file system; destroys what was there.

- `-b`: 1024, 2048 or 4096 (the default) bytes per block.
- `-i`: the number of inodes.
- `MKMFS3 <disk>` lists the partitions.

## MORE

`MORE file`, `command | MORE`, `MORE < file` *(program)*

Shows text a screen at a time, with scrolling. `DIR -p` and `TYPE -p` run it too.

```
C:\>more readme.txt          (a file)
C:\>more < readme.txt        (the same)
C:\>dir | more               (the output of any command or program)
C:\>dir -p                   (the same: DIR and TYPE take -p)
```

- **Down** / **Enter**: one line down; **Up**: one line up.
- **PgDn** / **Space**: one page down (Space on the last page ends MORE); **PgUp** / **B**: one page up.
- **Home** / **End**: start / end.
- **Q** / **Esc**: back to the prompt (the page stays on the screen).

The bottom line shows where you are (`-- MORE -- rows 25-48 of 310 (15%)`). Text that fits on one screen is just printed. Long lines wrap at a blank, so words are not cut (only a word longer than the screen is). [ANSI colors](#ansi-colors) are shown, also when scrolling back. With MORE's own output redirected, the text passes through unchanged.

## MOVE / MV / REN

`MOVE [-y] [-a|-a:h] from to`

Renames or moves a file or directory.

- Into an existing directory: `MOVE REPORT.TXT DOCS`.
- Rename: `MOVE OLD.TXT NEW.TXT`.
- Within a drive it is an instant rename. Between drives it copies, then deletes the original.
- Moving a file onto an existing file asks `Overwrite ...? (Y/N)` (answer + **Enter**), as `COPY` does; `MOVE -y` replaces it without asking (DOS 6.22's `/Y`). An existing folder is never replaced: moving onto one is refused.
- Changing only the capitalization works: `MOVE readme.txt Readme.txt`.
- With a [wildcard](#wildcards), every match is moved into the destination, which must be an existing directory: `MOVE *.TXT DOCS`. For matches whose name already exists there, it asks for each file. Hidden matches stay where they are, as with `COPY`: `-a` moves them too, `-a:h` only them. A moved directory always takes everything inside it.
- With a wildcard it lists each moved entry, then `N file(s) moved` (or `N file(s) and M dir(s) moved`); a single one only gets the count. A single directory moved to another drive is listed as by `COPY`.

## PATH

`PATH [dir;dir]`

`PATH` holds the folders (separated by `;`, or by `:` as on Unix: `/C:/APPS:/C:/GAMES`; a drive's colon doesn't split) where commands are looked for after the current directory. ZDOS starts it as `C:\APPS` (the boot drive's `\APPS`); the test disks' `AUTOEXEC.CMD` adds `C:\GAMES`. A `PATH=` line in [SYSTEM.CFG](CONFIG.md) would replace ZDOS's value, as any setting there becomes a variable.

```
C:\>path                    shows it:  PATH=C:\APPS;C:\GAMES
C:\>path c:\apps;d:\tools   sets it (the same as SET PATH=...)
C:\>path ;                  clears it: only the current directory is searched
```

## PAUSE

`PAUSE`: shows "Press any key to continue . . ." and waits for a key.

## PS

`PS` *(program)*: the running tasks: number (as `KILL`, `WAIT` and `getpid` use it), parent, priority, state, CPU time, program.

## RD / RMDIR / DELTREE

`RD [-a|-a:h] [-y] path`: like `DEL`, but only for directories, so a mistyped name can't delete a file. The directory doesn't have to be empty (as with `DELTREE`). No wildcards. A hidden directory needs `-a`; `-y` deletes without asking.

## REBOOT

`REBOOT` *(program)*: restarts the computer, as the reset button does; admins only.

## RTPRIO

`RTPRIO -f|-r PRIORITY PROGRAM [ARGS]`, `RTPRIO -d RUNTIME DEADLINE PERIOD PROGRAM [ARGS]` *(program)*: runs a program with a scheduling policy: FIFO, RR (priorities 0-31, default 16) or earliest deadline first (times in microseconds). `-p ID` instead of the program changes a running task; `RTPRIO -p ID` alone shows its policy (see [Real-Time](REALTIME.md); `RTLAT` measures it, see [APPS.md](APPS.md#rtlat)).

## SCREEN

`SCREEN` *(program)*: lists the screen modes the firmware offers, smallest first, and shows the one in use in brackets (`[1280x800]`), in four columns. Any of them can go into `RESOLUTION=` in `SYSTEM.CFG` (see [SYSTEM.CFG](CONFIG.md)). The Metal editions record the list at startup, before leaving the firmware; UEFI asks the firmware each time. BIOS lists 320x200, 640x480 and the VESA BIOS's modes; in brackets the one programs get for the whole screen, the largest true-color mode up to 1024x768 (`RESOLUTION=` has no effect there).

## SET

`SET [name=value]`, `SET -p name=prompt`, `SET -a expression` ([Arithmetic](#arithmetic))

```
C:\>set name=Ann            sets a variable (names are not case-sensitive)
C:\>echo Hello %name%       %NAME% is replaced by its value, also at the prompt
Hello Ann
C:\>set                     lists all variables
C:\>set na                  lists those starting with NA
C:\>set name=               removes it
C:\>set -p name="Your name: "
Your name: Bob              asks; Enter alone keeps the old value
```

Variables set at the prompt or in `AUTOEXEC.CMD` are **global**; only admins may set them (see [Users](USERS.md)). Each batch file has its own scope: see [Batch files](#batch-files). Programs see the variables too (the global ones, and those of the batch file that started them).

Variables ZDOS sets itself at startup (`AUTOEXEC.CMD` may change them; with `LOGIN=true` each login starts again from the variables as `AUTOEXEC.CMD` left them):

- `PATH`: `C:\APPS`.
- `PLATFORM`: which ZDOS this is: `METAL`, `UEFI` or `BIOS`; `ARCH`: the CPU, `x86_64`, `arm64` or `x86` (zdos-cc's names). Always ZDOS's own, whatever `SYSTEM.CFG` says.
- `USER`, `LOGNAME`, `HOME`: the user (`ROOT`, unless [SYSTEM.CFG](CONFIG.md) sets them) and the home folder (`C:\USERS\ROOT`); `LOGIN.APP` sets them for each user.
- `COMSPEC`: the command interpreter, `C:\APPS\COMMAND.APP`; `SHELL` the same in POSIX form, `/C:/APPS/COMMAND.APP`, for programs ported from Unix.
- `TERM`: the console mode, `zdos` or `vt100` (from `SYSTEM.CFG`, see below; `zdos` without it).

`ERRORLEVEL` (unless set) is the last exit code of a program, `EXIT n` or `CHOICE`. As in DOS, it belongs to the command interpreter: it isn't a variable programs see. COMMAND.APP also makes three variables when they are used (`%CD%`, `IF DEFINED CD` ...): `CD` the current folder (`C:\DOCS`), `DATE` today's date (`2026-10-16`, as `DATE` shows it) and `TIME` the time (`14:05:09`). Like `ERRORLEVEL` they belong to the command interpreter, `SET` doesn't list them, and a variable set with the same name hides them.

```
C:\>echo Backup of %CD% on %DATE% at %TIME%
C:\>copy notes.txt notes-%DATE%.txt
```

## SHUTDOWN

`SHUTDOWN` *(program)*: turns the computer off (in QEMU, QEMU closes); admins only.

## SORT

`SORT [-r] [file]`: prints the lines in order, letters without regard to case, as DOS does (`apple` and `Apple` stay in the order they came in); `-r` the other way round. It reads one file (no wildcards) or its input, and keeps all lines in memory.

```
C:\>type names.txt | sort > sorted.txt
```

## SYS

`SYS X: [-O]` *(program)*: makes a drive bootable. `-O`: no questions; existing files (another system's fallback file too) are replaced in place, without a temporary copy.

**BIOS version:** writes ZDOS's boot code into the FAT volume's boot sector (its BPB kept) and copies `ZIGDOS.SYS` from the boot drive.

- The MBR and the active partition aren't changed: the partition must be the active one (`FDISK`). `build/bios-x86/mbr.bin` is ZDOS's MBR.
- Refused: GPT disks; volumes starting beyond 2 TB; FAT12/16 without the extended BPB (DOS 3 and older); FAT32 whose reserved sectors 2 and 8 aren't free. `FORMAT` it again.

**Metal and UEFI versions:** copy the file ZDOS was started from (`\EFI\BOOT\BOOTX64.EFI`, `\EFI\ZDOS\ZIGDOS.EFI` ...; `BOOTAA64.EFI` on ARM64):

- An EFI system partition gets `\EFI\ZDOS\ZIGDOS.EFI`, and `\EFI\BOOT\BOOTX64.EFI` if that is free; an existing one is replaced only after asking.
- Any other disk (a USB stick) gets `\EFI\BOOT\BOOTX64.EFI`.
- The boot drive needs a letter: run `DISKLET` first.
- On an EFI system partition, SYS adds a firmware boot entry `ZDOS` for `ZIGDOS.EFI`, first in the boot order; if the firmware refuses it, choose the file in its boot menu.

A file is copied under a temporary name first, so a failed copy leaves the old one working. Only the boot files are copied: the programs (`\APPS`, `COMMAND.APP`) and settings (`\CONF`) must be copied too.

## TOP

`TOP [seconds]` *(program)*: the tasks, busiest first, with their share of the CPU and the free memory, refreshed every `seconds` (default 1); Q or Esc ends it. CPU shares: metal editions.

## TYPE / CAT

`TYPE [-p] file`: prints a text file. Both Windows (`\r\n`) and Unix (`\n`) line endings display correctly. Control characters in binary files are shown as `.`, except ESC: [ANSI colors](#ansi-colors) in the file are shown as colors. `TYPE -p file` shows it page by page, the same as `MORE file`.

## VER

`VER [file]` *(program)*: shows the ZDOS version, or a program's, library's or driver's own version and the ABI version it was built for.

## VOL

`VOL [X:]` *(program)*: shows the label, the serial number, the file system, its block size (a FAT cluster, an ext2 or Minix block) and the space: total, used (with the percentage) and available, in bytes and in KB, MB, GB or TB.

```
C:\>vol d:
 Volume in drive D is DATA
 Volume Serial Number is DFC8-8DD5
 File system is FAT32
 Block size is 4096 bytes

 Total      2,145,386,496 bytes  (2.0 GB)
 Used         861,175,808 bytes  (821.3 MB, 40%)
 Available  1,284,210,688 bytes  (1.2 GB)
```

## WAIT

`WAIT [n]`: waits for task `n`, or for all started with `&`; `WAIT n` sets `ERRORLEVEL` to its exit code.

## WHERE

`WHERE name`: shows what typing the name runs, and what else has that name further on: a built-in command first (it always wins), then the program or batch file found in the current folder, then in each `PATH` folder. A program with a built-in's name runs only with its path (`\APPS\FIND`), or with its extension: `FIND.APP` (also `.CMD`, `.BAT`) is never a built-in, it is looked for as a file.

```
C:\>where find
FIND: built-in command
C:\>where more
C:\APPS\MORE.APP
```

## X:

`X:`: switches to drive X, to its current directory (see [CD](#cd)).

## Terminal

How the command line behaves: running programs, wildcards, redirection, colors.

### ANSI colors

Text printed to the screen may contain ANSI color sequences, as with ANSI.SYS in DOS: `ESC [ 31 m` switches to red, `ESC [ 0 m` back to normal. ESC is the character 27 (0x1B); in a batch file it has to be in the file itself, as the editor writes it. This works for `ECHO`, `TYPE` and every program (a C `printf`, a MicroPython `print`).

- `0` (or nothing): normal, light gray on black.
- `1` / `22`: bright text on / off (colors 30-37 become 90-97).
- `7` / `27`: reverse (text and background swapped) on / off.
- `30`-`37`: text in black, red, green, yellow, blue, magenta, cyan, white; `90`-`97` bright text in the same order.
- `40`-`47`: background in the same order; `100`-`107` (bright) give the same 8.
- `39` / `49`: normal text / normal background.
- `38;5;n` / `48;5;n`: text / background from the 256-color palette, shown as the nearest of the 16.
- `38;2;r;g;b` / `48;2;r;g;b`: text / background as RGB, shown as the nearest of the 16.

Several codes can be combined: `ESC [ 1;33;44 m` is yellow on blue.

With `TERM=vt100` (set in [SYSTEM.CFG](CONFIG.md); the test disks have it) these work too:

- `ESC [ n A` / `B` / `C` / `D`: cursor up / down / right / left by n (default 1).
- `ESC [ n E` / `F`: n lines down / up, to the first column.
- `ESC [ row ; col H` (or `f`): cursor to row, column (counted from 1; alone: top left).
- `ESC [ n G` / `ESC [ n d`: cursor to column n / row n.
- `ESC [ n J`: erase: `0` (or nothing) to the end of the screen, `1` to its start, `2` all.
- `ESC [ n K`: erase: `0` (or nothing) to the end of the line, `1` to its start, `2` the whole line.
- `ESC [ s` / `ESC [ u`, `ESC 7` / `ESC 8`: save / restore the cursor position.
- `ESC [ ? 25 l` / `h`: hide / show the cursor.
- `ESC c`: reset: normal colors, screen cleared, cursor shown and at the top left.

Erasing fills with the current background color, except the bottom-right cell. Scroll regions and inserting or deleting lines are not supported. Unknown sequences are left out, not shown as stray characters. In a file or pipe the sequences are kept unchanged. Colors stay until changed; when a program ends, ZDOS resets them. `C:\SCRIPTS\COLORTEST.CMD` shows all the colors, `C:\SCRIPTS\VTTEST.CMD` the cursor and erase sequences.

### Tab completion

It takes the **alphabetically first** match and never lists alternatives.

- It completes the word at the cursor. Words are split at blanks, with quotes grouping, and at `|`, `<` and `>`.
- For the first word of a command (also after `|`) it completes a command name (`di` -> `dir`), otherwise a folder, program (`.APP`) or batch file (`.CMD`, `.BAT`) in the current directory, otherwise one in a `PATH` folder.
- Every later word is completed as a file or folder name, also the second name of `COPY` / `MOVE` and the file after `>` or `<`: `copy readme.txt Do` becomes `copy readme.txt Docs\`. For `CD`, `MD` and `RD` only folders. Folders get a `\` so you can continue (`type docs\in` becomes `type docs\INFO.TXT`). Switches (`-s`) are left alone.
- A name with blanks is put in quotes, closed before a final `\` so you can keep typing: `cd My Fo` -> `cd "My Folder"\`, then `Su` -> `cd "My Folder\Sub Dir"\`. Typing `My Fo` without quotes works: if the last word alone matches nothing, the last two (three ...) words are tried as one name.

### Background tasks

`program args &`: runs a program as a task in the background; its number is shown. Pipes work: `a | b | c &` runs each program as a task, joined by pipes. Not with batch files or built-in commands. A task that ends is reported before the next prompt.

### Names with spaces in COPY and MOVE

Quotes are optional here too. Without them, ZDOS finds where the source name ends by checking which part of the line is an existing file or directory; with quotes, the first blank outside them ends it:

```
D:\>cp My Folder Backup Dir         (works if "My Folder" exists and "My" doesn't)
D:\>cp "My Folder" "Backup Dir"     (quotes always work)
```

If more than one split matches (for example both `My` and `My Folder` exist), ZDOS asks for quotes instead of guessing.

### Redirection and pipes

As in DOS, the output of any command or program can go to a file, and one command can read another's output:

- `command > file` writes the output to the file, replacing it.
- `command >> file` adds the output to the end of the file.
- `command < file`: the command reads the file (`MORE`, and programs that read input).
- `cmd1 | cmd2`: `cmd2` reads `cmd1`'s output; more than two work too: `TYPE A.TXT | DEMO UPPER | MORE`.
- `command > NUL` throws the output away (`NUL` is the device that is nowhere, also `NUL:`, any case); `< NUL` gives empty input.
- `command 2> file`, `2>> file`: the command's error output (programs that print errors there, such as C programs' `stderr`) to a file; `2>&1` sends it where the output goes; `2> NUL` throws it away. Per command, also in pipes and with `&`.

```
C:\>dir \apps > list.txt
C:\>help | more
C:\>echo one more line >> notes.txt
C:\>demo upper < notes.txt
C:\>find "error" log.txt > nul
```

- The commands run **one after another**, as in DOS: `cmd1` runs to the end with its output kept in memory, then `cmd2` reads it. A pipe of programs ending in `&` runs them at the same time instead (see [Background tasks](#background-tasks)).
- Questions (`Delete ...? (Y/N)`) and what you type always appear on the screen, also while the output goes to a file.
- COMMAND's own messages are part of the output, as in DOS: `DIR X > list.txt` puts "File not found" into the file. Programs that use the error output (C programs' `stderr`, POSIX tools) keep their errors on the screen while their output is redirected, as on Unix.
- While the output is redirected, screen control does nothing: `CLS`, and programs' colors and cursor positioning.
- Redirected output is written as printed, with Unix line ends (`\n`). File names may contain spaces without quotes; `|`, `<` and `>` inside quotes are just text (`echo "a > b"`).
- `<` can only be used on the first command of a line, `>` / `>>` only on the last.

### Running programs

`name [args]`: runs a program or a batch file, from the current directory or a `PATH` folder (see [Running programs](../README.md#running-programs), [PATH](#path), [WHERE](#where), [Batch files](#batch-files)). With `&` at the end it runs as a background task ([Background tasks](#background-tasks)).

### Wildcards

`DIR`, `DEL`, `COPY`, `MOVE` and `ATTRIB` accept wildcards in the **last part** of the (source) path:

- `*` matches any characters, also none: `*.TXT`, `REPORT*`, `*` (everything).
- `?` matches exactly one character: `FILE?.TXT` matches `FILE1.TXT`, not `FILE10.TXT`.

Matching ignores case, as in DOS, on every drive (on ext2 and Minix drives too, where names themselves are case-sensitive: `DEL *.TXT` also matches `report.txt`). Patterns match directories too, so `DEL *` empties the current directory completely (after asking). `.` and `..` never match.

## Batch files

A batch file (`.CMD` or `.BAT`) is a text file with commands, run line by line like DOS's batch files. Start it by name like a program: `BACKUP a b` runs `BACKUP.CMD` (or `.BAT`) with `%1` = `a`, `%2` = `b`.

`AUTOEXEC.CMD` (or `.BAT`) is COMMAND.APP's startup script: the first COMMAND.APP runs `SCRIPTS\AUTOEXEC.CMD` beside its own folder, `C:\SCRIPTS\AUTOEXEC.CMD` for `C:\APPS\COMMAND.APP`. It runs after [SYSTEM.CFG](CONFIG.md) is read, and the variables it sets are global. With `LOGIN=true` it runs once at startup, as root, before the first login; each user's `%HOME%\LOGIN.CMD` runs at their login (see [Users](USERS.md)). The one in `scripts/` adds `C:\GAMES` to `PATH`. Other command interpreters have their own (Ash: `ashrc.sh`).

```bat
@ECHO OFF
REM The name of the file is %0, its arguments %1 ... %9, all of them %*
# a comment too
SET -p who="Your name: "
IF "%who%" == "" (
    ECHO Nobody there
    EXIT 1
) ELSE IF -i "%who%" == "ann" (
    ECHO Hello again, Ann
) ELSE (
    ECHO Hello %who%
)
IF NOT EXIST C:\BACKUP MD C:\BACKUP
FOR %%f IN (*.TXT) DO COPY %%f C:\BACKUP
FOR %%i IN (apple banana cherry) DO ECHO Fruit: %%i
SET n=
FOR DO (
    SET n=%n%x
    IF "%n%" == "xxx" BREAK
)
CALL OTHER.CMD %1
PAUSE
```

- `@ECHO OFF`, `@`: by default each command is shown (with the prompt) before it runs, as in DOS. `ECHO OFF` stops that, `@` hides one line; `ECHO` alone shows the setting.
- `REM ...`, `# ...`: comments.
- `%0`, `%1` ... `%9`, `%*`: the batch file's name as typed, its arguments (`"quoted text"` is one argument), all arguments. `SHIFT` makes `%1` the new `%0`, `%2` the new `%1` ... (for more than nine arguments).
- `%NAME%`: a variable; an unknown one is empty. `%%` is a single `%`.
- `IF [-i] [NOT] cond cmd`: `cond` is `EXIST file` (also with wildcards), `DEFINED name`, `a op b`, or `ERRORLEVEL n`; comparisons are numeric when both values are numbers, otherwise text (`-i` ignores case).
- `... ELSE cmd`, `ELSE IF ...`: on one line, or after `)` on the line closing a block.
- `( ... )`: a block of lines after `IF`, `ELSE` or `DO`; also on one line: `IF EXIST X (ECHO yes) ELSE (ECHO no)`.
- `FOR %%x IN (list) DO cmd`: for each item of the list (separated by spaces, `,` or `;`); items with `*` / `?` are replaced by the matching files (not folders, not hidden ones). At the prompt write `%x` instead of `%%x`.
- `FOR -L %%x IN (from,step,to) DO cmd`: numbers: `(1,1,5)` is 1 to 5, `(10,-2,0)` counts down; DOS's `FOR /L`.
- `FOR -f %%x IN (files) DO cmd`: each line of the files (DOS's `FOR /F`); `IN ('command')` each line the command prints (it runs first; pipes work: `'DIR -s -b | MORE'`); `IN ("text")` the text itself, once. Unlike DOS, a line isn't split at spaces, so a path with spaces stays one value; empty lines are skipped.
- `FOR DO cmd`: repeats until `BREAK`, which leaves the innermost `FOR`.
- [CALL](#call), [EXIT](#exit), [PAUSE](#pause), [CHOICE](#choice): other batch files, leaving, waiting and asking.

### Arithmetic

`SET -a` computes signed 64-bit integers. Each comma-separated item is an assignment (`SET -a 1+2` is an error), run left to right. In an expression a variable is its bare name (`N`); `%N%`, `%1` and FOR variables work too; unset or non-numeric counts as 0. At the prompt it prints the last value.

```text
SET -a N=N+1
SET -a X=(A+B)*2
SET -a N+=1
SET -a A=1, B=A*2
```

Operators: `+`, `-`, `*`, `/` (truncated toward zero), `%` (remainder; `%%` in a batch file, as in Windows NT), parentheses, unary `-` / `+`, and `+=`, `-=`, `*=`, `/=`, `%=`. After an operand `%` is always the operator: write `X+%1`, not `X %1`. Division by zero and overflow are reported.

`IF` compares with DOS's names (`EQU`, `NEQ`, `LSS`, `LEQ`, `GTR`, `GEQ`) or `==`, `!=`, `<`, `<=`, `>`, `>=`:

```text
IF %N% GEQ 10 ECHO Ten or more
IF %N% >= 10 ECHO Ten or more
IF NAME == Ann ECHO Hello Ann
```

### Differences from DOS

- **No `GOTO` and no labels**: blocks in `( )`, `ELSE IF` and `FOR DO ... BREAK` take their place.
- **At most 64 levels of `IF` / `FOR` inside each other** (an `ELSE IF` counts as one more level). Deeper nesting is refused when the file is read, before anything runs: `Syntax error in X.CMD, line N: Blocks nested too deeply (more than 64 IF / FOR levels)`. Batch files starting batch files go 16 deep.
- **Variables are replaced when a command runs**, not when its block is read: inside a `FOR` or `IF` block, `%X%` is always the current value (no "delayed expansion" needed).
- **Starting another batch file always returns** to the next line, with or without `CALL` (in DOS, without `CALL` it never came back).
- **Each batch file has its own variables.** What it sets is seen by itself and by the batch files and programs it starts, and disappears when it ends; the variables of its caller and the global ones (prompt, `AUTOEXEC.CMD`) are seen too:

  ```
  global       PATH=C:\APPS, NAME=Ann
   └ A.CMD     X=1                 sees PATH, NAME=Ann, X
      └ B.CMD  NAME=Bob            sees PATH, X, NAME=Bob   (back in A.CMD: NAME=Ann)
  ```
- The whole file is checked first: a syntax error (`Missing ) at the end of a block`) is shown with its line number, and nothing runs.
- **Ctrl+C** stops a running batch file (or an endless `FOR` at the prompt) after asking `Terminate batch job (Y/N)?`, also when it ended a command or program in the batch file. Other keys typed meanwhile are kept. See [Ctrl+C](../README.md#ctrlc).
- `IF` and `FOR` also work at the prompt, as one line.
