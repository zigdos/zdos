// The prompt, command lines (redirection, pipes) and built-ins. Disk
// commands are in filecmds.zig, DIR in dircmd.zig, batch files and IF /
// FOR / SET in batch.zig.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const vars = @import("vars.zig");
const filecmds = @import("filecmds.zig");
const datetime = @import("datetime.zig");
const lineedit = @import("lineedit.zig");
const batch = @import("batch.zig");
const dircmd = @import("dircmd.zig");
const textcmds = @import("textcmds.zig");
const compare = @import("compare.zig");
const path_list = @import("path_list.zig");


// For Tab completion.
pub const command_names = [_][]const u8{
    "CALL", "CAT",  "COMP",  "CD",    "CHDIR", "CHOICE", "CLS",     "COPY", "CP",    "DATE", "DEL",   "DELTREE",
    "DIR",  "ECHO", "ERASE", "EXIT",  "FC",    "FIND",   "FINDSTR", "HELP", "LS",    "MD",   "MKDIR", "MKFILE",
    "MOVE", "MV",   "PATH",  "PAUSE", "RD",    "REM",    "REN",     "RM",   "RMDIR", "SET",  "SHIFT", "SORT",
    "TYPE", "WAIT", "WHERE", "XCOPY",
};

pub const Mode = enum {
    permanent, // -p: the first one, started by ZDOS; EXIT doesn't end it
    login, // -l: started by LOGIN.APP for a user; EXIT logs out
    secondary, // started from the prompt or a program: EXIT ends it
};

// Until EXIT (never, if permanent).
pub fn interactive(mode: Mode, autoexec: bool) u8 {
    permanent = mode == .permanent;
    if (permanent) {
        listDrives();
        con.print("\nType HELP for a list of commands\n\n");
        if (autoexec) batch.runAutoexec();
    } else if (mode == .login) {
        if (autoexec) batch.runAutoexec();
        batch.runLoginScript();
    } else {
        const version = zdos.systemInfo().os_version;
        con.printf("ZDOS command interpreter {d}.{d}. EXIT returns to where it was started.\n\n", .{ version[0], version[1] });
    }

    var line_buf: [1024]u8 = undefined;
    lineedit.reprompt = &printPrompt;
    while (exit_code == null) {
        con.clearBreak();
        collectFinished();
        printPrompt();
        const line = lineedit.read(&line_buf, true);
        batch.runPromptLine(line);
    }
    return exit_code.?;
}

var permanent = false;
var exit_code: ?u8 = null; // set by EXIT in a secondary command interpreter

// If a line ran EXIT (for COMMAND -c).
pub fn exitCode() ?u8 {
    return exit_code;
}

// After a program changed them: DOS left them to the program, ZDOS undoes it.
fn resetScreen() void {
    if (zdos.outputRedirected()) return;
    zdos.setColor(.light_gray, .black);
    zdos.showCursor(true);
}

// At startup, in the columns of DRIVES.APP.
fn listDrives() void {
    if (sys.driveAt(0) == null) {
        con.print("No drives found\n");
        return;
    }
    con.print("Drives:\n");
    var index: u32 = 0;
    while (sys.driveAt(index)) |info| : (index += 1) {
        if (info.letter == 0) continue;
        con.printf("  {c}:  ", .{info.letter});
        if (info.ready or info.unreadable) {
            con.print(info.label());
            con.spaces(12 -| info.label_len);
            const name = fs.fileSystemName(info.file_system);
            const kind = if (name.len > 0) name else "unknown";
            con.print(kind);
            con.spaces(7 -| kind.len);
            con.printNum(info.size / (1024 * 1024), 8);
            con.print(" MB");
        } else if (info.floppy or info.removable) {
            con.print("(no disk)");
        }
        if (info.unreadable) con.print("   (not readable)");
        if (info.boot) con.print("   (boot)");
        if (info.system) con.print("   (system)");
        if (info.hidden) con.print("   (hidden)");
        con.print("\n");
    }
}

pub fn printPrompt() void {
    var buf: [fs.max_path + 2]u8 = undefined;
    con.print(zdos.getCwd(&buf));
    con.print(">");
}

fn trim(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t");
    // Quoted paths: CD "My Folder":
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
    return t;
}

