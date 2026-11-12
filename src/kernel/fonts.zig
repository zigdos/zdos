// The text font from SYSTEM\FONTS (FONT=, CODEPAGE=).
// UEFI: ZDOS draws <family>-<W>x<H>.zfn itself, glyphs
// by code point. BIOS: one 8x16 table of 256 glyphs,
// placed by <CODEPAGE>.zcp.
const std = @import("std");
const platform = @import("../platform.zig");
const fs = @import("fs.zig");
const env = @import("env.zig");
const con = @import("console.zig");

const cell_w = 8;
const cell_h = 16;
const folder = "\\SYSTEM\\FONTS\\";

// Called at startup, after the settings are read
pub fn apply() void {
    const font = env.get("FONT") orelse "firmware";
    if (std.ascii.eqlIgnoreCase(font, "firmware")) return;
    const d = fs.bootDrive() orelse {
        con.printf("FONT={s} is not available: there is no boot drive\n", .{font});
        return;
    };
    if (platform.console.font_files) applyFile(d, font) else applyTable(d, font);
}

fn notAvailable(font: []const u8) void {
    con.printf("FONT={s} is not available: using the firmware's font\n", .{font});
}

fn applyFile(d: *const fs.Drive, font: []const u8) void {
    const family_end = std.mem.indexOfScalar(u8, font, '-') orelse font.len;
    const family = font[0..family_end];
    var w: u32 = cell_w;
    var h: u32 = cell_h;
    if (family_end < font.len and !parseSize(font[family_end + 1 ..], &w, &h)) return notAvailable(font);
    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}-{d}x{d}.zfn", .{ folder, family, w, h }) catch return notAvailable(font);
    const data = readFile(d, name) orelse return notAvailable(font);
    if (!platform.console.loadFontFile(data)) {
        platform.memory.free(data.ptr);
        return notAvailable(font);
    }
    // The console keeps the file's bytes for the rest of the run
}

// "WxH" -> the cell size
fn parseSize(text: []const u8, w: *u32, h: *u32) bool {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return false;
    w.* = std.fmt.parseInt(u32, text[0..x], 10) catch return false;
    h.* = std.fmt.parseInt(u32, text[x + 1 ..], 10) catch return false;
    return true;
}

// A whole file in platform memory
fn readFile(d: *const fs.Drive, name: []const u8) ?[]align(8) u8 {
    const f = fs.openFile(d, name, .read) catch return null;
    defer fs.close(f);
    const size = platform.storage.size(f) catch return null;
    const n = std.math.cast(usize, size) orelse return null;
    if (n == 0) return null;
    const mem = platform.memory.alloc(n) orelse return null;
    const buf = mem[0..n];
    fs.readAll(f, buf) catch {
        platform.memory.free(mem);
        return null;
    };
    return buf;
}

fn applyTable(d: *const fs.Drive, font: []const u8) void {
    const family_end = std.mem.indexOfScalar(u8, font, '-') orelse font.len;
    const family = font[0..family_end];
    const codepage = env.get("CODEPAGE") orelse "CP437";
    var points: [256]u32 = undefined;
    if (!readCodepage(d, codepage, &points)) {
        con.printf("CODEPAGE={s} is not available: using CP437\n", .{codepage});
        if (!readCodepage(d, "CP437", &points)) {
            con.print("CODEPAGE=CP437 is not available either: the font is not changed\n");
            return;
        }
    }
    var table: [256 * cell_h]u8 = [_]u8{0} ** (256 * cell_h);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}-{d}x{d}.zfn", .{ folder, family, cell_w, cell_h }) catch return;
    if (!readGlyphs(d, name, &points, &table) or !platform.console.loadFont(&table)) {
        con.printf("FONT={s} is not available: using the firmware's font\n", .{font});
    } else {
        platform.console.setCodepage(&points);
    }
}

// ZCPG file: magic, version 1, 3 reserved, count u32 = 256,
// then the code point of each byte value (u32 LE)
fn readCodepage(d: *const fs.Drive, codepage: []const u8, points: *[256]u32) bool {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}.zcp", .{ folder, codepage }) catch return false;
    const f = fs.openFile(d, name, .read) catch return false;
    defer fs.close(f);
    var head: [12]u8 = undefined;
    fs.readAll(f, &head) catch return false;
    if (!std.mem.eql(u8, head[0..4], "ZCPG") or head[4] != 1) return false;
    if (std.mem.readInt(u32, head[8..12], .little) != 256) return false;
    var raw: [256 * 4]u8 = undefined;
    fs.readAll(f, &raw) catch return false;
    for (points, 0..) |*p, i| p.* = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
    return true;
}

// The glyphs of an 8x16 font file, 16 bytes per byte value
// of the codepage; characters the font lacks stay blank
fn readGlyphs(d: *const fs.Drive, name: []const u8, points: *const [256]u32, table: *[256 * cell_h]u8) bool {
    const f = fs.openFile(d, name, .read) catch return false;
    defer fs.close(f);
    var head: [16]u8 = undefined;
    fs.readAll(f, &head) catch return false;
    if (!std.mem.eql(u8, head[0..4], "ZFNT") or head[4] != 1) return false;
    if (head[5] != cell_w or head[6] != cell_h) return false;
    const count = std.mem.readInt(u32, head[8..12], .little);
    const row_bytes = (cell_w + 7) / 8;
    var entry: [4 + cell_h * row_bytes]u8 = undefined;
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        fs.readAll(f, &entry) catch return false;
        const code = std.mem.readInt(u32, entry[0..4], .little);
        for (points, 0..) |p, b| {
            if (p == code and code != 0) {
                @memcpy(table[b * cell_h ..][0..cell_h], entry[4..][0..cell_h]);
            }
        }
    }
    return true;
}
