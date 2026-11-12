// KEYB: shows, lists and sets the keyboard layouts (src/kernel/keyb.zig)
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const usage = "Usage: KEYB [-l | EN,ES,FR]\n";
const max_config = 16 * 1024;

// Kept here rather than on the stack:
var config_buf: [max_config]u8 = undefined;
var out_buf: [max_config + 64]u8 = undefined;

pub fn main(args: []const u8) u8 {
    const s = std.mem.trim(u8, args, " \t");
    if (s.len == 0) return show();
    if (std.ascii.eqlIgnoreCase(s, "-l")) return list();
    if (s[0] == '-' or s[0] == '/') {
        zdos.print(usage);
        return 1;
    }
    return set(s);
}

// "" past the last one.
fn nameOf(index: u32, buf: []u8) []const u8 {
    return sys.keybName(index, buf) orelse "";
}

fn isAvailable(word: []const u8) bool {
    var buf: [8]u8 = undefined;
    var i: u32 = 0;
    while (i < sys.keybCount()) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(nameOf(i, &buf), word)) return true;
    }
    return false;
}

// What does not fit is left out.
fn appendText(buf: []u8, n: usize, text: []const u8) usize {
    const k = @min(text.len, buf.len - n);
    @memcpy(buf[n..][0..k], text[0..k]);
    return n + k;
}

// Wrapped to 80 columns, continuation lines indented.
fn printList(label: []const u8, text: []const u8) void {
    zdos.print(label);
    var col = label.len;
    var it = std.mem.splitSequence(u8, text, ", ");
    var first = true;
    while (it.next()) |word| {
        if (!first) {
            if (col + 2 + word.len > 80) {
                zdos.print(",\n    ");
                col = 4;
            } else {
                zdos.print(", ");
                col += 2;
            }
        }
        first = false;
        zdos.print(word);
        col += word.len;
    }
    zdos.print("\n");
}

fn show() u8 {
    var name_buf: [8]u8 = undefined;
    var loaded_buf: [64]u8 = undefined;
    const active = nameOf(sys.keybActive(), &name_buf);
    const loaded = sys.keybLoaded(&loaded_buf) catch |err| {
        zdos.printf("Cannot read the keyboard layouts: {s}\n", .{zdos.message(err)});
        return 1;
    };
    zdos.printf("Active layout: {s}\n", .{active});
    var line: [256]u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, loaded, ',');
    while (it.next()) |word| {
        if (n > 0) n = appendText(&line, n, ", ");
        n = appendText(&line, n, word);
        if (std.ascii.eqlIgnoreCase(word, active)) n = appendText(&line, n, " (active)");
    }
    printList("Loaded layouts: ", line[0..n]);
    n = 0;
    var i: u32 = 0;
    while (i < sys.keybCount()) : (i += 1) {
        if (i > 0) n = appendText(&line, n, ", ");
        n = appendText(&line, n, nameOf(i, &name_buf));
    }
    printList("Available layouts: ", line[0..n]);
    zdos.print("\nCtrl + Space switches between the loaded layouts");
    zdos.print(" (BIOS: Left Alt + Shift too).\n");
    return 0;
}

fn list() u8 {
    var name_buf: [8]u8 = undefined;
    var i: u32 = 0;
    while (i < sys.keybCount()) : (i += 1) {
        zdos.printf("{s}\n", .{nameOf(i, &name_buf)});
    }
    return 0;
}

// Then asks to save them.
fn set(s: []const u8) u8 {
    var list_buf: [64]u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        const word = std.mem.trim(u8, raw, " \t");
        if (word.len == 0) continue;
        if (!isAvailable(word)) {
            zdos.printf("Unknown keyboard layout: {s}\n", .{word});
            zdos.print(usage);
            return 1;
        }
        var upper: [8]u8 = undefined;
        const name = std.ascii.upperString(&upper, word);
        if (len > 0) {
            if (len + 1 >= list_buf.len) break;
            list_buf[len] = ',';
            len += 1;
        }
        if (len + name.len > list_buf.len) break;
        @memcpy(list_buf[len..][0..name.len], name);
        len += name.len;
    }
    if (len == 0) {
        zdos.print(usage);
        return 1;
    }
    const value = list_buf[0..len];
    sys.keybSetLoaded(value) catch |err| {
        zdos.printf("Cannot set the keyboard layouts: {s}\n", .{zdos.message(err)});
        return 1;
    };
    zdos.printf("Loaded layouts now: {s}\n", .{value});

    var path_buf: [64]u8 = undefined;
    const path = configPath(&path_buf) orelse {
        zdos.print("The program's drive is not known: SYSTEM.CFG is not changed.\n");
        return 1;
    };
    zdos.printf("Save KEYB={s} in {s} (Y/N)? ", .{ value, path });
    if (!sys.askYes()) {
        zdos.print("SYSTEM.CFG is not changed.\n");
        return 0;
    }
    return save(path, value);
}