fn execute(line: []const u8) void {
    if (line.len == 0) return;

    // Drive switch: "D:":
    if (line.len == 2 and line[1] == ':') {
        if (!fs.driveExists(line[0])) {
            con.print("Invalid drive specification\n");
        } else zdos.setCwd(line) catch |err| con.printf("{s}\n", .{fs.message(err)});
        return;
    }

    // The name also ends at '.', '\' or '/', so "CD.." and "CD\" work:
    var end: usize = 0;
    while (end < line.len and line[end] != ' ' and line[end] != '.' and line[end] != '\\' and line[end] != '/') : (end += 1) {}
    const cmd = line[0..end];
    // A name with an extension ("FIND.APP") is never a built-in:
    if (end < line.len and line[end] == '.') {
        const word_end = std.mem.indexOfAnyPos(u8, line, end, " \t") orelse line.len;
        const ext = line[end..word_end];
        for ([_][]const u8{ ".APP", ".CMD", ".BAT" }) |e| {
            if (!std.ascii.eqlIgnoreCase(ext, e)) continue;
            if (!runExternal(line)) con.print("Bad command or file name\n");
            return;
        }
    }
    const args = trim(line[end..]);
    // MD, MKFILE, DEL, COPY and MOVE parse quotes themselves ("A B" "C D"):
    const raw_args = std.mem.trim(u8, line[end..], " \t");

    const is = std.ascii.eqlIgnoreCase;
    if (is(cmd, "CLS")) {
        zdos.clearScreen();
    } else if (is(cmd, "HELP")) {
        con.print(
            \\VER [file]       The ZDOS version, or a program's, library's or driver's (VER.APP)
            \\CLS              Clear the screen
            \\DIR [-a|-a:h] [-w] [-b] [-s] [-o[keys]] [-p] [path]
            \\                 List a directory (also LS): -a also hidden, -a:h only hidden,
            \\                 -w wide, -b names only, -s with subfolders, -o sorted
            \\                 (N name, E ext, S size, D date, G folders first, - reverses)
            \\CD [path]        Show or change the current directory (CD .., CD \)
            \\X:               Switch to drive X
            \\DRIVES           List all drives, also those without a letter (DRIVES.APP)
            \\DISKLET          Give the drives without a letter (--) a letter (DISKLET.APP)
            \\TYPE [-p] file   Show a text file (also CAT); -p: page by page, as with MORE
            \\MORE file        Show a text file page by page, with scrolling (MORE.APP)
            \\FIND [-v] [-c] [-n] [-i] "text" [file ...]
            \\                 Lines with the text (-v without it, -c count, -n numbered,
            \\                 -i any case); a file or input: DIR | FIND "x"
            \\FINDSTR [-v] [-c] [-n] [-i] [-l] pattern [file ...]
            \\                 Like grep: lines matching a pattern (. [a-z] * + ? ^ $ a|b \x);
            \\                 -l only the files' names
            \\SORT [-r] [file] Sort lines (letters without case; -r reversed)
            \\FC [-i] file1 file2  Compare text files line by line (-i: any case)
            \\COMP file1 file2 Compare files byte by byte
            \\WHERE name       Show what NAME runs: a built-in command, or the program
            \\                 or batch file found (current folder, then PATH)
            \\program args &   Run a program as a task, in the background
            \\WAIT [n]         Wait for task n, or for those started with &
            \\MD path          Create a directory (also MKDIR)
            \\MKFILE file      Create an empty file
            \\ECHO text        Print the text
            \\DEL [-a|-a:h] [-q] path
            \\                 Delete a file, or a directory with all in it (also RM, ERASE);
            \\                 hidden matches only with -a (also them) or -a:h (only them);
            \\                 -q: don't ask
            \\RD [-a|-a:h] [-y] path
            \\                 Delete a directory with all in it (also RMDIR, DELTREE);
            \\                 a hidden one only with -a; -y: don't ask
            \\COPY [-a|-a:h] [-y] from to
            \\                 Copy a file, or a directory with all in it (also CP, XCOPY);
            \\                 -y: overwrite without asking; with wildcards, hidden
            \\                 entries only with -a (also them) or -a:h (only them)
            \\COPY CON file    Type a new text file; Ctrl+Z or F6 ends it
            \\MOVE [-a|-a:h] [-y] from to
            \\                 Move or rename a file or directory (also MV, REN);
            \\                 asks before replacing a file; -y: without asking;
            \\                 with wildcards, hidden entries as by COPY
            \\ATTRIB [+-RASH] [path]
            \\                 Show or change attributes: Read-only, Archive, System, Hidden
            \\                 (ATTRIB.APP)
            \\DATE [new]       Show or set the date and time (yyyy-mm-dd hh:mm[:ss][am|pm])
            \\VOL [X:]         Show a drive's label, serial number, file system, block size
            \\                 and space: total, used, available (VOL.APP)
            \\path [args]      Run a program: NAME, NAME.APP, D:\TOOLS\NAME ...
            \\SET [name=value] Show or set variables; SET -p asks, SET -a evaluates 64-bit arithmetic
            \\PATH [dir;dir]   Show or set where commands are looked for (also SET PATH=)
            \\CALL file [args] Run a batch file (.CMD, .BAT) or a command
            \\PAUSE            Wait for a key
            \\CHOICE [-c YN] [-t:Y,s] [text]  Ask for a key; ERRORLEVEL = its number
            \\MEM              Show the CPU and the memory: total, free, largest free block
            \\                 (MEM.APP)
            \\SHUTDOWN         Turn off the computer (SHUTDOWN.APP)
            \\REBOOT           Restart the computer (REBOOT.APP)
            \\EXIT [code]      Leave a batch file, or a second command interpreter
            \\COMMAND [-c line]  Start a second command interpreter (COMMAND.APP),
            \\                 or run one command line with it
            \\
            \\In batch files:  IF [NOT] EXIST f / a op b / ERRORLEVEL n ... ELSE ...,
            \\                 FOR %%x IN (list) DO ..., FOR -L %%x IN (from,step,to) DO ...,
            \\                 FOR -f %%x IN (file / 'command' / "text") DO ... (each line),
            \\                 FOR DO ... BREAK, IF DEFINED name, IF -i, SHIFT, REM / #,
            \\                 %1, %name%
            \\
            \\command > file   Write the command's output to a file (>> file: add to it)
            \\command < file   The command reads the file (MORE, programs)
            \\cmd1 | cmd2      cmd2 reads cmd1's output, e.g. DIR | MORE
            \\HELP             Show this list
            \\
        );
    } else if (is(cmd, "CD") or is(cmd, "CHDIR")) {
        cmdCd(args);
    } else if (is(cmd, "DIR") or is(cmd, "LS")) {
        dircmd.run(args);
    } else if (is(cmd, "MD") or is(cmd, "MKDIR")) {
        filecmds.md(raw_args);
    } else if (is(cmd, "MKFILE")) {
        filecmds.mkfile(raw_args);
    } else if (is(cmd, "ECHO")) {
        // After "ECHO " or "ECHO." (an empty line), spaces kept; ECHO alone
        // shows, ECHO ON / OFF sets whether batch files show their commands:
        const rest = line[end..];
        if (std.mem.trim(u8, rest, " \t").len == 0) {
            con.print(if (batch.echo_on) "ECHO is on\n" else "ECHO is off\n");
        } else if (std.ascii.eqlIgnoreCase(args, "ON") or std.ascii.eqlIgnoreCase(args, "OFF")) {
            batch.echo_on = std.ascii.eqlIgnoreCase(args, "ON");
        } else {
            filecmds.echo(if (rest[0] == ' ' or rest[0] == '.') rest[1..] else rest);
        }
    } else if (is(cmd, "SET")) {
        batch.cmdSet(raw_args);
    } else if (is(cmd, "PATH") or (line.len > 4 and std.ascii.eqlIgnoreCase(line[0..4], "PATH") and (line[4] == '=' or line[4] == ';'))) {
        batch.cmdPath(line[4..]);
    } else if (is(cmd, "PAUSE")) {
        batch.cmdPause();
    } else if (is(cmd, "CHOICE")) {
        batch.cmdChoice(raw_args);
    } else if (is(cmd, "CALL")) {
        if (raw_args.len == 0) con.print("Required parameter missing\n") else runLine(raw_args);
    } else if (is(cmd, "REM")) {
        // A comment:
    } else if (is(cmd, "DEL") or is(cmd, "RM") or is(cmd, "ERASE")) {
        filecmds.del(raw_args);
    } else if (is(cmd, "RD") or is(cmd, "RMDIR") or is(cmd, "DELTREE")) {
        filecmds.rd(raw_args);
    } else if (is(cmd, "COPY") or is(cmd, "CP") or is(cmd, "XCOPY")) {
        filecmds.copy(raw_args);
    } else if (is(cmd, "MOVE") or is(cmd, "MV") or is(cmd, "REN")) {
        filecmds.move(raw_args);
    } else if (is(cmd, "DATE")) {
        cmdDate(args);
    } else if (is(cmd, "EXIT")) {
        // In a batch file EXIT leaves the file (batch.zig); here it leaves a
        // second interpreter, but not the first:
        if (permanent) {
            con.print("EXIT only leaves a batch file or a second command interpreter. To turn off the computer, use SHUTDOWN.\n");
        } else {
            exit_code = std.fmt.parseInt(u8, args, 10) catch vars.errorlevel;
        }
    } else if (is(cmd, "TYPE") or is(cmd, "CAT")) {
        cmdType(args);
    } else if (is(cmd, "FIND")) {
        textcmds.find(raw_args);
    } else if (is(cmd, "FINDSTR")) {
        textcmds.findstr(raw_args);
    } else if (is(cmd, "SORT")) {
        textcmds.sort(raw_args);
    } else if (is(cmd, "FC")) {
        compare.fc(raw_args);
    } else if (is(cmd, "COMP")) {
        compare.comp(raw_args);
    } else if (is(cmd, "WHERE")) {
        cmdWhere(args);
    } else if (is(cmd, "WAIT")) {
        cmdWait(args);
    } else if (!runExternal(line)) {
        con.print("Bad command or file name\n");
    }
}

