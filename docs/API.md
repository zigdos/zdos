# Program API reference

The functions of the program interface. Writing programs: [DEVELOPER.md](DEVELOPER.md).

All functions are reached through their groups (`src/kernel/abi.zig`, mirrored by `sdk/src/zdos.h`). Names below are the Zig wrappers of `apps/zdos/zdos.zig`, with the C form written with its group: `files->open(...)` is `zdos->files->open(...)`.

## Console and keyboard

- `print(str)` (C: `console->print(str, len)`): print text; `\n` starts a new line.
- `printf(fmt, args)` (Zig only, Zig's `{d}` / `{s}` format, up to 256 bytes): formatted print. ZDOS has no formatting function: C programs use the standard `printf` of the [SDK](../sdk/README.md)'s C library, which prints through `print`.
- `readKey()` -> `Key` (C: `console->read_key()` -> `zdos_key`): wait for a key press.
- `pollKey()` -> `?Key` (C: `console->poll_key(&key)`): a key press if one is waiting, else return at once.
- `setCtrlC(as_key)` (C: `programs->set_ctrl_c(as_key)`): `true` makes Ctrl+C an ordinary key for this program; `false`, the default, lets it end the program.
- `editLine(row)` (C: `console->edit_line(row)`): a line editor's line starts at screen row `row` (null / -1: done). Other tasks' output then goes there and `readKey` gives `Scan.redraw`: print the prompt and the line again.

**Ctrl+C** ends a program (exit code 255) at its next `print`, `read_key`, `poll_key`, `read_input` or `sleep`. After `setCtrlC(true)` `read_key` returns it as character 3, until the program ends (C: `signal(SIGINT, ...)`).

A key press has a **character** (`char`; Enter `'\r'`, Backspace `0x08`, Tab `'\t'`) or, for keys without one, a **scan code** (`scan`): Up `0x01`, Down `0x02`, Right `0x03`, Left `0x04`, Home `0x05`, End `0x06`, Insert `0x07`, Delete `0x08`, Page Up `0x09`, Page Down `0x0A`, F1–F10 `0x0B`–`0x14`, F11 `0x15`, F12 `0x16`, Esc `0x17`.

**Ctrl with a letter** gives the control character, as in DOS: Ctrl+A is 1, Ctrl+C 3 … Ctrl+Z 26, with the Ctrl bit set; Ctrl+S is `char == 0x13`. With Alt held too (AltGr) the character stays as typed.

**Modifier bits** (`mods`; `zdos.Mod.*` in Zig, `ZDOS_MOD_*` in C):

- Shift: `left_shift` `0x0001`, `right_shift` `0x0002`.
- Ctrl: `left_ctrl` `0x0004`, `right_ctrl` `0x0008`.
- Alt: `left_alt` `0x0010`, `right_alt` `0x0020` (AltGr on many keyboards).
- Windows / Cmd: `left_logo` `0x0040`, `right_logo` `0x0080`.
- Menu: `menu` `0x0100`.
- Locks, while on: `caps_lock` `0x1000`, `num_lock` `0x2000`, `scroll_lock` `0x4000`.

`shift`, `ctrl`, `alt` and `logo` combine left and right; in Zig `k.ctrl()`, `k.alt()`, `k.shift()`, `k.logo()` test them:

```zig
const k = zdos.readKey();
if (k.ctrl() and k.char == 's') save();
if (k.alt() and k.scan == zdos.Scan.f10) quit();
```

On UEFI the firmware decides what is reported:

- [x] Ctrl, Alt, Windows / Cmd and Menu with every key; Shift with keys without a character. With letters and symbols Shift is already in the character (`'A'`, `'!'`) and its bit isn't set.
- [ ] Modifier keys pressed on their own.
- [ ] Key releases.

On the BIOS and metal editions `keyEvent` sees all of them. `DEMO`, menu item "Keyboard", shows every key with its modifiers.

## Memory

- `alloc(size)` (C: `memory->alloc(size)`): a 16-byte aligned block; null if out of memory.
- `free(ptr)` (C: `memory->free(ptr)`): free a block; null is ignored.
- `allocator` (Zig only): a `std.mem.Allocator` on the above, alignment up to 16.

Blocks still allocated when the program ends are freed by zdos.

## Files

- `open(path, mode)` -> `Error!File` (C: `files->open(path, len, mode)` -> handle or -1): open a file. Modes: **read** (an existing file), **write** (create, or empty an existing file), **update** (create if missing, keep the contents, read and write; seek to the end to append).
- `file.read(buf)` -> `Error!usize` (C: `files->read(h, buf, len)`): the bytes read, 0 at the end.
- `file.write(data)` -> `Error!usize` (C: `files->write(h, buf, len)`): the bytes written, fewer when the disk fills up. `file.writeAll(data)` writes everything or fails.
- `file.seek(pos)` (C: `files->seek(h, pos)`): set the position; `seek_end` / `ZDOS_SEEK_END` is the end.
- `file.size()` -> `Error!u64` (C: `files->size(h)`): the size in bytes.
- `file.setSize(n)` (C: `files->set_size(h, n)`): set the length like `ftruncate`: shorter cuts, longer adds zeros (written, FAT has no holes). The position stays. Needs a file open for writing (`AccessDenied`); at most 4 GB (`DiskFull`).
- `file.commit()` (C: `files->commit(h)`): write the size and date to the disk now, as closing does, and empty the drive's write cache, so the data survives a reset while the file stays open (`fsync`); an ext2 or Minix volume is marked clean too. Files only (`InvalidHandle` for pipes and folders).
- `file.close()` (C: `files->close(h)`): close; also for directories. Closing a written file writes its size and date; `file.closeChecked()` / `last_error` say whether that worked.
- `delete(path)` (C: `files->delete_file(path, len)`): delete a file (a folder: `IsADirectory`, see `deleteTree`).

Paths work as in the shell, with `/` or `\`, also as `/E:/DOCS/X.TXT`: up to 1024 bytes of UTF-8, names up to 255 characters. Up to 128 files and directories can be open at once.

## Directories and drives

- `openDir(path)` -> `Error!Dir` (C: `files->open_dir(path, len)` -> handle or -1): open a directory for listing; `""` is the current one.
- `dir.next(&entry)` -> `Error!bool` (C: `files->read_dir(h, &entry)`): the next entry, false at the end. In C, false with `last_error() == ZDOS_ERROR_NONE` is the end, anything else a read error.
- `getCwd(buf)` (C: `files->get_cwd(buf, len)`): the current location, e.g. `D:\DOCS`.
- `setCwd(path)` (C: `files->set_cwd(path, len)`): change directory like `CD`, with a drive (`E:`, `E:\X`) also the drive. Stays after the program ends.
- `getDrives(&buf)` (C: `drives->letters(buf, len)`): the drive letters, e.g. `CDE`.
- `driveInfo(letter)` -> `Error!DriveInfo` (C: `drives->info`): label, size, free space, `block_size`, serial, `file_system` (`zdos.fileSystemName` names it), whether it is the boot volume, an ESP, hidden, a floppy, `ready`, or `unreadable` (no driver reads it).
- `makeDir(path)` (C: `files->make_dir(path, len)`): create a directory; fails if the name exists.
- `stat(path)` -> `Error!DirEntry` (C: `files->stat(path, len, &entry)`): name (on-disk spelling), `is_dir`, `attrs`, size and dates of a file or directory.
- `fullPath(path, buf)` (C: `files->full_path(path, len, buf, buf_len)`): the full form of a path, with existing names in their on-disk spelling (`docs\..\notes\report.txt` -> `C:\NOTES\Report.txt`). The folders must exist, the last part needn't. Buffer too small: `InvalidArgument` (C: 0).
- `setAttributes(path, attrs)` (C: `files->set_attributes(path, len, attrs)`): set all four attribute bits of a file or directory, like `ATTRIB` (read them with `stat` first to change one). The root has none. A read-only file can't be written or deleted.
- `permissions(path)` -> `Error!Permissions` (C: `files->permissions(path, len, &p)`): `mode` (type and permission bits, as `st_mode`), `uid`, `gid`, and `unix`: false where the file system has none (FAT), then made up from the read-only attribute with owner 0.
- `statEx(path)`, `file.statEx()`, `dir.nextEx(&info, name_buf)` (C: `files->stat_ex`, `fstat_ex`, `read_dir_ex`): `stat`'s information plus mode, owner, inode, links, blocks and the last status change; `valid` says which the file system has. In C set `size = sizeof(zdos_stat_ex)` first.
- `setMode(path, mode)` (C: `files->set_mode(path, len, mode)`, `chmod`): the permission bits, 0o7777 at most. Without Unix permissions only the write bits count: none makes it read only.
- `setOwner(path, uid, gid)` (C: `files->set_owner(path, len, uid, gid)`, `chown`): null (C: `ZDOS_KEEP_ID`) leaves one as it is; root only (`AccessDenied`), `NotSupported` without Unix permissions.

Programs see only drives with a letter: EFI System Partitions and hidden partitions appear after `DISKLET`. `getDrives` plus `driveInfo` gives the `DRIVES` list without the `--` lines (`sys.driveAt` has those too).

A directory entry has `name`, `is_dir`, `attrs` (`zdos.Attr.read_only`, `.hidden`, `.system`, `.archive`), `size` and the dates `modified`, `created`, `accessed` (year 0: unknown). Hidden and system entries are listed too.

## Copying, moving and deleting folders

- `deleteTree(path)` (C: `files->delete_tree(path, len)`): delete a file, or a folder with everything in it. The root is refused. A drive's current directory inside it moves to the parent.
- `copy(from, to)` (C: `files->copy`): a file, or a folder with everything in it, to exactly `to` (which must not exist), also to another drive. Modification dates and, between Unix file systems, permission bits are kept; `zdos.copyMode(from, to)` does the same for a program's own copy.
- `move(from, to)` (C: `files->move(from, from_len, to, to_len)`): rename or move a file or directory, also to another drive (there: copy, then delete). `to` must not exist, except when only the capitalization changes (`Readme.txt` -> `README.TXT`).

They ask and print nothing: conflicts are left to the program (check with `stat`, ask, then delete or skip). When they fail part way, what was done stays done, and the error is the first failure's.

## Time

- `millis()` (C: `time->millis()`): milliseconds since ZDOS started.
- `nanos()` (C: `time->nanos()`): monotonic nanoseconds since ZDOS started, from the CPU's counter; `clockResolution()` its step.
- `sleep(ms)` (C: `time->sleep(ms)`): wait.
- `getTime()` (C: `time->get(&t)`): year, month, day, hour, minute, second.

## Screen

- `clearScreen()` (C: `console->clear_screen()`): clear; the cursor goes to the top left.
- `setCursor(col, row)` (C: `console->set_cursor(col, row)`): move the cursor (0-based).
- `getCursor()` -> `Pos` (C: `console->get_cursor()` -> `zdos_pos`): where the cursor is.
- `screenSize()` -> `Pos` (C: `console->screen_size()` -> `zdos_pos`): columns and rows.
- `setColor(fg, bg)` (C: `console->set_color(fg, bg)`): colors for what is printed next.
- `showCursor(visible)` (C: `console->show_cursor(visible)`): show or hide the cursor.

The 16 DOS colors: `zdos.Color.black` … `.white` (C: `ZDOS_BLACK` … `ZDOS_WHITE`); backgrounds only the first 8. When a program ends, the command interpreter resets the colors and shows the cursor.

Printed text can set colors with ANSI sequences, and with `TERM=vt100` move the cursor and erase ([COMMAND.md](COMMAND.md#ansi-colors)); sequences stay as they are in files and pipes.

## Running other programs

`exec(path, args)` -> `Error!u8` (C: `programs->exec(path, len, args, args_len)` -> exit code or -1) runs a program and waits for it.

The path works as in the shell (`.APP` added, `PATH` searched without a folder). The result is the exit code, or why it couldn't start: `NotFound`, `NotSupported` (not a ZDOS program, or a batch file: use `runCommand`), `InvalidArgument`, `OutOfMemory`. Programs nest up to 10 levels deep.

## Standard input, redirection and variables

A program in a pipe (`TYPE NOTES.TXT | MYPROG`, `MYPROG < NOTES.TXT`) can read its input; with its output redirected (`MYPROG > OUT.TXT`, `MYPROG | MORE`) everything it prints goes there.

- `readInput(buf)` -> bytes (C: `console->read_input(buf, len)`): read the standard input, 0 at the end; always 0 when the input isn't redirected (read the keyboard then).
- `inputRedirected()` (C: `console->input_redirected()`): whether there is such input.
- `outputRedirected()` (C: `console->output_redirected()`): whether `print` goes to a file or the next command. The screen functions then do nothing, so a program can skip drawing.
- `getVar(name, buf)` -> `?value` (C: `programs->get_var(name, name_len, buf, len)`): a variable (`SET`, `PATH`, `COMSPEC`) as seen where the program was started: a batch file's own, then its caller's, then the global ones. Returns the length (`-1` / `null` if not set). `ERRORLEVEL` isn't one, as in DOS.
- `varAt(index, buf)` -> `?"NAME=value"` (C: `programs->var_at(index, buf, len)`): the variables one at a time, as `SET` lists them; `-1` / `null` past the last.

A filter, as `DEMO UPPER` does it:

```zig
var buf: [1024]u8 = undefined;
while (true) {
    const n = zdos.readInput(&buf);
    if (n == 0) break;
    for (buf[0..n]) |*c| c.* = std.ascii.toUpper(c.*);
    zdos.print(buf[0..n]);
}
```

The commands of a pipe run one after another, so the input is complete when the program starts. The keyboard still works meanwhile.

## Program arguments and exit code

- The text after the program name comes as UTF-8: `main(args)` in Zig, `start->args` / `start->args_len` in C; at most 4096 bytes (longer text from `exec` is cut).
- Zig programs get it as typed and split it themselves. Remove every `"` from a name, since Tab completion quotes parts of paths (`"My Folder"\Sub`). C programs get `argv` with the quotes removed.
- The value returned from `main` / `zdos_entry` is the exit code; 0 means success.

## System, variables and ending the program

- `systemInfo()` -> `SystemInfo` (C: `programs->system_info(&info)`): ZDOS's version (4 bytes, as `VER` shows it), total and free memory, the largest free block, the CPU's name and speed in MHz (0 if unknown), as `MEM` shows them.
- `programPath(buf)` (C: `programs->program_path(buf, len)`): the program's own file, `C:\APPS\DEMO.APP`; `""` / 0 if the buffer is too small.
- `setFileTime(path, time)`, `file.setTime(time)` (C: `files->set_time`, `fset_time`): a file's or folder's modification time. Closing a written file stamps the current time, so set it afterwards or through the open file.
- `setVar(name, value)` (C: `programs->set_var`): in the batch file the program runs from, else globally; global variables only for admins (`AccessDenied`). An empty value removes it. Names up to 32 characters, values up to 512 bytes.
- `runCommand(line)` -> `Error!u8` (C: `programs->run_command(line, len)` -> ERRORLEVEL or -1): run a line as typed at the prompt, with built-in commands, batch files, pipes, `IF`, `FOR`, `%NAME%`. ZDOS starts `COMSPEC` (normally `C:\APPS\COMMAND.APP`; `SHELL` is the same in POSIX form) as `COMMAND -c line`; its output goes where the program's does.
- `exit(code)` (C: `programs->exit(code)`): end the program at once, from anywhere, as when `main` returns.
- `getIds()`, `setIds(ids)` (C: `programs->get_ids`, `set_ids`): `real`, `uid`, `saved`, `gid` and up to 16 `groups`, inherited from the starter. Root may set anything, others only switch among their real, effective and saved user; `keep_id` / `keep_groups` leave a value.
- `randomBytes(buf)` (Zig only): random bytes for salts and keys, from the CPU's random number instruction where it has one and the cycle counter, mixed through SHA-256.

`runCommand` returns ERRORLEVEL: a program's exit code, a batch file's `EXIT n`, 0 after most built-in commands (they print their errors). What the line changes stays: `CD` and `D:` change the program's directory and drive, `SET` sets variables as `setVar` does, `SHUTDOWN` turns the computer off.

## System functions (system.zig)

For command interpreters and system tools. Zig programs import `apps/zdos/system.zig` next to `zdos.zig`; in C they are in the groups `system`, `disks`, `drives` and `keyb`.

- `redirect(.input / .output, handle)` (C: `system->redirect(stream, handle)`): the standard input or output to an open file or pipe, for the program and those it starts; `sys.inherited`, `sys.console`, `sys.nul`. Undone when the program ends.
- `createPipe()` -> `Error!File` (C: `system->create_pipe()` -> handle or -1): a pipe in memory, written like a file, then read from its start. `a | b` runs `a` into a pipe, then `b` from it. Closing frees it; `OutOfMemory` if output had to be dropped.
- `catchCtrlC(on)` (C: `system->catch_ctrl_c(on)`): Ctrl+C neither ends the program nor is a key; ZDOS shows `^C` and remembers it. Programs started meanwhile end on Ctrl+C as usual. `read_key` still returns it when it is the key waited for.
- `ctrlCPressed(clear)` (C: `system->ctrl_c_pressed(clear)`): whether Ctrl+C was pressed (while caught, or ending a program this one started); `clear` forgets it.
- `pushVars()`, `popVars()` (C: `system->push_vars()`, `pop_vars()`): variable scopes, as batch files have: `setVar` sets in the top one, `getVar` looks there first. A program drops only scopes it pushed; at most 16.
- `termCreate(cols, rows)` -> `Error!File` (C: `system->term_create`): a remote console, as SSHD's sessions: reading gives what its tasks print as VT100, writing types keys; tasks started with `SpawnOptions.term` live there. Closing it sends them SIGHUP; `termResize` sends SIGWINCH.
- `driveAt(index)` -> `?DriveInfo` (C: `drives->at(index, &info)`): every drive, also those without a letter (letter 0), as `DRIVES` shows them.
- `assignLetters()` (C: `drives->assign_letters()`): give the drives without a letter one, until restart (`DISKLET`); returns how many. Root only (0 and `AccessDenied`).
- `eject(letter)` (C: `drives->eject`): writes the drive's disk out and lets it go (metal USB disks); `AccessDenied` for the boot disk or with a file open for writing.
- `setLabel(letter, label)` (C: `drives->set_label(letter, label, len)`): set a drive's label like `LABEL`; `""` removes it. DOS's rules apply (11 characters, none of `* ? . , ; : / \ | + = < > [ ] "`, stored in capitals; `InvalidName`). UEFI firmware drops spaces. Root only.
- `setTime(time)` (C: `time->set(&time)`): set the local date and time; admins only (`AccessDenied`), `InvalidArgument` for an invalid one, `NotSupported` if the clock refuses (the BIOS clock: 1980–2079 without ACPI's century register).
- `shutdown()`, `restart()` (C: `system->shutdown()`, `system->restart()`): turn the computer off; restart it (CHKDSK does after a repair). Admins only: they don't return, so for anyone else the program ends with exit code 1 and a message on the error output.
- `bootFile(buf)` (C: `system->boot_file(buf, len)`): the file ZDOS was started from, on the boot drive (`\EFI\BOOT\BOOTX64.EFI`, BIOS `\ZIGDOS.SYS`); null / 0 if the firmware didn't say. `addBootEntry(letter, path)` (C: `system->add_boot_entry(letter, path, len)`): a UEFI boot entry for that file, first in the boot order (BIOS: `NotSupported`).
- `diskCount()` -> `u32` (C: `disks->count()`): whole disks and floppy drives. Partitions aren't listed: a tool reads them from the sectors.
- `diskInfo(index)` -> `?DiskInfo` (C: `disks->info(index, &info)`): sectors (0 without a disk), sector size, removable and read-only.
- `readSectors(index, lba, buf)` (C: `disks->read(index, lba, count, buf)`): read whole sectors from the disk's start; `device_error` past the end or on a read error.
- `writeSectors(index, lba, data)` (C: `disks->write(index, lba, count, data)`): write whole sectors; `write_protected` on a protected disk. Nothing stops a program from writing the disk ZDOS started from: it has to ask first.
- Raw sectors pass by every file's permissions, so `disks->read` and `write` are root only (`AccessDenied`).
- `diskChanged(index)` (C: `disks->changed(index)`): after raw writes, the disk's volumes are read again, so the drives don't use what was there before.
- `driveLocation`, `driveSectors`, `driveRead`, `driveWrite`, `driveChanged` (C: `drives->location`, `sectors`, `read`, `write`, `changed`): a drive's volume by sector, counted from its start, for the disk tools (root only).
- `syncDrive(letter)`, `syncDisk(index)` (C: `drives->sync`, `disks->sync`): write out what ZDOS still holds for it in memory, before a tool reads or writes its sectors itself (CHKDSK, CHKMFS, CHKEXT2, FORMAT).
- Keyboard layouts (C: group `keyb`): `keybCount()`, `keybName(index, buf)` (two letters), `keybActive()`, `keybSetActive(index)` (it must be loaded), `keybLoaded(buf)` (`EN,ES,FR` in switching order), `keybSetLoaded(list)`, as `KEYB` uses them.

`zdos.zig` also gives the raw groups (`zdos.table()`, e.g. `zdos.table().gfx.begin`), `zdos.check(ok)` and `zdos.lastError()`, which `system.zig` and `gfx.zig` build on.

## Tasks (system.zig)

Programs running at the same time, as tasks (group `tasks`), on every edition; a task's number is its POSIX process ID, the first is 1. Scheduling, preemption, timers and locking: [REALTIME.md](REALTIME.md#how-it-works). Only task 1 reads the keyboard; a started task has no standard input, the screen as output, and the global variables.

- `taskSpawn(path, args)` -> `Error!u32` (C: `tasks->spawn`): a program, found as `exec` finds it, as a new task at the caller's priority.
- `taskSpawnWith(path, args, options)` (C: `spawn_ex`): with standard streams (`SpawnOptions`), a priority and a remote console (`term`).
- `taskSpawnEnv(path, args, options, env)` (C: `spawn_env`): with variables of its own, `NAME=value` entries each ended by a 0 byte (up to 48, values up to 512 bytes). `sys.spawnEnvWorks()` tells whether this ZDOS has it.
- `taskWait(id)` -> `Error!u8`, `taskEnded(id)` -> `?u8`, `taskWaitAny(hang)` -> `Error!?TaskEnd` (C: `wait`, `ended`, `wait_any`, `wait_end`): the exit code of a task this one started. Ended tasks are freed at once; the last 64 exit codes are kept for their starters, none with `SA_NOCLDWAIT`.
- `taskId()`, `taskYield()`, `taskSetPriority(id, p)`, `taskPriority(id)`; `taskSetPolicy`, `taskSetDeadline`, `taskSetAffinity` (C: `set_policy`, `set_deadline`, `cores->set_affinity`): others' tasks only as root.
- `cpuTimes()`, `taskInfo(index)` (C: `times`, `info`): the CPU load and the task list, for TOP and PS.
- `Mutex.create()`, `lock()`, `tryLock()`, `unlock()`, `destroy()` (C: `tasks->mutex_create()` …): with priority inheritance; a program's mutexes go when it ends.

**Threads** (group `threads`): `threadCreate(entry, arg, stack_size, priority)` runs a function of the program as a task of its own; `threadJoin`, `threadDetach`, `threadExit`; `set_local` / `local` keep a value per thread. `Cond` and `Semaphore`, both with an optional timeout. Futexes (C: `threads->futex_wait`, `futex_wake`, `futex_requeue`; Zig `sys.futexWait`, `sys.futexWake`) as Linux's `FUTEX_WAIT_BITSET`, `WAKE_BITSET`, `CMP_REQUEUE`; `futex_wait` returns its error code (and sets `last_error`, which threads share). The C library's pthreads and `syscall(SYS_futex)` are built on them. `exit` in a thread ends the program.

**POSIX paths**: exactly `/dev/null`, `/dev/tty`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr` are devices; `/tmp` is the `TEMP` folder. Other paths starting with `/` are on the current drive, and `/C:/DOCS` is `C:\DOCS`.

**Error output**: the third standard stream, `printError` / `eprintf` (C: `console->print_error`, `stderr`), the screen unless redirected (`system->redirect(2, handle)`).

**Current directories**: each program has its own current drive and directories, from the program that started it; threads share their program's.

**CPU faults** (metal and BIOS): a fault in a program's code gives it the signal (SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP); without a handler it ends with 128 + the signal and a line on the error output. On metal address 0 and a guard page below every stack are unmapped. A fault in ZDOS's own code shows the crash screen and halts: a file system may be half updated.

**Pipes, dup, poll** (group `files`): `pipe()` gives two ends between tasks (64 KiB; `BrokenPipe` and SIGPIPE with no reader); `dup`, `poll`; `queue_create` / `queue_events`, event queues as epoll, over sockets, pipe ends and `threads->counter_create`'s counters (eventfd).

**Signals** (group `signals`, POSIX numbers): `signalSend(task, sig)`, to tasks of the same user, any as root; `set_handler`, `mask`, `pending`, `alarm(ms)`, `wait(mask)`. Without a handler SIGCHLD, SIGURG, SIGWINCH and SIGCONT are ignored, SIGSTOP / SIGTSTP stop the task until SIGCONT, the rest end the program with 128 + the signal. A signal ends waits with `Interrupted`.

## Other CPU cores (system.zig)

Jobs on the other cores (group `cores`), sharing the program's memory. A job must not call ZDOS, not even to allocate or print; a program that ends waits for its jobs. Example: `apps/demo.zig` (`DEMO cores`).

- `coreCount()` (C: `cores->count()`): core 0 included; the network's own core too, but it refuses jobs (`AccessDenied`).
- `coreStart(n, job, arg)` (C: `cores->start`): `job(arg)` on core `n` (1 to count − 1); `AccessDenied` while it still runs one.
- `coreBusy(n)`, `coreWait(n)` (C: `cores->busy`, `wait`).

## Libraries (.ZDL)

`NAME.ZDL`, looked for in the program's folder, then in `\LIBS` on the boot drive (never the current folder). The program format with an export table instead of an entry point (`sdk/linkers/lib-*.ld`): `slots`, then function pointers, which only grow at the end.

- `loadLibrary(name)` -> `Error!*const anyopaque` (C: `programs->load_library`): the export table; `zdos.library(T, name)` gives it as the extern struct `T`, slots an older library lacks failing with `NotSupported`.
- **Shared** (`export const zdos_library_shared`): one copy for every program, so no changing global state; callers pass their memory. **Per program** (default): a copy each, for libraries with globals.
- `zdos_library_init(start)`, if exported, runs once per load.
- **Import stubs** let C programs call a library's functions by name: `sdk/bin/zdos-stubs`. Making a library, in C or Zig: [ZDL.md](ZDL.md).
- A C library has its own copy of the C library: its descriptors, `FILE` streams and `atexit` are its own, so it must be per program; `malloc` / `free` and threads are shared with the program.

## Drivers (.SYS)

`\SYSTEM\DRIVERS\*.SYS`, loaded at startup on metal and BIOS for the PCI devices their `zdos_driver_ids` name. `zdos_driver_init(api, device)` gets the driver interface (`src/kernel/drv.zig`): logging, time, DMA pages, register mapping, PCI configuration, firmware files, registering a network or sound card, and interrupts: `attach_interrupt` (MSI-X or MSI on metal, the wired line on BIOS, shared) and, for network cards, `net_interrupts`, which lets ZDOS connect the card's interrupts where the network runs. Writing one: [SYS.md](SYS.md).

## Graphics, game keys and mouse (gfx.zig)

A picture over the whole screen in 256 colors or true color, key presses and releases, and the mouse: `apps/zdos/gfx.zig`, group `gfx`. C programs may also use SDL 2, the partial SDL 1.2 ([ports](../ports/README.md)) or `zdos_media.h` ([sdk/README.md](../sdk/README.md#display-input-and-sound-zdos_mediah)).

Each program in graphics has a tab: its own screen, mode, palette and last picture (up to 8). Alt+Tab or Win+Tab brings the next to the front, the text console first; only the front tab is shown and gets input, the others run on.

- `visible()` (C: `gfx->visible()`): whether this program's tab is in front; a game may pause while it isn't.
- `setTitle(name)` (C: `gfx->set_title(name, len)`): the tab's name (SDL's window title); its program's name until set.
- `textInput(buf)` (C: `gfx->text_input`): the characters typed since the last call, UTF-8 with the layout applied (SDL's text input).

- `begin(width, height)` (C: `gfx->begin`): graphics for a `width` x `height` picture, scaled up by a whole number and centered; BIOS: VGA mode 13h up to 320×200, a larger picture the smallest 256-color VESA mode it fits (without VESA mode 12h, 16 colors, up to 640×480). The palette starts black.
- `beginDosAspect(width, height)` (C: `gfx->begin_dos_aspect`): the same, shown 4:3 as a DOS screen showed 320×200 (UEFI; on BIOS the monitor does it).
- `palette(first, colors)` with `[N][3]u8` (C: `gfx->palette(first, count, rgb)`): set colors from `first` on, red, green, blue 0-255; takes effect at the next `draw` at the latest.
- `draw(pixels)` (C: `gfx->draw(pixels)`): show a picture, `width * height` palette indexes, row after row from the top left.
- `end()` (C: `gfx->end()`): back to the text screen as it was. ZDOS does it too when the program ends.
- `screen()` -> `Error!ScreenInfo` (C: `gfx->screen`): the screen's `width`, `height` and `true_color`; a picture that size is shown 1:1, one half as wide and high doubled. BIOS: the largest true-color VESA mode up to 1024×768 (without VESA 320×200, not true color).
- `beginRgb(width, height)`, `drawRgb(pixels)` (C: `begin_rgb`, `draw_rgb`): a true-color picture of `0x00RRGGBB` pixels; on BIOS in the smallest true-color VESA mode it fits (`NotSupported` without VESA).
- `modes(buf)` (C: `gfx->modes(sizes, max)`): the screen modes the firmware offers (`ScreenSize`: width, height), smallest first, as many as fit; C returns how many there are. BIOS: 320 x 200, 640 x 480 and the VESA modes. `SCREEN` lists them.
- `keyEvent()` -> `Error!?KeyEvent` (C: `gfx->key_event`): the next key going down or up: its set 1 scan code (E0 keys as `0xE000 | code`, the same on every layout), `pressed`, `repeat`, `mods`. Keys read this way no longer reach `readKey`.
- `mouse()` -> `Error!Mouse` (C: `gfx->mouse`): the movement since the last call (`dx`, `dy`), `wheel` and `buttons`; `NotSupported` without a mouse.
- `arrow`, `drawArrow(...)`, `small_arrow`, `drawSmallArrow(...)` (Zig): the arrow cursors from `icons/`, drawn into a picture; ZDOS draws no pointer itself.

```zig
const gfx = @import("zdos/gfx.zig");

try gfx.begin(320, 200);
defer gfx.end();
gfx.palette(0, &colors); // colors: [256][3]u8
gfx.draw(&picture);      // picture: [320 * 200]u8
```

|                        | BIOS               | UEFI (x86-64, ARM64)    |
| ---------------------- | ------------------ | ----------------------- |
| Screen                 | VESA, VGA 13h (12h without VESA) | firmware's (GOP, `Blt`) |
| Picture too large      | `NotSupported`     | `NotSupported`          |
| Text printed meanwhile | shown afterwards   | lost                    |
| `keyEvent`             | yes                | `NotSupported`          |
| `mouse`                | PS/2, USB via BIOS | firmware USB, 2 buttons |

## Network (net.zig)

TCP/IP over IPv4 (lwIP in the kernel), group `net`, when `SYSTEM.CFG` has `NETWORK=true` ([Network](NETWORK.md)); without it the calls fail with `NetworkDown`. Zig programs import `apps/zdos/net.zig`; C programs use the usual socket functions (`sys/socket.h`, `netdb.h`), or the group directly. Addresses are `NetAddress`: `addr` as written (`.{ 192, 168, 0, 1 }`) and `port`.

- `info()`, `interface(i)`, `route(i)` (C: `net->info`, `interface`, `route`): the interfaces (card, MAC, flags, addresses, DNS, DHCP lease, counters) and routes. `renew(ms)`, `release()`: DHCP again, or give the addresses up.
- `resolve(name)` -> `[4]u8` (C: `net->resolve(name, len, out)`): an address written out, `localhost`, `HOSTS.CFG`, then DNS; `HostNotFound`.
- `ping(addr, seq, size, ttl, timeout_ms)` -> `PingReply`: one echo request; `result` reply, unreachable or TTL expired, `rtt_ms`, `ttl`, `from`; `TimedOut` without an answer.
- `arpEntry(i)`, `arpAdd(addr, mac)`, `arpRemove(addr or null for all)`; `connection(i)`: the ARP table and the TCP/UDP sockets (for `ARP`, `NETSTAT`). Adding and removing ARP entries is for admins.
- Sockets (`Socket`; C: `net->socket` and the rest, or `sys/socket.h`): `open`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `sendTo`, `recvFrom`, `sendVia` / `recvVia` (with the card and addresses, as `IP_PKTINFO`), `shutdown` (C), `address`, options. A socket is a handle: `read`, `write`, `poll`, `dup`, `close` work on it. Ports below 1024 are admins'.

## Sound (sound.zig)

Group `sound`. Zig programs import `apps/zdos/sound.zig`; C programs use `zdos->sound`.

- `tone(hz)`, `softTone(hz)`, `beep(hz, ms)`: the PC speaker (x86), a square wave of 20-20000 Hz until the next call (0: silence); `softTone` a quieter pulse.
- `open(rate, channels, bits)` -> `Output` (`write`, `queued`, `close(drop)`), `setVolume`: samples to the sound card a driver registered, 8000-192000 Hz, mono or stereo, 8 or 16 bits, converted for the card. One program at a time (`AccessDenied`); `NotSupported` without a card.

## Errors

Every call that can fail records why, *none* when it works; calls that can't fail leave it alone. Each program has its own code.

- Zig: failed calls return a `zdos.Error`; `zdos.lastErrorCode()` gives the raw code.
- C: `programs->last_error()` -> `zdos_error`, read right after the failed call, before anything else that can fail (`close` too).
- `zdos.message(err)` (C: `zdos_error_message(code)`): the text the shell shows, `Access denied`, `Disk full` ...

The codes, with their C name, number and the `errno` the SDK and MicroPython translate them into:

- `NotFound` (`ZDOS_ERROR_NOT_FOUND`, 1, `ENOENT`): the file or folder doesn't exist.
- `PathNotFound` (`ZDOS_ERROR_PATH_NOT_FOUND`, 2, `ENOENT`): a folder on the way, or the drive, doesn't exist.
- `AlreadyExists` (`ZDOS_ERROR_ALREADY_EXISTS`, 3, `EEXIST`): `make_dir`, `copy`, `move` to a name that is taken.
- `AccessDenied` (`ZDOS_ERROR_ACCESS_DENIED`, 4, `EACCES`): a read-only or system entry, the root, writing a file opened for reading, the file's permissions, or something only root or admins may do.
- `WriteProtected` (`ZDOS_ERROR_WRITE_PROTECTED`, 5, `EROFS`): the disk is write-protected.
- `DiskFull` (`ZDOS_ERROR_DISK_FULL`, 6, `ENOSPC`): no free space, a full FAT12/16 root folder, or FAT's 4 GB file limit.
- `TooManyOpen` (`ZDOS_ERROR_TOO_MANY_OPEN`, 7, `EMFILE`): no free handle.
- `InvalidHandle` (`ZDOS_ERROR_INVALID_HANDLE`, 8, `EBADF`): not open, a directory handle used as a file or the other way, or its floppy was changed.
- `OutOfMemory` (`ZDOS_ERROR_OUT_OF_MEMORY`, 9, `ENOMEM`).
- `InvalidName` (`ZDOS_ERROR_INVALID_NAME`, 10, `EINVAL`): a name with `" * / : < > ? \ |` or control characters, too long, or an invalid label.
- `DeviceError` (`ZDOS_ERROR_DEVICE_ERROR`, 11, `EIO`): read or write error, no disk in the drive, damaged file system.
- `NotSupported` (`ZDOS_ERROR_NOT_SUPPORTED`, 12, `EOPNOTSUPP`): the platform can't do it.
- `NotADirectory` (`ZDOS_ERROR_NOT_A_DIRECTORY`, 13, `ENOTDIR`): a file where a folder is needed (`open_dir`, `NOTE.TXT\X`).
- `IsADirectory` (`ZDOS_ERROR_IS_A_DIRECTORY`, 14, `EISDIR`): a folder where a file is needed (`open`, `delete_file`).
- `DirNotEmpty` (`ZDOS_ERROR_DIR_NOT_EMPTY`, 15, `ENOTEMPTY`).
- `InvalidArgument` (`ZDOS_ERROR_INVALID_ARGUMENT`, 16, `EINVAL`): an invalid open mode or date, a folder copied into itself, a buffer too small.
- `Interrupted` (`ZDOS_ERROR_INTERRUPTED`, 17, `EINTR`): a signal ended the wait.
- `TimedOut` (`ZDOS_ERROR_TIMED_OUT`, 18, `ETIMEDOUT`): a condition or semaphore wait's time ran out.
- `WouldBlock` (`ZDOS_ERROR_WOULD_BLOCK`, 19, `EAGAIN`): it would have to wait, and wasn't to (`tryLock`, a semaphore with timeout 0).
- `BrokenPipe` (`ZDOS_ERROR_BROKEN_PIPE`, 20, `EPIPE`): writing a pipe nobody reads any more.
- `NoChild` (`ZDOS_ERROR_NO_CHILD`, 21, `ECHILD`): no task of this one's to wait for.
- The network's (22-34): `NetworkDown` (`ENETDOWN`), `InProgress` (`EINPROGRESS`), `Already` (`EALREADY`), `AddressInUse` (`EADDRINUSE`), `HostUnreachable` (`EHOSTUNREACH`), `IsConnected` (`EISCONN`), `NotConnected` (`ENOTCONN`), `ConnectionRefused` (`ECONNREFUSED`), `ConnectionReset` (`ECONNRESET`), `ConnectionAborted` (`ECONNABORTED`), `MessageTooLong` (`EMSGSIZE`), `HostNotFound` (C: `getaddrinfo`'s `EAI_NONAME`), `NotASocket` (`ENOTSOCK`).

BIOS and UEFI report the same codes, since the kernel checks paths and names itself. For failures of the disk itself, the BIOS only tells write protection apart; everything else is `DeviceError`.