// On the drive this program runs from:
fn configPath(buf: []u8) ?[]const u8 {
    var exe_buf: [256]u8 = undefined;
    const exe = zdos.programPath(&exe_buf);
    if (exe.len < 2 or exe[1] != ':') return null;
    return std.fmt.bufPrint(buf, "{c}:\\CONF\\SYSTEM.CFG", .{exe[0]}) catch null;
}

// KEYB=value in [System], replaced or added; other lines stay.
fn save(path: []const u8, value: []const u8) u8 {
    const text = readFile(path) orelse return 1;
    const new_text = rewrite(text, value) orelse {
        zdos.printf("{s} is too big to change (at most {d} bytes)\n", .{ path, max_config - 1 });
        return 1;
    };
    const f = zdos.open(path, .write) catch |err| {
        zdos.printf("Cannot write {s}: {s}\n", .{ path, zdos.message(err) });
        return 1;
    };
    f.writeAll(new_text) catch |err| {
        f.close();
        zdos.printf("Cannot write {s}: {s}\n", .{ path, zdos.message(err) });
        return 1;
    };
    f.closeChecked() catch |err| {
        zdos.printf("Cannot write {s}: {s}\n", .{ path, zdos.message(err) });
        return 1;
    };
    zdos.printf("KEYB={s} is saved in {s}\n", .{ value, path });
    return 0;
}

// Empty if there is no file yet; null if it can't be read.
fn readFile(path: []const u8) ?[]const u8 {
    const f = zdos.open(path, .read) catch |err| {
        if (err == error.NotFound) return config_buf[0..0];
        zdos.printf("Cannot read {s}: {s}\n", .{ path, zdos.message(err) });
        return null;
    };
    defer f.close();
    var n: usize = 0;
    while (n < config_buf.len) {
        const got = f.read(config_buf[n..]) catch |err| {
            zdos.printf("Cannot read {s}: {s}\n", .{ path, zdos.message(err) });
            return null;
        };
        if (got == 0) break;
        n += got;
    }
    if (n == config_buf.len) {
        zdos.printf("{s} is too big to change (at most {d} bytes)\n", .{ path, max_config - 1 });
        return null;
    }
    return config_buf[0..n];
}

// Null if too big.
fn rewrite(src: []const u8, value: []const u8) ?[]const u8 {
    const eol: []const u8 = if (std.mem.indexOf(u8, src, "\r\n") != null) "\r\n" else "\n";
    var fbs = std.io.fixedBufferStream(&out_buf);
    const w = fbs.writer();
    var in_system = false;
    var has_system = false;
    var done = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const last = lines.peek() == null;
        if (last and raw.len == 0) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            if (in_system and !done) {
                w.print("KEYB={s}{s}", .{ value, eol }) catch return null;
                done = true;
            }
            in_system = std.ascii.eqlIgnoreCase(line, "[System]");
            has_system = has_system or in_system;
        } else if (in_system and isKeyb(line)) {
            // The first one is replaced; any others in the section go:
            if (!done) w.print("KEYB={s}{s}", .{ value, eol }) catch return null;
            done = true;
            continue;
        }
        w.writeAll(std.mem.trimRight(u8, raw, "\r")) catch return null;
        if (!last) w.writeAll(eol) catch return null;
    }
    if (!done) {
        const so_far = fbs.getWritten();
        if (so_far.len > 0 and so_far[so_far.len - 1] != '\n') w.writeAll(eol) catch return null;
        if (!has_system) w.print("[System]{s}", .{eol}) catch return null;
        w.print("KEYB={s}{s}", .{ value, eol }) catch return null;
    }
    return fbs.getWritten();
}

fn isKeyb(line: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..eq], " \t"), "KEYB");
}