// REDIRECTION AND PIPES: as in DOS, piped commands run one after
// another, each one's output in a pipe in memory for the next

const max_stages = 8;

const Stage = struct {
    cmd: []const u8,
    in: ?[]const u8 = null, // < file
    out: ?[]const u8 = null, // > file or >> file
    append: bool = false,
    err: ?[]const u8 = null, // 2> file or 2>> file: the error output
    err_append: bool = false,
    err_to_out: bool = false, // 2>&1
    pager: bool = false, // its output goes to the MORE that -p added
};

pub fn runLine(raw: []const u8) void {
    const line = std.mem.trim(u8, raw, " \t");
    if (line.len == 0) return;
    // "PROGRAM args &": the program as a task, in the background:
    if (line[line.len - 1] == '&' and !inQuotes(line, line.len - 1)) {
        return runBackground(std.mem.trim(u8, line[0 .. line.len - 1], " \t"));
    }

    var stages: [max_stages + 1]Stage = undefined;
    var count: usize = 0;
    var quoted = false;
    var start: usize = 0;
    for (line, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if ((c == '|' and !quoted) or i == line.len - 1) {
            const end = if (c == '|' and !quoted) i else line.len;
            if (count == max_stages) return screenError("Too many commands joined by |\n");
            stages[count] = parseStage(line[start..end]) orelse return;
            count += 1;
            start = i + 1;
        }
    }
    if (line[line.len - 1] == '|') return screenError("Missing command after |\n");
    // DIR -p, TYPE -p: the same as ... | MORE:
    if (pagingSwitch(&stages[count - 1])) {
        // MORE takes over the redirection; it
        // passes the text through to a file:
        stages[count] = .{ .cmd = "MORE", .out = stages[count - 1].out, .append = stages[count - 1].append };
        stages[count - 1].out = null;
        stages[count - 1].pager = true;
        count += 1;
    }
    if (count == 1 and stages[0].in == null and stages[0].out == null and stages[0].err == null and !stages[0].err_to_out) return execute(stages[0].cmd);
    for (stages[0..count], 0..) |st, i| {
        if (st.cmd.len == 0) return screenError("Missing command before or after |\n");
        if (st.in != null and i > 0) return screenError("Only the first command can read a file (<)\n");
        if (st.out != null and i < count - 1) return screenError("Only the last command can write a file (> or >>)\n");
    }
    runStages(stages[0..count]);
}

