// Graphics on the VGA: mode 13h, 320x200 with one palette
// byte per pixel at 0xA0000 and 256 colors; mode 12h,
// 640x480 in 16 colors (the palette's first 16), four bit
// planes at 0xA0000 (a pixel's bit n in plane n). The DAC
// palette has 6 bits per component. Modes are switched by
// the BIOS (int 10h); a smaller picture is centered.
const platform = @import("../../platform.zig");
const realmode = @import("realmode.zig");
const port = @import("../../arch/x86_port.zig");
const console = @import("console.zig");
const memory = @import("memory.zig");

const vga: [*]volatile u8 = @ptrFromInt(0xA0000);
const bda_video_mode: *const volatile u8 = @ptrFromInt(0x449);

const Mode = enum { none, m13, m12 };

var mode: Mode = .none;
var screen_width: u32 = 320;
var screen_height: u32 = 200;
var width: u32 = 0;
var height: u32 = 0;
var left: u32 = 0; // where the picture starts on the screen (mode 12h: a multiple of 8)
var top: u32 = 0;

// Mode 12h: what the planes hold (one after another, 80
// bytes a row), so draw writes only the bytes that
// changed: a VGA write is slow on the card and an exit
// to the hypervisor in a VM. Without it, all are written.
const plane_size = 80 * 480;
const shadow_pages = (4 * plane_size + 4095) / 4096;
var shadow: ?[*]align(4096) u8 = null;

fn freeShadow() void {
    if (shadow) |s| memory.freePages(s, shadow_pages);
    shadow = null;
}

fn setMode(m: u8) void {
    var r: realmode.Regs = .{ .eax = m }; // ah 0: set video mode
    realmode.call(0x10, &r);
}

// dos_aspect has no effect: the monitor shows both modes 4:3 itself
pub fn begin(w: u32, h: u32, dos_aspect: bool) platform.Error!void {
    _ = dos_aspect;
    if (w == 0 or h == 0) return error.InvalidArgument;
    const want: Mode = if (w <= 320 and h <= 200) .m13 else if (w <= 640 and h <= 480) .m12 else return error.NotSupported;
    if (mode != want) {
        if (mode == .none) console.hide();
        const number: u8 = if (want == .m13) 0x13 else 0x12;
        setMode(number);
        if (bda_video_mode.* & 0x7F != number) { // a VGA BIOS that can't
            setMode(0x03);
            console.unhide();
            mode = .none;
            freeShadow();
            return error.NotSupported;
        }
        mode = want;
        if (want == .m12) {
            // Attribute palette: color n is the DAC's entry n, as in mode 13h
            _ = port.inb(0x3DA); // the attribute controller's flip-flop to "index"
            for (0..16) |i| {
                port.outb(0x3C0, @intCast(i));
                port.outb(0x3C0, @intCast(i));
            }
            port.outb(0x3C0, 0x20); // the screen on again
        }
    }
    screen_width = if (want == .m13) 320 else 640;
    screen_height = if (want == .m13) 200 else 480;
    width = w;
    height = h;
    left = (screen_width - w) / 2;
    if (want == .m12) left &= ~@as(u32, 7);
    top = (screen_height - h) / 2;
    if (want == .m13) {
        freeShadow();
        for (0..320 * 200) |i| vga[i] = 0;
    } else {
        setPlanes(0x0F);
        for (0..80 * 480) |i| vga[i] = 0;
        // The planes are all 0 now, and so is the copy:
        if (shadow == null) shadow = memory.allocPages(shadow_pages, false);
        if (shadow) |c| @memset(c[0 .. 4 * plane_size], 0);
    }
    port.outb(0x3C8, 0); // the whole palette black
    for (0..256 * 3) |_| port.outb(0x3C9, 0);
}

// Mode 12h: the planes the next writes go to (the sequencer's map mask)
fn setPlanes(mask: u8) void {
    port.outb(0x3C4, 2);
    port.outb(0x3C5, mask);
}

// 320 x 200 in 256 colors, 640 x 480 in 16 (pixel values 0-15)
pub fn modes() []const platform.ScreenSize {
    return &.{ .{ .width = 320, .height = 200 }, .{ .width = 640, .height = 480 } };
}

// The 256-color screen, which programs
// asking for "the screen" get; 640 x 480 (16
// colors) is among the modes
pub fn screen() ?platform.ScreenInfo {
    return .{ .width = 320, .height = 200, .true_color = false };
}

pub fn beginRgb(w: u32, h: u32) platform.Error!void {
    _ = w;
    _ = h;
    return error.NotSupported;
}

pub fn drawRgb(picture: []const u32) void {
    _ = picture;
}

pub fn palette(first: u8, rgb: []const u8) void {
    if (mode == .none) return;
    port.outb(0x3C8, first);
    const count = @min(rgb.len / 3, 256 - @as(usize, first));
    for (rgb[0 .. count * 3]) |c| port.outb(0x3C9, c >> 2);
}

pub fn draw(pixels: []const u8) void {
    if (mode == .none or pixels.len < width * height) return;
    if (mode == .m13) {
        for (0..height) |y| {
            const row = vga + (top + y) * 320 + left;
            for (pixels[y * width ..][0..width], 0..) |p, x| row[x] = p;
        }
        return;
    }
    // Mode 12h: each plane in turn, eight
    // pixels a byte (the leftmost the high bit)
    const first_byte = left / 8;
    const bytes = (width + 7) / 8;
    for (0..4) |plane| {
        setPlanes(@as(u8, 1) << @intCast(plane));
        for (0..height) |y| {
            const src = pixels[y * width ..][0..width];
            const at = (top + y) * 80 + first_byte;
            const row = vga + at;
            const old: ?[*]u8 = if (shadow) |c| c + plane * plane_size + at else null;
            for (0..bytes) |b| {
                var v: u8 = 0;
                const x0 = b * 8;
                const n = @min(8, width - x0);
                for (0..n) |i| v |= ((src[x0 + i] >> @intCast(plane)) & 1) << @intCast(7 - i);
                if (old) |o| {
                    if (o[b] == v) continue;
                    o[b] = v;
                }
                row[b] = v;
            }
        }
    }
    setPlanes(0x0F);
}

pub fn end() void {
    if (mode == .none) return;
    mode = .none;
    freeShadow();
    setMode(0x03);
    console.unhide();
}
