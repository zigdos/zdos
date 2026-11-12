// Graphics of the metal editions: a program's 8-bit palette
// or true color picture on the console's framebuffer
// (framebuffer.zig), scaled by a whole
// number and centered, or 4:3 (fitDos).
const std = @import("std");
const platform = @import("../../platform.zig");
const memory = @import("memory.zig");
const framebuffer = @import("framebuffer.zig");
const screen_mode = @import("../uefi/screen_mode.zig");

var active = false;
var surface: framebuffer.Surface = undefined;
var colors: [256]u32 = [_]u32{0} ** 256;
var line: ?[*]align(8) u8 = null; // one widened row
var line_pixels: usize = 0;
var width: u32 = 0;
var height: u32 = 0;
var out_width: u32 = 0; // the picture's size on the screen
var out_height: u32 = 0;
var left: u32 = 0; // where it starts on the screen
var top: u32 = 0;
var true_color = false; // the picture's pixels: 0x00RRGGBB (else palette bytes)
var native = false; // the screen's pixels are 0x00RRGGBB too: copied as they are

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

// The firmware's modes, recorded before leaving it
pub fn modes() []const platform.ScreenSize {
    return screen_mode.list();
}

// The screen's size, for a picture shown 1:1
pub fn screen() ?platform.ScreenInfo {
    const s = framebuffer.surface() orelse return null;
    return .{ .width = s.width, .height = s.height, .true_color = true };
}

pub fn begin(w: u32, h: u32, dos_aspect: bool) platform.Error!void {
    return start(w, h, dos_aspect, false);
}

pub fn beginRgb(w: u32, h: u32) platform.Error!void {
    return start(w, h, false, true);
}

fn start(w: u32, h: u32, dos_aspect: bool, rgb: bool) platform.Error!void {
    if (w == 0 or h == 0) return error.InvalidArgument;
    const s = framebuffer.surface() orelse return error.NotSupported;
    if (w > s.width or h > s.height) return error.NotSupported;
    // Square pixels, a whole number of times
    // larger, unless 4:3 is asked and fits
    const k = @min(s.width / w, s.height / h);
    const size: Size = (if (dos_aspect) fitDos(w, h, s.width, s.height) else null) orelse .{ .w = w * k, .h = h * k };
    if (line == null or line_pixels < size.w) {
        const mem = memory.alloc(@as(usize, size.w) * @sizeOf(u32)) orelse return error.OutOfMemory;
        if (line) |old| memory.free(old);
        line = mem;
        line_pixels = size.w;
    }
    if (!active) {
        framebuffer.pause(true);
        active = true;
    }
    surface = s;
    true_color = rgb;
    native = framebuffer.rgbPixel(0x12, 0x34, 0x56) == 0x123456;
    width = w;
    height = h;
    out_width = size.w;
    out_height = size.h;
    left = (s.width - size.w) / 2;
    top = (s.height - size.h) / 2;
    @memset(&colors, framebuffer.rgbPixel(0, 0, 0));
    // The whole screen black: the borders around the picture stay so
    for (0..s.height) |y| @memset(s.base[y * s.pitch ..][0..s.width], colors[0]);
}

pub fn palette(first: u8, rgb: []const u8) void {
    if (!active) return;
    const count = @min(rgb.len / 3, 256 - @as(usize, first));
    for (0..count) |i| colors[first + i] = framebuffer.rgbPixel(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
}

// Where picture column or row i starts on the screen, of
// `out` for `in`: the extra screen pixels of an uneven
// scale are spread evenly
fn edge(i: usize, out: usize, in: usize) usize {
    return i * out / in;
}

pub fn draw(picture: []const u8) void {
    if (!active or true_color or picture.len < @as(usize, width) * height) return;
    const row: [*]u32 = @ptrCast(line.?);
    const ow: usize = out_width;
    for (0..height) |y| {
        var x: usize = 0;
        for (picture[y * width ..][0..width], 1..) |p, i| {
            const c = colors[p];
            const x1 = edge(i, ow, width);
            while (x < x1) : (x += 1) row[x] = c;
        }
        for (edge(y, out_height, height)..edge(y + 1, out_height, height)) |sy| {
            const to = surface.base + (top + sy) * surface.pitch + left;
            @memcpy(to[0..ow], row[0..ow]);
        }
    }
}

// A true-color picture: each pixel 0x00RRGGBB
pub fn drawRgb(picture: []const u32) void {
    if (!active or !true_color or picture.len < @as(usize, width) * height) return;
    const row: [*]u32 = @ptrCast(line.?);
    const ow: usize = out_width;
    for (0..height) |y| {
        const src = picture[y * width ..][0..width];
        const dest: [*]u32 = if (ow == width and native) @constCast(src.ptr) else row;
        if (ow != width or !native) {
            var x: usize = 0;
            for (src, 1..) |p, i| {
                const c = if (native) p else framebuffer.rgbPixel(@truncate(p >> 16), @truncate(p >> 8), @truncate(p));
                const x1 = edge(i, ow, width);
                while (x < x1) : (x += 1) row[x] = c;
            }
        }
        for (edge(y, out_height, height)..edge(y + 1, out_height, height)) |sy| {
            const to = surface.base + (top + sy) * surface.pitch + left;
            @memcpy(to[0..ow], dest[0..ow]);
        }
    }
}

pub fn end() void {
    if (!active) return;
    active = false;
    framebuffer.pause(false);
}