// "SORT < in.txt > out.txt": names run to the next < or > (spaces
// allowed, quotes optional).
fn parseStage(text: []const u8) ?Stage {
    var st: Stage = .{ .cmd = "" };
    var cmd_end: ?usize = null;
    var quoted = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"') quoted = !quoted;
        if (quoted or (c != '<' and c != '>')) continue;
        // 2> (a word of its own): the error output:
        const to_err = c == '>' and i > 0 and text[i - 1] == '2' and (i == 1 or text[i - 2] == ' ' or text[i - 2] == '\t');
        if (cmd_end == null) cmd_end = if (to_err) i - 1 else i;
        const append = c == '>' and i + 1 < text.len and text[i + 1] == '>';
        if (to_err and !append and std.mem.startsWith(u8, text[i + 1 ..], "&1")) {
            st.err_to_out = true;
            i += 2;
            continue;
        }
        const name_start = i + @as(usize, if (append) 2 else 1);
        var name_end = name_start;
        var q = false;
        while (name_end < text.len) : (name_end += 1) {
            if (text[name_end] == '"') q = !q;
            if (!q and (text[name_end] == '<' or text[name_end] == '>')) break;
            // " 2>": the next redirection, not part of the name:
            if (!q and (text[name_end] == ' ' or text[name_end] == '\t') and std.mem.startsWith(u8, text[name_end + 1 ..], "2>")) break;
        }
        const name = std.mem.trim(u8, text[name_start..name_end], " \t");
        if (name.len == 0) {
            screenError("Missing file name after < or >\n");
            return null;
        }
        if (to_err) {
            if (st.err != null) {
                screenError("More than one 2> in a command\n");
                return null;
            }
            st.err = name;
            st.err_append = append;
        } else if (c == '<') {
            if (st.in != null) {
                screenError("More than one < in a command\n");
                return null;
            }
            st.in = name;
        } else {
            if (st.out != null) {
                screenError("More than one > in a command\n");
                return null;
            }
            st.out = name;
            st.append = append;
        }
        i = name_end - 1;
    }
    st.cmd = trim(text[0 .. cmd_end orelse text.len]);
    return st;
}

// Takes -p off and returns true.
fn pagingSwitch(st: *Stage) bool {
    var name_end: usize = 0;
    while (name_end < st.cmd.len and st.cmd[name_end] != ' ') : (name_end += 1) {}
    const name = st.cmd[0..name_end];
    const is = std.ascii.eqlIgnoreCase;
    if (!(is(name, "DIR") or is(name, "LS") or is(name, "TYPE") or is(name, "CAT"))) return false;
    // A "-p" word anywhere in the arguments:
    var i = name_end;
    while (i + 2 <= st.cmd.len) : (i += 1) {
        if (st.cmd[i] != '-' or std.ascii.toLower(st.cmd[i + 1]) != 'p') continue;
        if (st.cmd[i - 1] != ' ' or (i + 2 < st.cmd.len and st.cmd[i + 2] != ' ')) continue;
        const S = struct {
            var buf: [1024]u8 = undefined; // a whole command line
        };
        const before = std.mem.trimRight(u8, st.cmd[0..i], " ");
        const after = st.cmd[i + 2 ..];
        if (before.len + after.len > S.buf.len) return false;
        @memcpy(S.buf[0..before.len], before);
        @memcpy(S.buf[before.len..][0..after.len], after);
        st.cmd = S.buf[0 .. before.len + after.len];
        return true;
    }
    return false;
}

// NUL or NUL:, output to it is dropped, input from it is empty.
fn isNul(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " \t\"");
    return std.ascii.eqlIgnoreCase(n, "NUL") or std.ascii.eqlIgnoreCase(n, "NUL:");
}

