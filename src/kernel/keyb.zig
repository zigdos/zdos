// Keyboard layouts: which exist, which are loaded (KEYB=)
// and which is active. EN is built in; the others are
// parsed on first use. BIOS: ps2kbd.zig translates with
// the active layout. UEFI: the firmware translated keys as
// US, so fromFirmware maps them back through EN.
const std = @import("std");
const fs = @import("fs.zig");
const env = @import("env.zig");
const con = @import("console.zig");
const platform = @import("../platform.zig");
const kbd = @import("../drivers/ps2kbd.zig");
const data = @import("keyb_layouts.zig");
const file = @import("keyb_file.zig");

pub const supported = true;

const Error = fs.Error;

pub const max_layouts = 32; // EN, and up to 31 files
const folder = "\\SYSTEM\\KEYB";
const max_file = 2048; // read buffer; keyb_file.max_size is smaller

// A layout read from its file. The layout points into its slot,
// so slots never move (a static table).
const Slot = struct {
    dead: [file.max_dead]u21 = undefined,
    layout: data.Layout = undefined,
};

const State = enum { untried, ok, bad };

var names: [max_layouts][2]u8 = undefined; // by index; index 0 is EN
var layout_count: usize = 1; // EN and the files found
var scanned = false;
var slots: [max_layouts]Slot = undefined;
var state: [max_layouts]State = [_]State{.untried} ** max_layouts;

var loaded: [max_layouts]usize = undefined; // indexes, in list order
var loaded_count: usize = 0;
var current: usize = 0; // index of the active layout

fn nameOf(i: usize) []const u8 {
    return if (i == 0) data.en.name else names[i][0..];
}

// Collects the two-letter XX.ZKB names in SYSTEM\KEYB, in
// directory order (which is the layout numbering).
// An EN.ZKB is ignored: EN is built in.
fn scan() void {
    if (scanned) return;
    scanned = true;
    const d = fs.bootDrive() orelse return;
    var dir: fs.Path = .{};
    fs.resolveDir(d, folder, &dir) catch return;
    var list = fs.listMatches(d, &dir, "*.ZKB", .visible) catch return;
    defer list.deinit();
    var it = list.iterator();
    while (it.next()) |entry| {
        if (layout_count == max_layouts) break;
        if (entry.len != 6 or !std.ascii.eqlIgnoreCase(entry[2..], ".ZKB")) continue;
        if (!std.ascii.isAlphabetic(entry[0]) or !std.ascii.isAlphabetic(entry[1])) continue;
        const up = [2]u8{ std.ascii.toUpper(entry[0]), std.ascii.toUpper(entry[1]) };
        if (std.mem.eql(u8, &up, data.en.name)) continue;
        names[layout_count] = up;
        layout_count += 1;
    }
}

pub fn count() usize {
    scan();
    return layout_count;
}

pub fn name(index: usize) ?[]const u8 {
    scan();
    if (index >= layout_count) return null;
    return nameOf(index);
}

pub fn active() usize {
    return current;
}

// KEYB= from SYSTEM.CFG, at startup after the
// settings are read. Unknown names are left out
// with a message; none known gives EN.
pub fn apply() void {
    if (!supported) return;
    scan();
    const list = std.mem.trim(u8, env.get("KEYB") orelse "", " \t");
    var known: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t");
        if (word.len == 0) continue;
        if (resolve(word)) |i| {
            if (add(i)) known += 1;
        }
    }
    if (known == 0) {
        if (list.len > 0) con.printf("KEYB={s} is not available: using EN\n", .{list});
        _ = add(0);
    } else {
        var again = std.mem.splitScalar(u8, list, ',');
        while (again.next()) |raw| {
            const word = std.mem.trim(u8, raw, " \t");
            if (word.len > 0 and resolve(word) == null) con.printf("KEYB={s} is not available: left out\n", .{word});
        }
    }
    select(loaded[0]);
    kbd.hotkey = switchLayout;
}

fn find(word: []const u8) ?usize {
    scan();
    for (0..layout_count) |i| {
        if (std.ascii.eqlIgnoreCase(nameOf(i), word)) return i;
    }
    return null;
}

// The index of a usable layout by name; reads its file the first time
fn resolve(word: []const u8) ?usize {
    const i = find(word) orelse return null;
    return if (layoutAt(i) != null) i else null;
}

// Null if the file is missing or bad
fn layoutAt(i: usize) ?*const data.Layout {
    if (i == 0) return &data.en;
    if (state[i] == .untried) state[i] = if (readSlot(i)) .ok else .bad;
    return if (state[i] == .ok) &slots[i].layout else null;
}

