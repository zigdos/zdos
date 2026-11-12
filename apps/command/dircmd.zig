// DIR. -p is turned into "| MORE" by the shell; into a file or another
// pipe DIR writes plain text.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const Grow = fs.Grow;

const Opts = struct {
    show: fs.Select = .visible,
    wide: bool = false,
    bare: bool = false,
    subdirs: bool = false,
    sort: []const u8 = "GN", // the default: folders first, then by name
};

const Item = struct {
    name_off: u32,
    name_len: u32,
    is_dir: bool,
    attrs: u8,
    size: u64,
    modified: zdos.Time,
};

// Names kept together in one buffer.
const Listing = struct {
    items: Grow(Item) = .{},
    names: Grow(u8) = .{},

    fn name(self: *const Listing, it: Item) []const u8 {
        return self.names.slice()[it.name_off..][0..it.name_len];
    }

    fn deinit(self: *Listing) void {
        self.items.deinit();
        self.names.deinit();
    }
};

const Totals = struct {
    files: u64 = 0,
    dirs: u64 = 0,
    bytes: u64 = 0,
};

const State = struct {
    drive: u8, // its letter
    pattern: ?[]const u8,
    o: *const Opts,
    grand: Totals = .{},
    found: bool = false,
    failed: bool = false, // a folder couldn't be read (and that was said)
    volume_shown: bool = false,
};

// "File not found", or why the folder can't be listed.
fn notFound(err: fs.Error) void {
    con.print(switch (err) {
        error.NotFound, error.PathNotFound, error.NotADirectory => "File not found",
        else => fs.message(err),
    });
    con.print("\n");
}

pub fn run(all_args: []const u8) void {
    var o: Opts = .{};
    const args = switches(all_args, &o) orelse return;

    // The drive, the folder and ("DIR *.TXT", "DIR NOTES.TXT") the pattern:
    var typed_buf: fs.TypedBuf = undefined;
    const target = fs.typedPath(args, &typed_buf);
    if (fs.driveOf(target)) |letter| if (!fs.driveExists(letter)) {
        con.print("Invalid drive specification\n");
        return;
    };
    var dir_arg = target;
    var pattern: ?[]const u8 = null;
    const last = fs.lastComponent(target);
    if (fs.hasWildcard(last)) {
        pattern = last;
        dir_arg = target[0 .. target.len - last.len];
    }
    const path = fs.resolveDir(dir_arg) catch |err| blk: {
        // "DIR NOTES.TXT": as in DOS, list its folder showing only that file:
        if (err != error.NotADirectory or pattern != null or last.len == 0) {
            return notFound(err);
        }
        pattern = last;
        break :blk fs.resolveDir(target[0 .. target.len - last.len]) catch |e| return notFound(e);
    };

    var st: State = .{ .drive = path.drive(), .pattern = pattern, .o = &o };
    listTree(&st, &path);
    if (con.breakRequested()) return; // Ctrl+C: no totals
    if (!st.found) {
        if (!st.failed) con.print("File not found\n");
        return;
    }

    if (o.bare) return;
    const free = if (fs.volumeInfo(st.drive)) |v| v.free else null;
    if (o.subdirs) {
        con.print(" Total files listed:\n");
        printFiles(st.grand);
    }
    con.print(" ");
    con.printNum(st.grand.dirs, 0);
    con.print(" Dir(s)");
    if (free) |f| {
        con.print(", ");
        con.printNum(f, 0);
        con.print(" bytes free");
    }
    con.print("\n\n");
}

// At the start and the end of the arguments.
fn switches(args: []const u8, o: *Opts) ?[]const u8 {
    var rest = std.mem.trim(u8, args, " \t");
    var from_end = false;
    while (rest.len > 0) {
        const tok = if (from_end)
            rest[if (std.mem.lastIndexOfAny(u8, rest, " \t")) |i| i + 1 else 0..]
        else
            rest[0 .. std.mem.indexOfAny(u8, rest, " \t") orelse rest.len];
        if (tok.len < 2 or tok[0] != '-') {
            if (from_end) break;
            from_end = true;
            continue;
        }
        const is = std.ascii.eqlIgnoreCase;
        if (is(tok, "-a")) {
            o.show = .all;
        } else if (is(tok, "-a:h") or is(tok, "-ah")) {
            o.show = .hidden;
        } else if (is(tok, "-w")) {
            o.wide = true;
        } else if (is(tok, "-b")) {
            o.bare = true;
        } else if (is(tok, "-s")) {
            o.subdirs = true;
        } else if (tok[1] == 'o' or tok[1] == 'O') {
            var keys = tok[2..];
            if (keys.len > 0 and keys[0] == ':') keys = keys[1..];
            if (keys.len == 0) keys = "GN";
            for (keys) |k| {
                if (std.mem.indexOfScalar(u8, "NESDGnesdg-", k) == null) {
                    con.print("Invalid sort order - ");
                    con.print(tok);
                    con.print(" (keys: N E S D G, - reverses)\n");
                    return null;
                }
            }
            o.sort = keys;
        } else {
            con.print("Invalid switch - ");
            con.print(tok);
            con.print("\n");
            return null;
        }
        rest = if (from_end)
            std.mem.trimRight(u8, rest[0 .. rest.len - tok.len], " \t")
        else
            std.mem.trimLeft(u8, rest[tok.len..], " \t");
    }
    return rest;
}