fn runStages(stages: []const Stage) void {
    var in_file: ?zdos.File = null;
    var out_file: ?zdos.File = null;
    // What the first command reads and the last writes, if not the outer:
    var in_handle: ?i32 = null;
    var out_handle: ?i32 = null;
    if (stages[0].in) |name| {
        if (isNul(name)) {
            in_handle = sys.nul;
        } else {
            in_file = filecmds.openRedirect(name, .read) orelse return;
            in_handle = in_file.?.handle;
        }
    }
    const last = stages[stages.len - 1];
    if (last.out) |name| {
        if (isNul(name)) {
            out_handle = sys.nul;
        } else {
            out_file = filecmds.openRedirect(name, if (last.append) .append else .write) orelse {
                if (in_file) |f| f.close();
                return;
            };
            out_handle = out_file.?.handle;
        }
    }

    // The line may run inside a redirection (a batch file in a pipe): its
    // first command reads, its last writes, what the outer one gave:
    const outer_in = con.in_handle;
    const outer_out = con.out_handle;
    const outer_is_screen = !zdos.outputRedirected();

    // Stage i writes pipes[i % 2]; stage i + 1 reads it, then it is closed:
    var pipes = [2]?zdos.File{ null, null };
    for (stages, 0..) |st, i| {
        con.setInput(if (i == 0)
            (in_handle orelse outer_in)
        else
            pipes[(i - 1) % 2].?.handle);
        if (i < stages.len - 1) {
            const pipe = sys.createPipe() catch {
                con.setInput(outer_in);
                con.print("Not enough memory for the pipe\n");
                break;
            };
            pipes[i % 2] = pipe;
            con.setOutput(pipe.handle);
        } else con.setOutput(out_handle orelse outer_out);

        // 2> and 2>&1 for this command alone:
        var err_file: ?zdos.File = null;
        if (st.err_to_out) {
            sys.redirect(.err, zdos.SpawnOptions.caller_output) catch {};
        } else if (st.err) |name| {
            if (isNul(name)) {
                sys.redirect(.err, sys.nul) catch {};
            } else if (filecmds.openRedirect(name, if (st.err_append) .append else .write)) |f| {
                err_file = f;
                sys.redirect(.err, f.handle) catch {};
            }
        }
        // Colors for -p only when MORE shows them on the screen:
        con.colors_to_pager = st.pager and out_handle == null and outer_is_screen;
        execute(st.cmd);
        con.colors_to_pager = false;
        if (st.err_to_out or st.err != null) sys.redirect(.err, sys.inherited) catch {};
        if (err_file) |f| f.close();
        const stopped = con.breakRequested(); // Ctrl+C stops the whole pipe

        con.setOutput(outer_out);
        con.setInput(outer_in);
        if (i > 0) closePipe(&pipes[(i - 1) % 2], stages[i - 1].cmd);
        if (stopped) break;
    }
    for (pipes) |pipe| if (pipe) |p| p.close(); // not read: the pipe was stopped

    if (in_file) |f| f.closeChecked() catch |err| {
        con.printf("Read error: the input stopped early ({s})\n", .{fs.message(err)});
    };
    // Closing writes the file's size; a failure while writing it shows too:
    if (out_file) |f| f.closeChecked() catch |err| {
        con.printf("Write error: the file is incomplete ({s})\n", .{fs.message(err)});
    };
}

// Closing it tells whether some output was dropped.
fn closePipe(pipe: *?zdos.File, cmd: []const u8) void {
    const p = pipe.* orelse return;
    pipe.* = null;
    p.closeChecked() catch {
        con.print("Not enough memory for the whole output of ");
        con.print(cmd);
        con.print("; the rest was dropped\n");
    };
}

// Always on the screen.
fn screenError(msg: []const u8) void {
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print(msg);
}

// PROGRAMS AND BATCH FILES

// A program (.APP, or another extension given) or a batch file.
pub const Kind = enum { program, batch };

pub const Found = struct {
    path: fs.Path = .{}, // full
    kind: Kind,
};

// WHERE name: what NAME runs, then what else has that name further on
// (built-in, then the current folder, then PATH).
fn cmdWhere(args: []const u8) void {
    const name = std.mem.trim(u8, args, " \t\"");
    if (name.len == 0) {
        con.print("WHERE name\n");
        vars.errorlevel = 2;
        return;
    }
    var shown: usize = 0;
    for (command_names) |c| {
        if (std.ascii.eqlIgnoreCase(c, name)) {
            con.printf("{s}: built-in command\n", .{c});
            shown += 1;
        }
    }
    var seen: [16]fs.Path = undefined;
    var seen_count: usize = 0;
    var f: Found = .{ .kind = .program };
    if (findIn(name, &f)) {
        f.path.print();
        con.print("\n");
        seen[0] = f.path;
        seen_count = 1;
        shown += 1;
    }
    if (std.mem.indexOfAny(u8, name, ":\\/") == null) {
        var path_buf: vars.Buf = undefined;
        const path_var = vars.get("PATH", &path_buf) orelse "";
        var it: path_list.Iterator = .{ .value = path_var };
        dirs: while (it.next()) |raw| {
            const dir = std.mem.trim(u8, raw, " \t");
            if (dir.len == 0) continue;
            var buf: [fs.max_path]u8 = undefined;
            const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/' or dir[dir.len - 1] == ':') "" else "\\";
            const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, sep, name }) catch continue;
            if (!findIn(full, &f)) continue;
            // The same folder twice (the current one is in PATH too): once:
            for (seen[0..seen_count]) |*p| {
                if (std.ascii.eqlIgnoreCase(p.slice(), f.path.slice())) continue :dirs;
            }
            f.path.print();
            con.print("\n");
            if (seen_count < seen.len) {
                seen[seen_count] = f.path;
                seen_count += 1;
            }
            shown += 1;
        }
    }
    if (shown == 0) con.printf("Could not find {s}\n", .{name});
    vars.errorlevel = if (shown > 0) 0 else 1;
}

