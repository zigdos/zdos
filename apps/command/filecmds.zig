// MD, MKFILE, ECHO, DEL, RD, MOVE, COPY. Names with spaces need no
// quotes (see oneArg, twoArgs).
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const lineedit = @import("lineedit.zig");
const Grow = fs.Grow;

// "D:..\X", "My Folder", resolved to a full path.
const Target = fs.Path;

// "Access denied - C:\X.TXT", as DOS.
fn printError(err: fs.Error, t: *const Target) void {
    con.print(fs.message(err));
    con.print(" - ");
    t.print();
    con.print("\n");
}

// "Unable to move C:\X: Access denied"
fn printFailed(what: []const u8, t: *const Target, err: fs.Error) void {
    con.print(what);
    t.print();
    con.print(": ");
    con.print(fs.message(err));
    con.print("\n");
}

fn resolveQuiet(arg: []const u8) ?Target {
    return fs.resolve(arg) catch null;
}

// Prints an error and returns null if impossible.
fn resolve(arg: []const u8) ?Target {
    var buf: fs.TypedBuf = undefined;
    if (fs.driveOf(fs.typedPath(arg, &buf))) |letter| if (!fs.driveExists(letter)) {
        con.print("Invalid drive specification\n");
        return null;
    };
    return fs.resolve(arg) catch |err| {
        con.print(fs.message(err));
        con.print("\n");
        return null;
    };
}

const blanks = " \t";