fn readSlot(i: usize) bool {
    const d = fs.bootDrive() orelse return false;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}.ZKB", .{ folder, nameOf(i) }) catch return false;
    var buf: [max_file]u8 = undefined;
    const n = readFile(d, path, &buf) orelse return false;
    file.parse(buf[0..n], nameOf(i), &slots[i].dead, &slots[i].layout) catch return false;
    return true;
}

// A whole small file into buf; null if unreadable or too big
fn readFile(d: *const fs.Drive, path: []const u8, buf: []u8) ?usize {
    const f = fs.openFile(d, path, .read) catch return null;
    defer fs.close(f);
    const size = platform.storage.size(f) catch return null;
    const n = std.math.cast(usize, size) orelse return null;
    if (n == 0 or n > buf.len) return null;
    fs.readAll(f, buf[0..n]) catch return null;
    return n;
}

// False if already loaded
fn add(i: usize) bool {
    if (indexOf(loaded[0..loaded_count], i) != null) return false;
    loaded[loaded_count] = i;
    loaded_count += 1;
    return true;
}

fn indexOf(list: []const usize, i: usize) ?usize {
    for (list, 0..) |x, k| {
        if (x == i) return k;
    }
    return null;
}

// UEFI dead keys: the accent waiting, and a character to
// deliver after it (a dead key followed by
// a key it doesn't combine with gives both)
var pending: u21 = 0;
var extra: u21 = 0;

pub fn takeExtra() ?u21 {
    if (extra == 0) return null;
    const e = extra;
    extra = 0;
    return e;
}

// UEFI gives characters translated as US, not key positions:
// the position is found in EN, and the active layout's
// character there (same Shift layer) is typed. Characters EN
// lacks (control keys) pass unchanged.
// Null while a dead key waits for the next key.
pub fn fromFirmware(c: u21) ?u21 {
    const act = layoutAt(current) orelse &data.en;
    var out = c;
    if (current != 0 and c != 0) {
        search: for (0..2) |layer| {
            for (data.en.keys[layer], 0..) |u, place| {
                if (u == c) {
                    if (act.keys[layer][place] != 0) out = act.keys[layer][place];
                    break :search;
                }
            }
        }
    }
    if (pending != 0) {
        const accent = pending;
        pending = 0;
        if (data.compose(accent, out)) |r| return r;
        // Typed twice (or with Space): the accent alone
        if (out == accent or out == ' ') return accent;
        extra = out;
        return accent;
    }
    for (act.dead) |d| {
        if (d == out) {
            pending = out;
            return null;
        }
    }
    return out;
}

fn select(i: usize) void {
    pending = 0;
    current = i;
    kbd.useLayout(layoutAt(i) orelse &data.en);
}

// index must be loaded
pub fn setActive(index: usize) Error!void {
    if (!supported) return error.NotSupported;
    if (indexOf(loaded[0..loaded_count], index) == null) return error.InvalidArgument;
    select(index);
}

// Replaces the loaded list ("EN,ES,FR"); the first becomes
// active unless the active one is still in it. Any unusable
// name or an empty list changes nothing.
pub fn setLoaded(list: []const u8) Error!void {
    if (!supported) return error.NotSupported;
    var found: [max_layouts]usize = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t");
        if (word.len == 0) continue;
        const i = resolve(word) orelse return error.InvalidArgument;
        if (indexOf(found[0..n], i) == null) {
            found[n] = i;
            n += 1;
        }
    }
    if (n == 0) return error.InvalidArgument;
    @memcpy(loaded[0..n], found[0..n]);
    loaded_count = n;
    if (indexOf(loaded[0..n], current) == null) select(loaded[0]);
}

// "EN,ES,FR" into buf; returns the length
pub fn loadedText(buf: []u8) Error!usize {
    if (!supported) return error.NotSupported;
    var n: usize = 0;
    for (loaded[0..loaded_count], 0..) |i, k| {
        const text = nameOf(i);
        const need = text.len + @intFromBool(k > 0);
        if (n + need > buf.len) break;
        if (k > 0) {
            buf[n] = ',';
            n += 1;
        }
        @memcpy(buf[n .. n + text.len], text);
        n += text.len;
    }
    return n;
}

// The next loaded layout, cyclic (the layout hotkeys)
pub fn switchLayout() void {
    if (loaded_count < 2) return;
    const pos = indexOf(loaded[0..loaded_count], current) orelse 0;
    select(loaded[(pos + 1) % loaded_count]);
}
