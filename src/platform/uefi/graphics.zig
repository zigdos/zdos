// Graphics through GOP: 8-bit palette or true color
// pictures, scaled by a whole number and centered
// (or 4:3, fitDos). The firmware's mode is kept
// (changing it changes the text console too).
// Uses Blt: some GOPs have no linear framebuffer
// (virtio-gpu on ARM64).
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const memory = @import("memory.zig");
const screen_mode = @import("screen_mode.zig");
const console = @import("console.zig");

const Gop = uefi.protocol.GraphicsOutput;
const Pixel = Gop.BltPixel;
const black: Pixel = .{ .blue = 0, .green = 0, .red = 0, .reserved = 0 };

var gop: ?*Gop = null;
var active = false;
var saved: ?[*]align(8) u8 = null; // the text screen while the picture shows
var frame: ?[*]align(8) u8 = null; // the picture, scaled up
var colors: [256]Pixel = .{black} ** 256;
var screen_width: u32 = 0;
var screen_height: u32 = 0;
var width: u32 = 0;
var height: u32 = 0;
var out_width: u32 = 0; // the picture's size on the screen
var out_height: u32 = 0;
var left: u32 = 0; // where the picture starts on the screen
var top: u32 = 0;
var true_color = false;

fn pixels(mem: [*]align(8) u8) [*]Pixel {
    return @ptrCast(mem);
}

fn allocPixels(count: usize) ?[*]align(8) u8 {
    return memory.alloc(count * @sizeOf(Pixel));
}

const Size = struct { w: u32, h: u32 };

// Screen size of a w x h picture shown 4:3 as on DOS:
// whole-number pixel scales if they fit (320 x 200: 5 x 6
// each), else the largest 4:3 area.
// Null if the picture would have to shrink.
fn fitDos(w: u32, h: u32, sw: u32, sh: u32) ?Size {
    // 4:3 means w * kx : h * ky = 4 : 3,
    // so kx : ky = 4h : 3w, in lowest terms
    const a: u64 = 4 * @as(u64, h);
    const b: u64 = 3 * @as(u64, w);
    const g = std.math.gcd(a, b);
    const kx = a / g;
    const ky = b / g;
    const n = @min(sw / (w * kx), sh / (h * ky));
    if (n > 0) return .{ .w = @intCast(w * kx * n), .h = @intCast(h * ky * n) };
    // The screen is wider than 4:3: the
    // picture fills its height, else its width
    const fit: Size = if (@as(u64, sw) * 3 >= @as(u64, sh) * 4)
        .{ .w = @intCast(@as(u64, sh) * 4 / 3), .h = sh }
    else
        .{ .w = sw, .h = @intCast(@as(u64, sw) * 3 / 4) };
    if (fit.w < w or fit.h < h) return null;
    return fit;
}

// The screen's size (the firmware's mode), for a picture shown
// 1:1 The firmware's modes, asked when needed
pub fn modes() []const platform.ScreenSize {
    const g = console.gop() orelse return &.{};
    screen_mode.record(g);
    return screen_mode.list();
}

pub fn screen() ?platform.ScreenInfo {
    const g = console.gop() orelse return null;
    return .{ .width = g.mode.info.horizontal_resolution, .height = g.mode.info.vertical_resolution, .true_color = true };
}

pub fn begin(w: u32, h: u32, dos_aspect: bool) platform.Error!void {
    return start(w, h, dos_aspect, false);
}

pub fn beginRgb(w: u32, h: u32) platform.Error!void {
    return start(w, h, false, true);
}