// With -s then every folder below it, each before the ones inside it;
// without recursion (see fs.Stack).
fn listTree(st: *State, path: *const fs.Path) void {
    const Frame = struct {
        subdirs: fs.NameList,
        it: fs.NameIterator,
        len: usize,
    };
    var stack: fs.Stack(Frame) = .{};
    defer {
        while (stack.top()) |f| {
            f.subdirs.deinit();
            stack.pop();
        }
        stack.deinit();
    }
    var cur: fs.Path = path.*;
    var pending = true; // cur is a folder still to list
    while (true) {
        if (con.breakRequested()) return;
        if (pending) {
            pending = false;
            var subdirs = listFolder(st, &cur);
            if (subdirs.count == 0) {
                subdirs.deinit();
            } else {
                stack.push(.{ .subdirs = subdirs, .it = subdirs.iterator(), .len = cur.len }) catch {
                    subdirs.deinit();
                    con.print("Not enough memory for the folders below\n");
                };
            }
        }
        const f = stack.top() orelse return;
        if (f.it.next()) |name| {
            cur.len = f.len;
            if (cur.append(name)) pending = true;
        } else {
            f.subdirs.deinit();
            stack.pop();
        }
    }
}

// With -s returns its subfolders, for listTree to go into next.
fn listFolder(st: *State, path: *const fs.Path) fs.NameList {
    var subdirs: fs.NameList = .{};
    var l: Listing = .{};
    defer l.deinit();
    collect(path, st.o.show, &l) catch |err| {
        con.printf("Cannot read {s}: {s}\n", .{ path.slice(), fs.message(err) });
        st.failed = true;
        return subdirs;
    };

    // The entries to show, sorted:
    var shown: Grow(u32) = .{};
    defer shown.deinit();
    for (l.items.slice(), 0..) |it, i| {
        const name = l.name(it);
        if (st.pattern) |pt| if (!fs.matches(pt, name)) continue;
        if (st.o.bare and (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))) continue;
        if (!shown.append(&.{@intCast(i)})) break;
    }
    const order = shown.slice();
    std.mem.sort(u32, order, SortCtx{ .l = &l, .keys = st.o.sort }, lessThan);

    if (order.len > 0) {
        st.found = true;
        const t = show(st, path, &l, order);
        st.grand.files += t.files;
        st.grand.dirs += t.dirs;
        st.grand.bytes += t.bytes;
    }

    if (!st.o.subdirs) return subdirs;
    for (l.items.slice()) |it| {
        const name = l.name(it);
        if (!it.is_dir or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!subdirs.add(name)) {
            con.print("Not enough memory for the folders below\n");
            break;
        }
    }
    return subdirs;
}

fn collect(path: *const fs.Path, sel: fs.Select, l: *Listing) fs.Error!void {
    var it = try fs.openDir(path);
    defer it.close();
    while (try it.next()) |e| {
        if (!sel.takes(e.attrs)) continue;
        const name = e.name();
        const off: u32 = @intCast(l.names.len);
        if (!l.names.append(name)) return error.OutOfMemory;
        const item: Item = .{ .name_off = off, .name_len = @intCast(name.len), .is_dir = e.is_dir, .attrs = e.attrs, .size = e.size, .modified = e.modified };
        if (!l.items.append(&.{item})) return error.OutOfMemory;
    }
}

// As ANSI codes, so they reach MORE for DIR -p too; 39 goes back to the
// normal text color and keeps the background.
fn printName(it: Item, name: []const u8, before: []const u8, after: []const u8) void {
    const code = if (con.colorsWanted()) nameColor(it, name) else null;
    if (code) |c| con.print(c);
    con.print(before);
    con.print(name);
    con.print(after);
    if (code != null) con.print("\x1b[39m");
}

