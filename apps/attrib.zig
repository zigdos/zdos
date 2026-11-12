// ATTRIB: shows or changes the R, A, S, H attributes. Never recursive.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const fs = @import("command/fs.zig");
const Attr = fs.Attr;
const Target = fs.Path;

comptime {
    _ = zdos;
}

const blanks = " \t";

var failed = false;

pub fn main(args: []const u8) u8 {
    var set: u8 = 0;
    var clear: u8 = 0;
    var rest = std.mem.trim(u8, args, blanks);
    // Flags at the start:
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, blanks) orelse rest.len;
        switch (parseFlag(rest[0..end], &set, &clear)) {
            .flag => rest = std.mem.trimLeft(u8, rest[end..], blanks),
            .not_flag => break,
            .invalid => return invalidFlag(rest[0..end]),
        }
    }
    // And at the end:
    while (rest.len > 0) {
        const start = if (std.mem.lastIndexOfAny(u8, rest, blanks)) |i| i + 1 else 0;
        switch (parseFlag(rest[start..], &set, &clear)) {
            .flag => rest = std.mem.trimRight(u8, rest[0..start], blanks),
            .not_flag => break,
            .invalid => return invalidFlag(rest[start..]),
        }
    }
    if (set & clear != 0) {
        zdos.print("Conflicting parameters: an attribute is both set and cleared\n");
        return 1;
    }

    const path = unquote(rest);
    var t = resolve(if (path.len == 0) "*" else path) orelse return 1;
    var count: usize = 0;
    if (fs.hasWildcard(t.name())) {
        var dir = t;
        dir.pop();
        var list = fs.listMatches(&dir, t.name(), .all) catch |err| {
            printError(err, &dir);
            return 1;
        };
        defer list.deinit();
        if (list.count == 0) return notFound();
        var it = list.iterator();
        while (it.next()) |name| {
            var child = dir;
            if (child.append(name)) attribOne(&child, set, clear, &count);
        }
        return @intFromBool(failed);
    }
    const kind = fs.kindOf(&t) catch |err| {
        printError(err, &t);
        return 1;
    };
    if (kind == null) return notFound();
    // The root has no attributes of its own: the entries in it
    if (t.isRoot()) attribInside(&t, set, clear, &count) else attribOne(&t, set, clear, &count);
    if (count == 0) return notFound();
    return @intFromBool(failed);
}

const Flag = enum { flag, not_flag, invalid };

// "+R", "-h", "+RH": a sign and attribute letters
fn parseFlag(tok: []const u8, set: *u8, clear: *u8) Flag {
    if (tok.len < 2 or (tok[0] != '+' and tok[0] != '-')) return .not_flag;
    var bits: u8 = 0;
    for (tok[1..]) |c| {
        bits |= switch (std.ascii.toUpper(c)) {
            'R' => Attr.read_only,
            'A' => Attr.archive,
            'S' => Attr.system,
            'H' => Attr.hidden,
            else => return .invalid,
        };
    }
    if (tok[0] == '+') set.* |= bits else clear.* |= bits;
    return .flag;
}

fn invalidFlag(tok: []const u8) u8 {
    zdos.print("Invalid parameter - ");
    zdos.print(tok);
    zdos.print("\n");
    return 1;
}

fn notFound() u8 {
    zdos.print("File not found\n");
    return 1;
}

// Only the folder itself:
fn attribOne(t: *const Target, set: u8, clear: u8, count: *usize) void {
    count.* += 1; // an error is reported here, not as "File not found" at the end
    const info = fs.entryInfo(t) catch |err| return printError(err, t);
    if (set | clear == 0) {
        showAttributes(t, info.attrs);
    } else {
        const new = (info.attrs & ~clear) | set;
        if (new != info.attrs) zdos.setAttributes(t.slice(), new) catch |err| {
            zdos.print("Unable to change the attributes of ");
            zdos.print(t.slice());
            zdos.print(": ");
            zdos.print(fs.message(err));
            zdos.print("\n");
            failed = true;
        };
    }
}

fn attribInside(dir: *const Target, set: u8, clear: u8, count: *usize) void {
    var list = fs.listMatches(dir, "*", .all) catch |err| return printError(err, dir);
    defer list.deinit();
    var it = list.iterator();
    while (it.next()) |name| {
        var child = dir.*;
        if (child.append(name)) attribOne(&child, set, clear, count);
    }
}

// "A  SHR     C:\ZIGDOS.SYS", as DOS's ATTRIB:
fn showAttributes(t: *const Target, attrs: u8) void {
    var col = "           ".*;
    if (attrs & Attr.archive != 0) col[0] = 'A';
    if (attrs & Attr.system != 0) col[3] = 'S';
    if (attrs & Attr.hidden != 0) col[4] = 'H';
    if (attrs & Attr.read_only != 0) col[5] = 'R';
    zdos.print(&col);
    zdos.print(t.slice());
    zdos.print("\n");
}

// "Access denied - C:\X.TXT", as DOS:
fn printError(err: fs.Error, t: *const Target) void {
    zdos.print(fs.message(err));
    zdos.print(" - ");
    zdos.print(t.slice());
    zdos.print("\n");
    failed = true;
}

fn resolve(arg: []const u8) ?Target {
    var buf: fs.TypedBuf = undefined;
    if (fs.driveOf(fs.typedPath(arg, &buf))) |letter| if (!fs.driveExists(letter)) {
        zdos.print("Invalid drive specification\n");
        return null;
    };
    return fs.resolve(arg) catch |err| {
        zdos.print(fs.message(err));
        zdos.print("\n");
        return null;
    };
}

fn unquote(arg: []const u8) []const u8 {
    const t = std.mem.trim(u8, arg, blanks);
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}