// "A B" -> A B; quotes are only needed to make COPY/MOVE unambiguous.
fn unquote(arg: []const u8) []const u8 {
    const t = std.mem.trim(u8, arg, blanks);
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

// Everything after the command, spaces included.
fn oneArg(args: []const u8) ?[]const u8 {
    const a = unquote(args);
    if (a.len == 0) {
        con.print("Required parameter missing\n");
        return null;
    }
    return a;
}

// Without quotes the split is the space where the source exists ("COPY
// My Folder Backup"); several matches need quotes.
fn twoArgs(args: []const u8) ?[2][]const u8 {
    const s = std.mem.trim(u8, args, blanks);
    if (std.mem.indexOfScalar(u8, s, '"') != null) {
        // With quotes the first blank outside them ends the source, wherever
        // they are ("My Folder"\Sub "Backup Dir"):
        var quoted = false;
        const end = for (s, 0..) |c, i| {
            if (c == '"') quoted = !quoted;
            if (!quoted and (c == ' ' or c == '\t')) break i;
        } else s.len;
        const dst = std.mem.trim(u8, s[end..], blanks);
        if (dst.len == 0) {
            con.print("Required parameter missing\n");
            return null;
        }
        return .{ s[0..end], dst };
    }

    var found: ?[2][]const u8 = null;
    var splits: usize = 0;
    var matches: usize = 0;
    for (s, 0..) |c, i| {
        // Split only at the first blank of a run, so "A  B" is tried once:
        if ((c != ' ' and c != '\t') or i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t') continue;
        const src = s[0..i];
        const dst = unquote(s[i + 1 ..]);
        if (dst.len == 0) continue;
        splits += 1;
        var t = resolveQuiet(src) orelse continue;
        if (!exists(&t)) continue;
        matches += 1;
        found = .{ src, dst };
    }
    if (splits == 0) {
        con.print("Required parameter missing\n");
        return null;
    }
    if (matches > 1) {
        con.print("Ambiguous names, put them in quotes: \"from\" \"to\"\n");
        return null;
    }
    return found orelse {
        con.print("File not found\n");
        return null;
    };
}

// Set while a command runs with -y / -q: questions are answered "yes"
// without being shown.
var assume_yes = false;

// Off the start and the end of the arguments.
fn takeFlag(args: []const u8, flag: []const u8) struct { rest: []const u8, found: bool } {
    var rest = std.mem.trim(u8, args, blanks);
    var found = false;
    while (true) {
        const first = rest[0 .. std.mem.indexOfAny(u8, rest, blanks) orelse rest.len];
        if (first.len > 0 and std.ascii.eqlIgnoreCase(first, flag)) {
            rest = std.mem.trimLeft(u8, rest[first.len..], blanks);
            found = true;
            continue;
        }
        const last = rest[if (std.mem.lastIndexOfAny(u8, rest, blanks)) |i| i + 1 else 0..];
        if (last.len > 0 and last.len < rest.len and std.ascii.eqlIgnoreCase(last, flag)) {
            rest = std.mem.trimRight(u8, rest[0 .. rest.len - last.len], blanks);
            found = true;
            continue;
        }
        return .{ .rest = rest, .found = found };
    }
}

// Only Y or YES means yes. Shown on the screen even when
// the output is redirected.
fn confirm(comptime question: []const u8, t: *const Target) bool {
    if (assume_yes) return true;
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print(question ++ " ");
    t.print();
    return askYes();
}

// Confirmed with Enter, so a stray key press can't delete anything.
fn askYes() bool {
    con.print("? (Y/N) ");
    var buf: [8]u8 = undefined;
    const answer = std.mem.trim(u8, lineedit.read(&buf, false), blanks);
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

// WILDCARDS

// "D:\DOCS\*.TXT"
fn isPattern(t: *const Target) bool {
    return fs.hasWildcard(t.name());
}

// "D:\DOCS" for "D:\DOCS\*.TXT"
fn patternDir(t: *const Target) Target {
    var dir = t.*;
    dir.pop();
    return dir;
}

// Quietly: for finding where COPY's source name ends.
fn exists(t: *Target) bool {
    if (!isPattern(t)) return (fs.kindOf(t) catch null) != null;
    const dir = patternDir(t);
    var list = fs.listMatches(&dir, t.name(), .all) catch return false;
    defer list.deinit();
    return list.count > 0;
}

// Null if nothing; prints why if that can't be told.
fn kindOf(t: *const Target) error{Reported}!?fs.Kind {
    return fs.kindOf(t) catch |err| {
        printError(err, t);
        return error.Reported;
    };
}

// Prints why if there are none.
fn matchesOf(t: *const Target, dir: *const Target, sel: fs.Select) ?fs.NameList {
    var list = fs.listMatches(dir, t.name(), sel) catch |err| {
        printError(err, dir);
        return null;
    };
    if (list.count == 0) {
        list.deinit();
        con.print("File not found\n");
        return null;
    }
    return list;
}

fn isRoot(t: *const Target) bool {
    return t.isRoot();
}

pub fn md(args: []const u8) void {
    const a = oneArg(args) orelse return;
    var t = resolve(a) orelse return;
    if (kindOf(&t) catch return) |_| {
        con.print("A subdirectory or file ");
        t.print();
        con.print(" already exists\n");
        return;
    }
    zdos.makeDir(t.slice()) catch |err| printFailed("Unable to create directory ", &t, err);
}

pub fn mkfile(args: []const u8) void {
    const a = oneArg(args) orelse return;
    var t = resolve(a) orelse return;
    if (kindOf(&t) catch return) |_| {
        con.print("A subdirectory or file ");
        t.print();
        con.print(" already exists\n");
        return;
    }
    const f = zdos.open(t.slice(), .write) catch |err| return printFailed("Unable to create file ", &t, err);
    f.closeChecked() catch |err| printFailed("Unable to create file ", &t, err);
}

// > file goes through the shell's redirection.
pub fn echo(text: []const u8) void {
    con.print(text);
    con.print("\n");
}

// "< file", "> file" (emptied or created), ">> file". Prints why on failure.
pub fn openRedirect(name: []const u8, mode: enum { read, write, append }) ?zdos.File {
    const a = oneArg(name) orelse return null;
    // /dev/null, /dev/tty ...: ZDOS's devices, which have no full path:
    if (std.mem.startsWith(u8, a, "/dev/")) {
        return zdos.open(a, if (mode == .read) .read else .write) catch |err| {
            con.printf("Unable to open {s}: {s}\n", .{ a, zdos.message(err) });
            return null;
        };
    }
    var t = resolve(a) orelse return null;
    const kind = kindOf(&t) catch return null;
    if (kind == .dir) {
        t.print();
        con.print(" is a directory\n");
        return null;
    }
    if (mode == .read and kind == null) {
        con.print("File not found - ");
        t.print();
        con.print("\n");
        return null;
    }
    const f = zdos.open(t.slice(), switch (mode) {
        .read => .read,
        .write => .write,
        .append => .update,
    }) catch |err| {
        printFailed("Unable to open ", &t, err);
        return null;
    };
    if (mode == .append) f.seek(zdos.seek_end) catch |err| {
        f.close();
        printFailed("Unable to append to ", &t, err);
        return null;
    };
    return f;
}

// -a (all entries), -a:h / -ah (only hidden ones), like DOS's /A and /A:H.
// Null after an unknown switch.
pub fn selectSwitches(args: []const u8, sel: *fs.Select) ?[]const u8 {
    var rest = std.mem.trim(u8, args, blanks);
    var from_end = false;
    while (rest.len > 0) {
        const tok = if (from_end)
            rest[if (std.mem.lastIndexOfAny(u8, rest, blanks)) |i| i + 1 else 0..]
        else
            rest[0 .. std.mem.indexOfAny(u8, rest, blanks) orelse rest.len];
        if (tok.len < 2 or tok[0] != '-') {
            if (from_end) break;
            from_end = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(tok, "-a")) {
            sel.* = .all;
        } else if (std.ascii.eqlIgnoreCase(tok, "-a:h") or std.ascii.eqlIgnoreCase(tok, "-ah")) {
            sel.* = .hidden;
        } else {
            con.print("Invalid switch - ");
            con.print(tok);
            con.print("\n");
            return null;
        }
        rest = if (from_end)
            std.mem.trimRight(u8, rest[0 .. rest.len - tok.len], blanks)
        else
            std.mem.trimLeft(u8, rest[tok.len..], blanks);
    }
    return rest;
}

// A hidden file or folder without -a, or (-a:h) a file not hidden.
fn notSelected(t: *const Target, sel: fs.Select) void {
    t.print();
    con.print(if (sel == .hidden) " is not hidden\n" else " is hidden (use -a)\n");
}

// DEL [-a|-a:h] path: a file, or a folder with everything in it.
// -a:h on a folder deletes the hidden entries inside it.
pub fn del(args: []const u8) void {
    const q = takeFlag(args, "-q"); // don't ask
    assume_yes = q.found;
    defer assume_yes = false;
    var sel: fs.Select = .visible;
    const rest = selectSwitches(q.rest, &sel) orelse return;
    const a = oneArg(rest) orelse return;
    var t = resolve(a) orelse return;
    if (isPattern(&t)) return delMany(&t, sel);
    const info = fs.entryInfo(&t) catch |err| return printError(err, &t);
    if (!sel.takes(info.attrs)) return notSelected(&t, sel);
    deleteAsking(&t);
}

// RD / RMDIR / DELTREE: like DEL, but a file is refused, so a typo
// can't delete one.
pub fn rd(args: []const u8) void {
    const y = takeFlag(args, "-y"); // don't ask
    assume_yes = y.found;
    defer assume_yes = false;
    var sel: fs.Select = .visible;
    const rest = selectSwitches(y.rest, &sel) orelse return;
    const a = oneArg(rest) orelse return;
    var t = resolve(a) orelse return;
    if (isPattern(&t)) {
        con.print("Wildcards are not allowed here; use DEL\n");
        return;
    }
    const info = fs.entryInfo(&t) catch |err| {
        if (err == error.NotFound) {
            con.print("Directory not found\n");
            return;
        }
        return printError(err, &t);
    };
    if (!info.is_dir) {
        t.print();
        con.print(" is not a directory\n");
        return;
    }
    if (!sel.takes(info.attrs)) return notSelected(&t, sel);
    deleteAsking(&t);
}

// Hidden entries too, after asking; the root is refused.
fn deleteAsking(t: *const Target) void {
    if (isRoot(t)) {
        con.print("Cannot delete the root directory\n");
        return;
    }
    if (!confirm("Delete", t)) return;
    var r: fs.DeleteResult = .{};
    fs.deleteAll(t, &r);
    reportDelete(&r, t);
}

fn reportDelete(r: *const fs.DeleteResult, t: *const Target) void {
    if (r.failed) {
        con.print("Could not delete everything in ");
        t.print();
        if (r.err) |err| {
            con.print(": ");
            con.print(fs.message(err));
        }
        con.print("\n");
    }
}

// COPY with a wildcard or of a folder lists each file, as DOS's COPY
// and XCOPY (a single file only gets the count).
var show_names = false;

// An existing destination folder gets the source inside it.
const Pair = struct { src: Target, dst: Target };

fn getPair(a: [2][]const u8) ?Pair {
    var src = resolve(a[0]) orelse return null;
    var dst = resolve(a[1]) orelse return null;
    if ((kindOf(&src) catch return null) == null) {
        con.print("File not found\n");
        return null;
    }
    if (isRoot(&src)) {
        con.print("Cannot use the root directory as the source\n");
        return null;
    }
    if ((kindOf(&dst) catch return null) == .dir) {
        if (!dst.append(src.name())) {
            con.print("Path too long\n");
            return null;
        }
    }
    if (fs.isInside(dst.slice(), src.slice())) {
        con.print("Cannot copy or move ");
        src.print();
        con.print(" into itself\n");
        return null;
    }
    return .{ .src = src, .dst = dst };
}

// MOVE [-y] [-a|-a:h] from to: replaces an existing file after asking
// (as DOS 6.22).
pub fn move(args: []const u8) void {
    const y = takeFlag(args, "-y");
    assume_yes = y.found;
    defer assume_yes = false;
    var sel: fs.Select = .visible;
    const rest = selectSwitches(y.rest, &sel) orelse return;
    const a = twoArgs(rest) orelse return;
    if (fs.hasWildcard(fs.lastComponent(a[0]))) return moveMany(a, sel);
    if (caseOnlyRename(a)) return;
    var p = getPair(a) orelse return;
    if (!roomFor(&p)) return;
    const is_dir = (kindOf(&p.src) catch return) == .dir;
    if (p.src.drive() == p.dst.drive()) {
        zdos.move(p.src.slice(), p.dst.slice()) catch |err| return printFailed("Unable to move ", &p.src, err);
    } else {
        // Different drives: copy, then delete the original:
        show_names = is_dir;
        defer show_names = false;
        var count: usize = 0;
        if (!copyTree(&p.src, &p.dst, &count)) return;
        zdos.deleteTree(p.src.slice()) catch |err| printFailed("Copied, but could not delete the original ", &p.src, err);
    }
    printMoved(@intFromBool(!is_dir), @intFromBool(is_dir));
}

// "3 file(s) moved", "1 dir(s) moved", "2 file(s) and 1 dir(s) moved"
fn printMoved(files: usize, dirs: usize) void {
    if (dirs == 0) {
        con.printf("{d} file(s) moved\n", .{files});
    } else if (files == 0) {
        con.printf("{d} dir(s) moved\n", .{dirs});
    } else {
        con.printf("{d} file(s) and {d} dir(s) moved\n", .{ files, dirs });
    }
}

// An existing file there is deleted after asking (MOVE -y: without).
// Answered no: false, quietly.
fn roomFor(p: *const Pair) bool {
    const kind = (kindOf(&p.dst) catch return false) orelse return true;
    if (std.ascii.eqlIgnoreCase(p.src.slice(), p.dst.slice())) {
        con.print("Cannot move ");
        p.src.print();
        con.print(" onto itself\n");
        return false;
    }
    if (kind == .file and (kindOf(&p.src) catch return false) == .file) {
        if (!confirm("Overwrite", &p.dst)) return false;
        zdos.deleteTree(p.dst.slice()) catch |err| {
            printFailed("Cannot replace ", &p.dst, err);
            return false;
        };
        return true;
    }
    p.dst.print();
    con.print(" already exists\n");
    return false;
}

// COPY [-y] [-a|-a:h] from to
pub fn copy(args: []const u8) void {
    const y = takeFlag(args, "-y");
    assume_yes = y.found;
    defer assume_yes = false;
    var sel: fs.Select = .visible;
    const rest = selectSwitches(y.rest, &sel) orelse return;
    // COPY CON file: from the keyboard:
    const first_end = std.mem.indexOfAny(u8, rest, blanks) orelse rest.len;
    const first = rest[0..first_end];
    if (std.ascii.eqlIgnoreCase(first, "CON") or std.ascii.eqlIgnoreCase(first, "CON:")) {
        return copyFromConsole(rest[first_end..]);
    }
    const a = twoArgs(rest) orelse return;
    if (fs.hasWildcard(fs.lastComponent(a[0]))) return copyMany(a, sel);
    var p = getPair(a) orelse return;
    // One file: only the count, as DOS; a folder: each file it copies:
    show_names = (kindOf(&p.src) catch return) == .dir;
    defer show_names = false;
    var count: usize = 0;
    _ = copyTree(&p.src, &p.dst, &count);
    con.printf("{d} file(s) copied\n", .{count});
}

// Until Ctrl+Z or F6, with DOS line ends. Collected in memory first, so
// Ctrl+C creates nothing.
fn copyFromConsole(dest: []const u8) void {
    const name = unquote(dest);
    if (name.len == 0) {
        con.print("Required parameter missing\n");
        return;
    }
    var t = resolve(name) orelse return;
    const kind = kindOf(&t) catch return;
    if (kind == .dir) {
        t.print();
        con.print(" is a directory\n");
        return;
    }
    if (kind == .file and !confirm("Overwrite", &t)) return;

    var text: Grow(u8) = .{};
    defer text.deinit();
    if (zdos.inputRedirected()) {
        var buf: [4096]u8 = undefined;
        while (true) {
            if (con.breakRequested()) return;
            const n = zdos.readInput(&buf);
            if (n == 0) break;
            const part = buf[0..n];
            const stop = std.mem.indexOfScalar(u8, part, 0x1A); // Ctrl+Z: the end
            if (!text.append(part[0 .. stop orelse n])) return con.print("Not enough memory\n");
            if (stop != null) break;
        }
    } else {
        var line_buf: [1024]u8 = undefined;
        while (true) {
            var ended = false;
            const line = lineedit.readText(&line_buf, &ended);
            if (con.breakRequested()) return; // Ctrl+C: nothing is written
            if (!text.append(line)) return con.print("Not enough memory\n");
            if (ended) break;
            if (!text.append("\r\n")) return con.print("Not enough memory\n");
        }
    }

    const f = zdos.open(t.slice(), .write) catch |err| return printFailed("Unable to create file ", &t, err);
    f.writeAll(text.slice()) catch |err| {
        f.close();
        return printFailed("Unable to write ", &t, err);
    };
    f.closeChecked() catch |err| return printFailed("Unable to write ", &t, err);
    con.print("1 file(s) copied\n");
}

// "MV readme.txt Readme.txt": false if that's not the case.
fn caseOnlyRename(a: [2][]const u8) bool {
    const src = resolveQuiet(a[0]) orelse return false;
    if (isRoot(&src) or (fs.kindOf(&src) catch null) == null) return false;
    const dst = resolveQuiet(a[1]) orelse return false;
    // Both resolve to the on-disk spelling: the same file, the same path:
    if (!std.mem.eql(u8, dst.slice(), src.slice())) return false;
    var typed_buf: fs.TypedBuf = undefined;
    const typed = fs.lastComponent(fs.typedPath(a[1], &typed_buf));
    const current = src.name();
    if (std.mem.eql(u8, typed, current) or !std.ascii.eqlIgnoreCase(typed, current)) return false;
    const is_dir = (fs.kindOf(&src) catch null) == .dir;
    // ZDOS renames it when only the capitalization differs:
    var to = src;
    to.pop();
    if (!to.append(typed)) return false;
    zdos.move(src.slice(), to.slice()) catch |err| {
        printFailed("Unable to rename ", &src, err);
        return true;
    };
    printMoved(@intFromBool(!is_dir), @intFromBool(is_dir));
    return true;
}

// One question for every match sel takes.
fn delMany(t: *const Target, sel: fs.Select) void {
    const dir = patternDir(t);
    defer reportHiddenLeft(t, &dir, sel, "kept; use -a to delete them too");
    var list = matchesOf(t, &dir, sel) orelse return;
    defer list.deinit();
    const files = list.count - list.dirs;
    if (!assume_yes) {
        const prev = con.toScreen();
        defer con.restore(prev);
        con.printf("Delete {d} file(s)", .{files});
        if (list.dirs > 0) con.printf(" and {d} dir(s)", .{list.dirs});
        con.print(" matching ");
        t.print();
        if (!askYes()) return;
    }

    var r: fs.DeleteResult = .{};
    var it = list.iterator();
    while (it.next()) |name| {
        if (con.breakRequested()) return;
        var child = dir;
        if (!child.append(name)) continue;
        const failed_before = r.failed;
        r.failed = false;
        r.err = null;
        fs.deleteAll(&child, &r);
        if (r.failed) {
            con.print("Could not delete ");
            child.print();
            if (r.err) |err| {
                con.print(": ");
                con.print(fs.message(err));
            }
            con.print("\n");
        }
        r.failed = r.failed or failed_before;
    }
}

// The destination must be an existing folder, not the source folder.
fn patternDest(a: [2][]const u8, src: *const Target, dir: *const Target) ?Target {
    var dst = resolve(a[1]) orelse return null;
    if ((kindOf(&dst) catch return null) != .dir) {
        con.print("The destination must be an existing directory\n");
        return null;
    }
    if (std.ascii.eqlIgnoreCase(dst.slice(), dir.slice())) {
        con.print("Cannot copy or move ");
        src.print();
        con.print(" onto itself\n");
        return null;
    }
    return dst;
}

fn namedPair(dir: *const Target, dst: *const Target, name: []const u8) ?Pair {
    var p: Pair = .{ .src = dir.*, .dst = dst.* };
    if (!p.src.append(name) or !p.dst.append(name)) {
        con.print("Path too long\n");
        return null;
    }
    if (fs.isInside(p.dst.slice(), p.src.slice())) {
        con.print("Cannot copy or move ");
        p.src.print();
        con.print(" into itself\n");
        return null;
    }
    return p;
}

// How many hidden matches were left alone.
fn reportHiddenLeft(t: *const Target, dir: *const Target, sel: fs.Select, comptime what: []const u8) void {
    if (sel != .visible) return;
    var hidden = fs.listMatches(dir, t.name(), .hidden) catch return;
    defer hidden.deinit();
    if (hidden.count > 0) con.printf("{d} hidden file(s) or dir(s) " ++ what ++ "\n", .{hidden.count});
}

fn copyMany(a: [2][]const u8, sel: fs.Select) void {
    const src = resolve(a[0]) orelse return;
    const dir = patternDir(&src);
    var dst = patternDest(a, &src, &dir) orelse return;
    defer reportHiddenLeft(&src, &dir, sel, "skipped; use -a to include them");
    var list = matchesOf(&src, &dir, sel) orelse return;
    defer list.deinit();
    show_names = true;
    defer show_names = false;
    var count: usize = 0;
    var it = list.iterator();
    while (it.next()) |name| {
        if (con.breakRequested()) break;
        var p = namedPair(&dir, &dst, name) orelse continue;
        _ = copyTree(&p.src, &p.dst, &count);
    }
    con.printf("{d} file(s) copied\n", .{count});
}

fn moveMany(a: [2][]const u8, sel: fs.Select) void {
    const src = resolve(a[0]) orelse return;
    const dir = patternDir(&src);
    var dst = patternDest(a, &src, &dir) orelse return;
    defer reportHiddenLeft(&src, &dir, sel, "skipped; use -a to include them");
    var list = matchesOf(&src, &dir, sel) orelse return;
    defer list.deinit();
    var files: usize = 0;
    var dirs: usize = 0;
    defer printMoved(files, dirs);
    var it = list.iterator();
    while (it.next()) |name| {
        if (con.breakRequested()) break;
        var p = namedPair(&dir, &dst, name) orelse continue;
        if (!roomFor(&p)) continue;
        const is_dir = (kindOf(&p.src) catch continue) == .dir;
        // Each entry as it is moved, as DOS's and Windows' MOVE:
        p.src.print();
        con.print("\n");
        if (p.src.drive() == p.dst.drive()) {
            zdos.move(p.src.slice(), p.dst.slice()) catch |err| {
                printFailed("Unable to move ", &p.src, err);
                continue;
            };
        } else {
            var count: usize = 0;
            if (!copyTree(&p.src, &p.dst, &count)) continue;
            zdos.deleteTree(p.src.slice()) catch |err| printFailed("Copied, but could not delete ", &p.src, err);
        }
        if (is_dir) dirs += 1 else files += 1;
    }
}

// Without recursion (see fs.Stack). Existing files are replaced after
// asking, folders merged.
fn copyTree(src: *Target, dst: *Target, count: *usize) bool {
    const Frame = struct {
        list: fs.NameList,
        it: fs.NameIterator,
        s_len: usize,
        d_len: usize,
    };
    var stack: fs.Stack(Frame) = .{};
    defer {
        while (stack.top()) |f| {
            f.list.deinit();
            stack.pop();
        }
        stack.deinit();
    }
    var s: Target = src.*;
    var d: Target = dst.*;
    var pending = true; // s is an entry still to copy to d
    while (true) {
        if (con.breakRequested()) return false; // Ctrl+C: what is copied stays
        if (pending) {
            pending = false;
            switch (copyEntry(&s, &d, count)) {
                .failed => return false,
                .done => {},
                .folder => {
                    var list = fs.listMatches(&s, "*", .all) catch |err| {
                        printError(err, &s);
                        return false;
                    };
                    stack.push(.{ .list = list, .it = list.iterator(), .s_len = s.len, .d_len = d.len }) catch |err| {
                        list.deinit();
                        printError(err, &s);
                        return false;
                    };
                },
            }
        }
        const f = stack.top() orelse return true;
        if (f.it.next()) |name| {
            s.len = f.s_len;
            d.len = f.d_len;
            if (!s.append(name) or !d.append(name)) {
                con.print("Path too long\n");
                return false;
            }
            pending = true;
        } else {
            f.list.deinit();
            stack.pop();
        }
    }
}

// A file is copied (or skipped if not to overwrite), a folder made if
// needed, then its entries follow.
fn copyEntry(src: *const Target, dst: *const Target, count: *usize) enum { done, folder, failed } {
    const dst_kind = kindOf(dst) catch return .failed;
    if ((kindOf(src) catch return .failed) == .file) {
        if (dst_kind == .dir) {
            dst.print();
            con.print(" is a directory\n");
            return .failed;
        }
        if (dst_kind == .file and !confirm("Overwrite", dst)) return .done;
        if (show_names) {
            src.print();
            con.print("\n");
        }
        fs.copyFile(src, dst) catch |err| {
            printFailed("Unable to copy ", src, err);
            return .failed;
        };
        count.* += 1;
        return .done;
    }
    if (dst_kind == .file) {
        dst.print();
        con.print(" is a file\n");
        return .failed;
    }
    if (dst_kind == null) zdos.makeDir(dst.slice()) catch |err| {
        printFailed("Unable to create directory ", dst, err);
        return .failed;
    };
    return .folder;
}