fn start(w: u32, h: u32, dos_aspect: bool, rgb: bool) platform.Error!void {
    if (w == 0 or h == 0) return error.InvalidArgument;
    const g = console.gop() orelse return error.NotSupported;
    gop = g;
    const sw = g.mode.info.horizontal_resolution;
    const sh = g.mode.info.vertical_resolution;
    if (w > sw or h > sh) return error.NotSupported;
    // Square pixels, a whole number of times
    // larger, unless 4:3 is asked and fits
    const s = @min(sw / w, sh / h);
    const size: Size = (if (dos_aspect) fitDos(w, h, sw, sh) else null) orelse .{ .w = w * s, .h = h * s };
    const new_frame = allocPixels(@as(usize, size.w) * size.h) orelse return error.OutOfMemory;
    if (!active) {
        // Cursor off first, so the saved copy has none
        console.pause(true);
        // No memory for the copy: the screen is cleared at the end instead
        saved = allocPixels(@as(usize, sw) * sh);
        if (saved) |buf| {
            if (g.blt(pixels(buf), .blt_video_to_blt_buffer, 0, 0, 0, 0, sw, sh, 0) != .success) {
                memory.free(buf);
                saved = null;
            }
        }
        active = true;
    }
    if (frame) |f| memory.free(f);
    frame = new_frame;
    screen_width = sw;
    screen_height = sh;
    true_color = rgb;
    width = w;
    height = h;
    out_width = size.w;
    out_height = size.h;
    left = (sw - size.w) / 2;
    top = (sh - size.h) / 2;
    colors = .{black} ** 256;
    var fill = black;
    _ = g.blt(@ptrCast(&fill), .blt_video_fill, 0, 0, 0, 0, sw, sh, 0);
}

pub fn palette(first: u8, rgb: []const u8) void {
    const count = @min(rgb.len / 3, 256 - @as(usize, first));
    for (0..count) |i| {
        colors[first + i] = .{ .red = rgb[i * 3], .green = rgb[i * 3 + 1], .blue = rgb[i * 3 + 2], .reserved = 0 };
    }
}

// Where picture column or row i starts on the screen, of
// `out` for `in`: the extra screen pixels of an uneven
// scale are spread evenly
fn edge(i: usize, out: usize, in: usize) usize {
    return i * out / in;
}

pub fn draw(picture: []const u8) void {
    if (!active or true_color or picture.len < @as(usize, width) * height) return;
    const out = pixels(frame.?);
    const ow: usize = out_width;
    for (0..height) |y| {
        // The row widened once, then copied down to the rows it covers
        const y0 = edge(y, out_height, height);
        const y1 = edge(y + 1, out_height, height);
        const row = out + y0 * ow;
        var x: usize = 0;
        for (picture[y * width ..][0..width], 1..) |p, i| {
            const c = colors[p];
            const x1 = edge(i, ow, width);
            while (x < x1) : (x += 1) row[x] = c;
        }
        for (y0 + 1..y1) |k| @memcpy(out[k * ow ..][0..ow], row[0..ow]);
    }
    _ = gop.?.blt(out, .blt_buffer_to_video, 0, 0, left, top, ow, out_height, 0);
}

// A true-color picture: each pixel 0x00RRGGBB, as GOP's
// BltPixel; shown as it is when not
// scaled, else widened like an 8-bit one
pub fn drawRgb(picture: []const u32) void {
    if (!active or !true_color or picture.len < @as(usize, width) * height) return;
    if (out_width == width and out_height == height) {
        _ = gop.?.blt(@ptrCast(@constCast(picture.ptr)), .blt_buffer_to_video, 0, 0, left, top, width, height, 0);
        return;
    }
    const out = pixels(frame.?);
    const ow: usize = out_width;
    for (0..height) |y| {
        const y0 = edge(y, out_height, height);
        const y1 = edge(y + 1, out_height, height);
        const row = out + y0 * ow;
        var x: usize = 0;
        for (picture[y * width ..][0..width], 1..) |p, i| {
            const c: Pixel = @bitCast(p & 0x00FF_FFFF);
            const x1 = edge(i, ow, width);
            while (x < x1) : (x += 1) row[x] = c;
        }
        for (y0 + 1..y1) |k| @memcpy(out[k * ow ..][0..ow], row[0..ow]);
    }
    _ = gop.?.blt(out, .blt_buffer_to_video, 0, 0, left, top, ow, out_height, 0);
}

pub fn end() void {
    if (!active) return;
    active = false;
    if (frame) |f| memory.free(f);
    frame = null;
    // Restore the copy first: the cursor is drawn again only after it
    if (saved) |buf| {
        _ = gop.?.blt(pixels(buf), .blt_buffer_to_video, 0, 0, 0, 0, screen_width, screen_height, 0);
        memory.free(buf);
        saved = null;
        console.pause(false);
    } else {
        console.pause(false);
        console.clear();
    }
}