fn nameColor(it: Item, name: []const u8) ?[]const u8 {
    if (it.is_dir) return "\x1b[94m"; // light blue
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    if (dot) |d| {
        const ext = name[d + 1 ..];
        for ([_][]const u8{ "APP", "CMD", "BAT", "EXE", "SH" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return "\x1b[92m"; // light green
        }
    }
    if (it.attrs & fs.Attr.system != 0) return "\x1b[93m"; // yellow
    if (it.attrs & fs.Attr.archive != 0) return "\x1b[91m"; // light red
    return null;
}

// The header, entries and totals (unless bare).
fn show(st: *State, path: *const fs.Path, l: *const Listing, order: []const u32) Totals {
    var t: Totals = .{};
    var width: usize = "<DIR>".len;
    var longest: usize = 0;
    for (order) |i| {
        const it = l.items.slice()[i];
        if (it.is_dir) {
            t.dirs += 1;
        } else {
            t.files += 1;
            t.bytes += it.size;
            width = @max(width, numWidth(it.size));
        }
        longest = @max(longest, l.name(it).len + @as(usize, if (it.is_dir) 2 else 0));
    }

    if (st.o.bare) {
        for (order) |i| {
            if (con.breakRequested()) break;
            if (st.o.subdirs) {
                con.print(path.slice());
                if (!path.isRoot()) con.print("\\");
            }
            const it = l.items.slice()[i];
            printName(it, l.name(it), "", "");
            con.print("\n");
        }
        return t;
    }

    if (!st.volume_shown) {
        st.volume_shown = true;
        con.printf(" Volume in drive {c} ", .{st.drive});
        if (fs.volumeInfo(st.drive)) |v| {
            if (v.label_len > 0) {
                con.print("is ");
                con.print(v.label());
            } else con.print("has no label");
        } else con.print("has no label");
        con.print("\n");
    }
    con.print(" Directory of ");
    con.print(path.slice());
    con.print("\n");

    if (st.o.wide) {
        const screen = zdos.screenSize().col;
        const col_width = @min(longest + 2, @max(screen, 2) - 1);
        const columns = @max(1, (screen - 1) / col_width);
        for (order, 0..) |i, n| {
            if (con.breakRequested()) break;
            const it = l.items.slice()[i];
            const name = l.name(it);
            if (it.is_dir) printName(it, name, "[", "]") else printName(it, name, "", "");
            const used = name.len + @as(usize, if (it.is_dir) 2 else 0);
            if ((n + 1) % columns == 0 or n + 1 == order.len) {
                con.print("\n");
            } else con.spaces(col_width -| used);
        }
    } else {
        for (order) |i| {
            if (con.breakRequested()) break;
            const it = l.items.slice()[i];
            const m = it.modified;
            con.printf("{d:0>4}-{d:0>2}-{d:0>2}  {d:0>2}:{d:0>2}  ", .{ m.year, m.month, m.day, m.hour, m.minute });
            if (it.is_dir) con.printRight("<DIR>", width) else con.printNum(it.size, width);
            con.print(" ");
            printName(it, l.name(it), "", "");
            con.print("\n");
        }
    }
    if (st.o.subdirs) {
        printFiles(t);
        con.print("\n");
    } else printFiles(t);
    return t;
}

fn printFiles(t: Totals) void {
    con.print(" ");
    con.printNum(t.files, 0);
    con.print(" File(s), ");
    con.printNum(t.bytes, 0);
    con.print(" bytes\n");
}

// Digits plus thousands separators.
fn numWidth(n: u64) usize {
    var digits: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) digits += 1;
    return digits + (digits - 1) / 3;
}

// SORTING

const SortCtx = struct {
    l: *const Listing,
    keys: []const u8,
};

fn lessThan(ctx: SortCtx, a: u32, b: u32) bool {
    const x = ctx.l.items.slice()[a];
    const y = ctx.l.items.slice()[b];
    var reverse = false;
    for (ctx.keys) |k| {
        if (k == '-') {
            reverse = true;
            continue;
        }
        var ord = compare(ctx.l, std.ascii.toUpper(k), x, y);
        if (reverse) ord = ord.invert();
        reverse = false;
        if (ord != .eq) return ord == .lt;
    }
    return false; // equal: the sort is stable, disk order stays
}

fn compare(l: *const Listing, key: u8, x: Item, y: Item) std.math.Order {
    return switch (key) {
        'N' => std.ascii.orderIgnoreCase(l.name(x), l.name(y)),
        'E' => std.ascii.orderIgnoreCase(extension(l.name(x)), extension(l.name(y))),
        'S' => std.math.order(if (x.is_dir) 0 else x.size, if (y.is_dir) 0 else y.size),
        'D' => std.math.order(stamp(x.modified), stamp(y.modified)),
        'G' => std.math.order(@intFromBool(!x.is_dir), @intFromBool(!y.is_dir)), // folders first
        else => .eq,
    };
}

fn extension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return ""; // ".", "..", ".hidden"
    return name[dot + 1 ..];
}

fn stamp(t: zdos.Time) u64 {
    return ((((@as(u64, t.year) * 13 + t.month) * 32 + t.day) * 24 + t.hour) * 60 + t.minute) * 60 + t.second;
}