// "HELLO" tries HELLO.APP, .CMD, .BAT; a plain name is looked for in
// the current directory, then PATH (as ZDOS's exec does).
pub fn find(name: []const u8, out: *Found) bool {
    if (findIn(name, out)) return true;
    if (std.mem.indexOfAny(u8, name, ":\\/") != null) return false;
    var path_buf: vars.Buf = undefined;
    const path_var = vars.get("PATH", &path_buf) orelse return false;
    var it: path_list.Iterator = .{ .value = path_var };
    while (it.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \t");
        if (dir.len == 0) continue;
        var buf: [fs.max_path]u8 = undefined;
        const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/' or dir[dir.len - 1] == ':') "" else "\\";
        const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, sep, name }) catch continue;
        if (findIn(full, out)) return true;
    }
    return false;
}

fn findIn(path: []const u8, out: *Found) bool {
    var typed_buf: fs.TypedBuf = undefined;
    const name = fs.typedPath(path, &typed_buf);
    var has_ext = false;
    for (name) |c| switch (c) {
        '.' => has_ext = true,
        '\\', '/', ':' => has_ext = false,
        else => {},
    };
    if (has_ext) {
        const is_batch = std.ascii.endsWithIgnoreCase(name, ".CMD") or std.ascii.endsWithIgnoreCase(name, ".BAT");
        return check(name, if (is_batch) .batch else .program, out);
    }
    const kinds = [_]struct { ext: []const u8, kind: Kind }{
        .{ .ext = ".APP", .kind = .program },
        .{ .ext = ".CMD", .kind = .batch },
        .{ .ext = ".BAT", .kind = .batch },
    };
    for (kinds) |k| {
        var buf: [fs.max_path]u8 = undefined;
        const with_ext = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, k.ext }) catch continue;
        if (check(with_ext, k.kind, out)) return true;
    }
    return false;
}

fn check(name: []const u8, kind: Kind, out: *Found) bool {
    var p = fs.resolve(name) catch return false;
    if ((fs.kindOf(&p) catch null) != .file and !(anyCase(&p) and (fs.kindOf(&p) catch null) == .file)) return false;
    out.* = .{ .path = p, .kind = kind };
    return true;
}

// In any case, as on DOS, also on ext2 and Minix: the last part of p
// becomes the spelling in its folder.
fn anyCase(p: *fs.Path) bool {
    const s = p.slice();
    const cut = std.mem.lastIndexOfScalar(u8, s, '\\') orelse return false;
    var base_buf: [256]u8 = undefined;
    const base = s[cut + 1 ..];
    if (base.len == 0 or base.len > base_buf.len) return false;
    @memcpy(base_buf[0..base.len], base);
    var folder = p.*;
    folder.pop();
    const dir = zdos.openDir(folder.slice()) catch return false;
    defer dir.close();
    var e: zdos.DirEntry = undefined;
    while (dir.next(&e) catch return false) {
        const n = e.name();
        if (!std.ascii.eqlIgnoreCase(n, base_buf[0..base.len]) or std.mem.eql(u8, n, base_buf[0..base.len])) continue;
        var found = folder;
        if (!found.append(n)) return false;
        p.* = found;
        return true;
    }
    return false;
}

fn inQuotes(line: []const u8, at: usize) bool {
    var quoted = false;
    for (line[0..at]) |c| {
        if (c == '"') quoted = !quoted;
    }
    return quoted;
}

// WAIT without a number waits for them.
var background: [32]u32 = undefined;
var background_count: usize = 0;

// Collected, with their codes, for WAIT n afterwards: the last 32.
const Finished = struct { id: u32, code: u8 };
var finished: [32]Finished = undefined;
var finished_count: usize = 0;
var finished_next: usize = 0; // where the next one goes once all are used

// Before each prompt: ZDOS keeps only a few records; those programs
// left behind are collected quietly.
fn collectFinished() void {
    while (true) {
        const e = (sys.taskWaitAny(false) catch return) orelse return;
        const i = std.mem.indexOfScalar(u32, background[0..background_count], e.id) orelse continue;
        background[i] = background[background_count - 1];
        background_count -= 1;
        con.printf("[{d}] ended with code {d}\n", .{ e.id, e.code });
        remember(e.id, e.code);
    }
}

fn remember(id: u32, code: u8) void {
    if (finished_count < finished.len) {
        finished[finished_count] = .{ .id = id, .code = code };
        finished_count += 1;
        return;
    }
    finished[finished_next] = .{ .id = id, .code = code };
    finished_next = (finished_next + 1) % finished.len;
}

// Taken off the list.
fn takeFinished(id: u32) ?u8 {
    for (finished[0..finished_count], 0..) |f, i| {
        if (f.id != id) continue;
        finished[i] = finished[finished_count - 1];
        finished_count -= 1;
        finished_next = 0;
        return f.code;
    }
    return null;
}

