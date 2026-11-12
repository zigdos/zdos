// Keyboard layout files (SYSTEM\KEYB\XX.ZKB).
// Allocates nothing: the caller owns the dead-key buffer
// and the name. Host tests: zig test
// src/kernel/keyb_file.zig
const std = @import("std");
const layouts = @import("keyb_layouts.zig");

pub const magic = "ZKBD";
pub const version = 1;
pub const max_dead = 16;
pub const max_size = 8 + 4 * 4 * layouts.slots + 4 * max_dead;

pub const Error = error{
    BadMagic,
    BadVersion,
    BadDeadCount,
    BadReserved,
    BadSize, // truncated, or longer than the header says
    BadCharacter, // not a Unicode scalar value
};

// layout.dead points into dead_buf.
// On error layout is half filled: don't use it.
pub fn parse(bytes: []const u8, name: []const u8, dead_buf: *[max_dead]u21, layout: *layouts.Layout) Error!void {
    if (bytes.len < 8) return error.BadSize;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (bytes[4] != version) return error.BadVersion;
    const dead_count: usize = bytes[5];
    if (dead_count > max_dead) return error.BadDeadCount;
    if (bytes[6] != 0 or bytes[7] != 0) return error.BadReserved;
    if (bytes.len != 8 + 4 * 4 * layouts.slots + 4 * dead_count) return error.BadSize;

    var pos: usize = 8;
    for (0..4) |layer| {
        for (0..layouts.slots) |code| {
            layout.keys[layer][code] = try codepoint(bytes[pos..][0..4]);
            pos += 4;
        }
    }
    for (0..dead_count) |i| {
        dead_buf[i] = try codepoint(bytes[pos..][0..4]);
        pos += 4;
    }
    layout.name = name;
    layout.dead = dead_buf[0..dead_count];
}

fn codepoint(b: *const [4]u8) Error!u21 {
    const v = std.mem.readInt(u32, b, .little);
    if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return error.BadCharacter;
    return @intCast(v);
}

// Reads a whole file of the repository's keyb/ folder for the tests
fn readKeyb(name: []const u8) ![]u8 {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "keyb/{s}", .{name});
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 4096);
}

test "RU file: plain and Shift characters" {
    const bytes = try readKeyb("RU.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    try parse(bytes, "RU", &dead, &l);
    try std.testing.expectEqualStrings("RU", l.name);
    try std.testing.expectEqual(@as(u21, 0x439), l.keys[0][0x10]); // й
    try std.testing.expectEqual(@as(u21, 0x424), l.keys[1][0x1E]); // Ф (Shift layer)
    try std.testing.expectEqual(@as(u21, 0), l.keys[0][0x00]); // nothing typed
}

test "FR file has its dead keys" {
    const bytes = try readKeyb("FR.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    try parse(bytes, "FR", &dead, &l);
    try std.testing.expect(l.dead.len > 0);
}

test "a file of the wrong magic is rejected" {
    const bytes = try readKeyb("RU.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    var b = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(b);
    b[0] = 'X';
    try std.testing.expectError(error.BadMagic, parse(b, "RU", &dead, &l));
}

test "a file of another version is rejected" {
    const bytes = try readKeyb("RU.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    var b = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(b);
    b[4] = 2;
    try std.testing.expectError(error.BadVersion, parse(b, "RU", &dead, &l));
}

test "a truncated file is rejected" {
    const bytes = try readKeyb("RU.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    try std.testing.expectError(error.BadSize, parse(bytes[0 .. bytes.len - 1], "RU", &dead, &l));
    try std.testing.expectError(error.BadSize, parse(bytes[0..5], "RU", &dead, &l));
    try std.testing.expectError(error.BadSize, parse(bytes[0..0], "RU", &dead, &l));
}

test "a dead count over 16 is rejected" {
    const bytes = try readKeyb("RU.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    var b = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(b);
    b[5] = 17;
    try std.testing.expectError(error.BadDeadCount, parse(b, "RU", &dead, &l));
}

test "a dead count that does not match the size is rejected" {
    const bytes = try readKeyb("FR.ZKB");
    defer std.testing.allocator.free(bytes);
    var dead: [max_dead]u21 = undefined;
    var l: layouts.Layout = undefined;
    var b = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(b);
    b[5] = 0;
    try std.testing.expectError(error.BadSize, parse(b, "FR", &dead, &l));
}
