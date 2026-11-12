// The firmware's screen modes (GOP) for SCREEN (metal
// records them before leaving the firmware; UEFI asks it
// each time), and RESOLUTION= of SYSTEM.CFG: "WxH" or "max"
// (the most pixels). Used by the UEFI and metal editions.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const Gop = uefi.protocol.GraphicsOutput;

pub const Error = error{ Invalid, NoSuchMode, Failed };

// Sorted by size, without repeats; numbers: the GOP's
// mode for each. When full, the smallest go:
// the largest (max) stay.
var sizes: [64]platform.ScreenSize = undefined;
var numbers: [64]u32 = undefined;
var count: usize = 0;

pub fn list() []const platform.ScreenSize {
    return sizes[0..count];
}

// While the firmware runs
pub fn record(g: *Gop) void {
    const bs = uefi.system_table.boot_services.?;
    count = 0;
    var m: u32 = 0;
    while (m < g.mode.max_mode) : (m += 1) {
        var size: usize = 0;
        var info: *Gop.Mode.Info = undefined;
        if (g.queryMode(m, &size, &info) != .success) continue;
        const s: platform.ScreenSize = .{ .width = info.horizontal_resolution, .height = info.vertical_resolution };
        _ = bs.freePool(@ptrCast(@alignCast(info)));
        insert(s, m);
    }
}

fn pixels(s: platform.ScreenSize) u64 {
    return @as(u64, s.width) * s.height;
}

fn insert(s: platform.ScreenSize, mode: u32) void {
    var at: usize = 0;
    while (at < count) : (at += 1) {
        if (sizes[at].width == s.width and sizes[at].height == s.height) return;
        if (pixels(sizes[at]) > pixels(s) or (pixels(sizes[at]) == pixels(s) and sizes[at].width > s.width)) break;
    }
    if (count == sizes.len) {
        if (at == 0) return;
        at -= 1;
        std.mem.copyForwards(platform.ScreenSize, sizes[0..at], sizes[1 .. at + 1]);
        std.mem.copyForwards(u32, numbers[0..at], numbers[1 .. at + 1]);
    } else {
        std.mem.copyBackwards(platform.ScreenSize, sizes[at + 1 .. count + 1], sizes[at..count]);
        std.mem.copyBackwards(u32, numbers[at + 1 .. count + 1], numbers[at..count]);
        count += 1;
    }
    sizes[at] = s;
    numbers[at] = mode;
}

const Wanted = union(enum) { max, size: platform.ScreenSize };

fn parse(value: []const u8) ?Wanted {
    const v = std.mem.trim(u8, value, " \t");
    if (std.ascii.eqlIgnoreCase(v, "max")) return .max;
    const x = std.mem.indexOfAny(u8, v, "xX") orelse return null;
    const w = std.fmt.parseInt(u32, v[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .size = .{ .width = w, .height = h } };
}

// "RESOLUTION=...: why; the firmware's mode stays"
pub fn report(value: []const u8, err: Error, write: *const fn ([]const u8) void) void {
    var buf: [96]u8 = undefined;
    write(std.fmt.bufPrint(&buf, "RESOLUTION={s}: {s}; the firmware's mode stays\n", .{ value, switch (err) {
        error.Invalid => "not WxH or max",
        error.NoSuchMode => "no such screen mode",
        error.Failed => "the firmware refused it",
    } }) catch return);
}

// Switches the screen to the mode value asks for (while
// the firmware runs; after record)
pub fn apply(g: *Gop, value: []const u8) Error!void {
    const wanted = parse(value) orelse return error.Invalid;
    if (count == 0) return error.NoSuchMode;
    const i = switch (wanted) {
        .max => count - 1,
        .size => |s| for (sizes[0..count], 0..) |have, k| {
            if (have.width == s.width and have.height == s.height) break k;
        } else return error.NoSuchMode,
    };
    if (numbers[i] == g.mode.mode) return;
    if (g.setMode(numbers[i]) != .success) return error.Failed;
}