// PROGRAM args &: its number is shown. Each program of a pipeline is a
// task of its own, joined by POSIX pipes.
fn runBackground(line: []const u8) void {
    if (line.len == 0) return screenError("Missing command before &\n");
    var stages: [max_stages]Stage = undefined;
    var count: usize = 0;
    var quoted = false;
    var start: usize = 0;
    for (line, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if ((c == '|' and !quoted) or i == line.len - 1) {
            const end = if (c == '|' and !quoted) i else line.len;
            if (count == max_stages) return screenError("Too many commands joined by |\n");
            stages[count] = parseStage(line[start..end]) orelse return;
            if (stages[count].cmd.len == 0) return screenError("Missing command before or after |\n");
            count += 1;
            start = i + 1;
        }
    }
    // Each stage's program, found first: nothing starts if one is missing:
    var paths: [max_stages]Found = undefined;
    for (stages[0..count], 0..) |st, i| {
        if (st.in != null and i > 0) return screenError("Only the first command can read a file (<)\n");
        if (st.out != null and i < count - 1) return screenError("Only the last command can write a file (> or >>)\n");
        const name = st.cmd[0..nameEnd(st.cmd)];
        if (!find(name, &paths[i])) return con.printf("Bad command or file name: {s}\n", .{name});
        if (paths[i].kind == .batch) return con.print("A batch file can't run in the background\n");
    }
    var input: i32 = zdos.SpawnOptions.no_stream;
    var opened: [3 * max_stages + 2]i32 = undefined;
    var n_opened: usize = 0;
    defer for (opened[0..n_opened]) |h| (zdos.File{ .handle = h }).close();
    if (stages[0].in) |name| {
        const f = zdos.open(name, .read) catch |err| return con.printf("{s}: {s}\n", .{ name, fs.message(err) });
        input = f.handle;
        opened[n_opened] = f.handle;
        n_opened += 1;
    }
    for (stages[0..count], 0..) |st, i| {
        var output: i32 = zdos.SpawnOptions.no_stream;
        var next_input: i32 = zdos.SpawnOptions.no_stream;
        if (i + 1 < count) {
            const p = sys.pipe() catch |err| return con.printf("Cannot make a pipe: {s}\n", .{fs.message(err)});
            output = p.write;
            next_input = p.read;
            opened[n_opened] = p.read;
            opened[n_opened + 1] = p.write;
            n_opened += 2;
        } else if (st.out) |name| {
            const f = openOutput(name, st.append) catch |err| return con.printf("{s}: {s}\n", .{ name, fs.message(err) });
            output = f.handle;
            opened[n_opened] = f.handle;
            n_opened += 1;
        }
        // 2>&1 where the output goes, 2> a file, else ours:
        var err_out: i32 = zdos.SpawnOptions.caller_error;
        if (st.err_to_out) {
            err_out = output;
        } else if (st.err) |name| {
            const f = openOutput(name, st.err_append) catch |err| return con.printf("{s}: {s}\n", .{ name, fs.message(err) });
            err_out = f.handle;
            opened[n_opened] = f.handle;
            n_opened += 1;
        }
        const name = st.cmd[0..nameEnd(st.cmd)];
        const args = std.mem.trim(u8, st.cmd[name.len..], " \t");
        const id = sys.taskSpawnWith(paths[i].path.slice(), args, .{ .input = input, .output = output, .err = err_out }) catch |err| {
            switch (err) {
                error.NotSupported => con.print("Tasks in the background aren't available here\n"),
                error.TooManyOpen => con.print("Too many tasks\n"),
                else => con.printf("Cannot start {s}: {s}\n", .{ name, fs.message(err) }),
            }
            return;
        };
        if (background_count < background.len) {
            background[background_count] = id;
            background_count += 1;
        }
        con.printf("[{d}] {s}\n", .{ id, name });
        input = next_input;
    }
}

// A space outside quotes.
fn nameEnd(cmd: []const u8) usize {
    var end: usize = 0;
    var quoted = false;
    while (end < cmd.len and (quoted or cmd[end] != ' ')) : (end += 1) {
        if (cmd[end] == '"') quoted = !quoted;
    }
    return end;
}

// > file (new or emptied) or >> file
fn openOutput(name: []const u8, append: bool) zdos.Error!zdos.File {
    const f = try zdos.open(name, if (append) .update else .write);
    if (append) f.seek(zdos.seek_end) catch {};
    return f;
}

// WAIT [n]: until task n (or every task started here) has ended; n may
// be one reported at a prompt. Its code becomes ERRORLEVEL.
fn cmdWait(args: []const u8) void {
    if (args.len > 0) {
        const id = std.fmt.parseInt(u32, args, 10) catch return con.print("WAIT [task number]\n");
        if (takeFinished(id)) |code| {
            con.printf("[{d}] ended with code {d}\n", .{ id, code });
            vars.errorlevel = code;
            return;
        }
        if (std.mem.indexOfScalar(u32, background[0..background_count], id)) |i| {
            background[i] = background[background_count - 1];
            background_count -= 1;
        }
        return waitFor(id);
    }
    for (background[0..background_count]) |id| waitFor(id);
    background_count = 0;
}

fn waitFor(id: u32) void {
    const code = sys.taskWait(id) catch {
        con.printf("Task {d}: not started here, or ended too long ago\n", .{id});
        return;
    };
    con.printf("[{d}] ended with code {d}\n", .{ id, code });
    vars.errorlevel = code;
}

// False if there is no such file.
fn runExternal(line: []const u8) bool {
    var end: usize = 0;
    var quoted = false;
    while (end < line.len and (quoted or line[end] != ' ')) : (end += 1) {
        if (line[end] == '"') quoted = !quoted;
    }
    const name = line[0..end];
    const args = std.mem.trim(u8, line[end..], " \t");
    var f: Found = undefined;
    if (!find(name, &f)) return false;
    if (f.kind == .batch) {
        batch.runFile(&f, name, args);
        return true;
    }
    const code = zdos.exec(f.path.slice(), args) catch |err| {
        switch (err) {
            error.NotFound => return false,
            error.NotSupported => con.print("Not a ZDOS program\n"),
            error.InvalidArgument => con.print("Invalid program file\n"),
            error.OutOfMemory => con.print("Not enough memory (or too many programs started by programs)\n"),
            else => con.printf("Cannot load {s}: {s}\n", .{ name, fs.message(err) }),
        }
        return true;
    };
    vars.errorlevel = code;
    resetScreen();
    if (code != 0) con.printf("Program exited with code {d}\n", .{code});
    return true;
}

// DATE [yyyy-mm-dd] [hh:mm[:ss][am|pm]]: without arguments asks.
fn cmdDate(args: []const u8) void {
    var t = zdos.getTime();
    if (t.year == 0) {
        con.print("Clock not available\n");
        return;
    }
    if (args.len == 0) {
        con.printf("Current date is {s} {d}-{d:0>2}-{d:0>2}\n", .{ datetime.weekdayName(t), t.year, t.month, t.day });
        con.printf("Current time is {d:0>2}:{d:0>2}:{d:0>2}\n", .{ t.hour, t.minute, t.second });
    }

    var line_buf: [64]u8 = undefined;
    var input = args;
    while (true) {
        if (input.len == 0) {
            if (args.len > 0) return;
            // The input starts under "yyyy" of the line above:
            const prev = con.toScreen();
            defer con.restore(prev);
            con.print("Enter new date and time (yyyy-mm-dd hh:mm[:ss][am|pm])\n");
            con.print("  or simply press enter: ");
            input = trim(lineedit.read(&line_buf, false));
            if (input.len == 0) return;
        }
        if (datetime.parse(input, &t)) {
            sys.setTime(t) catch |err| con.print(if (err == error.AccessDenied) "Only admins may set the clock\n" else "Unable to set the clock\n");
            return;
        }
        con.print("Invalid date or time\n");
        if (args.len > 0) return;
        input = &.{};
    }
}

fn cmdType(args: []const u8) void {
    if (args.len == 0) {
        con.print("Required parameter missing\n");
        return;
    }
    if (!driveOk(args)) return;
    const file = zdos.open(typed(args), .read) catch |err| {
        con.print(fs.message(err));
        con.print("\n");
        return;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    var keep: usize = 0; // start of a character split across two reads
    var last: u8 = '\n';
    while (true) {
        if (con.breakRequested()) return;
        const got = file.read(buf[keep..]) catch |err| {
            con.printf("\nRead error: {s}\n", .{fs.message(err)});
            return;
        };
        if (got == 0) break;
        // Keep text, line breaks and ESC; drop '\r' (the console turns '\n'
        // into a full line break) and other controls:
        var n: usize = 0;
        for (buf[0 .. keep + got]) |c| {
            if (c == '\r') continue;
            buf[n] = if (c >= 0x20 or c == '\n' or c == '\t' or c == 0x1B) c else '.';
            n += 1;
        }
        keep = incompleteTail(buf[0..n]);
        con.print(buf[0 .. n - keep]);
        if (n > keep) last = buf[n - keep - 1];
        std.mem.copyForwards(u8, buf[0..keep], buf[n - keep .. n]);
    }
    if (keep > 0) con.print(buf[0..keep]);
    if (last != '\n') con.print("\n");
}

fn incompleteTail(s: []const u8) usize {
    var back: usize = 0;
    while (back < 4 and back < s.len) {
        back += 1;
        const c = s[s.len - back];
        if (c & 0xC0 != 0x80) {
            const need = std.unicode.utf8ByteSequenceLength(c) catch return 0;
            return if (need > back) back else 0;
        }
    }
    return 0;
}

// Without quotes; valid until the next call.
fn typed(arg: []const u8) []const u8 {
    const S = struct {
        var buf: fs.TypedBuf = undefined;
    };
    return fs.typedPath(arg, &S.buf);
}

// False (after saying so) if the drive doesn't exist.
fn driveOk(arg: []const u8) bool {
    const letter = fs.driveOf(typed(arg)) orelse return true;
    if (fs.driveExists(letter)) return true;
    con.print("Invalid drive specification\n");
    return false;
}

// CD [D:] [PATH]
fn cmdCd(args: []const u8) void {
    if (!driveOk(args)) return;
    const path = typed(args);
    const letter = fs.driveOf(path);
    if (path.len == 0 or (letter != null and path.len == 2)) {
        // "C:\DOCS": the drive's current directory:
        const full = fs.resolve(path) catch |err| return con.printf("{s}\n", .{fs.message(err)});
        con.print(full.slice());
        con.print("\n");
        return;
    }
    // "CD D:\DOCS" also makes D: the current drive, unlike DOS:
    zdos.setCwd(path) catch |err| {
        switch (err) {
            error.PathNotFound, error.NotADirectory, error.NotFound => con.print("Invalid directory\n"),
            else => con.printf("{s}\n", .{fs.message(err)}),
        }
        return;
    };
}
