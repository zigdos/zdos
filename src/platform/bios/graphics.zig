// Graphics on the VGA and VESA: mode 13h, 320x200 with one
// palette byte per pixel at 0xA0000 and 256 colors; the VESA
// BIOS's modes (VBE 2.0 and up, linear framebuffer) at 8
// bits a pixel (palette) or 15, 16, 24, 32 (true color), a
// picture scaled by a whole number and centered; without
// VESA mode 12h, 640x480 in 16 colors (the palette's
// first 16) in four bit planes at 0xA0000, plane n with
// each pixel's bit n. The DAC palette has 6 bits per component.
// The BIOS switches modes (int 10h); no paging: the
// framebuffer is written where it is.
const std = @import("std");
const platform = @import("../../platform.zig");
const realmode = @import("realmode.zig");
const port = @import("../../arch/x86_port.zig");
const console = @import("console.zig");
const memory = @import("memory.zig");

const vga: [*]volatile u8 = @ptrFromInt(0xA0000);
const bda_video_mode: *const volatile u8 = @ptrFromInt(0x449);

const Mode = enum { none, m13, m12, vesa };

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

// VESA

// A VBE mode with a linear framebuffer: 8 bits a pixel
// (palette), else true color with these fields
const Vbe = struct {
    number: u16,
    w: u32,
    h: u32,
    bits: u8,
    pitch: u32,
    lfb: u32,
    rs: u8, // red's size and position, green's, blue's
    rp: u8,
    gs: u8,
    gp: u8,
    bs: u8,
    bp: u8,

    fn bytes(m: *const Vbe) usize {
        return (@as(usize, m.bits) + 7) / 8;
    }

    // 0x00RRGGBB as written: the fields 8 bits there
    fn native(m: *const Vbe) bool {
        return m.bits == 32 and m.rs == 8 and m.rp == 16 and m.gs == 8 and m.gp == 8 and m.bs == 8 and m.bp == 0;
    }

    fn encode(m: *const Vbe, r: u8, g: u8, b: u8) u32 {
        return field(r, m.rs, m.rp) | field(g, m.gs, m.gp) | field(b, m.bs, m.bp);
    }
};

fn field(v: u8, size: u8, pos: u8) u32 {
    if (size == 0 or size > 8 or pos > 31) return 0;
    return @as(u32, v >> @intCast(8 - size)) << @intCast(pos);
}

const max_width = 4096;
const max_vbe = 64;
var probed = false;
var vbe_modes: [max_vbe]Vbe = undefined;
var vbe_count: usize = 0;
var vm: Vbe = undefined; // the mode set
var current: u16 = 0; // its number
var true_color = false; // the picture's pixels: 0x00RRGGBB (else palette bytes)
var scale: u32 = 1;
var colors: [256]u32 = @splat(0); // the palette, encoded for vm
var line: [max_width * 4]u8 = undefined; // one row, scaled and encoded

fn rd16(p: [*]const volatile u8, at: usize) u16 {
    return @as(u16, p[at]) | @as(u16, p[at + 1]) << 8;
}

fn rd32(p: [*]const volatile u8, at: usize) u32 {
    return @as(u32, rd16(p, at)) | @as(u32, rd16(p, at + 2)) << 16;
}

// The VESA BIOS's modes, once: 4F00h (the list, "VBE2" asks
// for 2.0's answer), 4F01h each (through the scratch area)
fn probe() void {
    if (probed) return;
    probed = true;
    const buf = realmode.scratch();
    @memset(buf, 0);
    @memcpy(buf[0..4], "VBE2");
    const at = @intFromPtr(buf);
    var r: realmode.Regs = .{ .eax = 0x4F00, .es = realmode.segment(at), .edi = realmode.offset(at) };
    realmode.call(0x10, &r);
    if (r.eax & 0xFFFF != 0x004F or !std.mem.eql(u8, buf[0..4], "VESA") or rd16(buf, 4) < 0x200) return;
    const version = rd16(buf, 4);
    const list_at = @as(usize, rd16(buf, 16)) * 16 + rd16(buf, 14);
    if (list_at == 0 or list_at >= 0x100000) return;
    // Copied first: it may lie in the scratch area 4F01h fills
    const list: [*]const volatile u8 = @ptrFromInt(list_at);
    var numbers: [128]u16 = undefined;
    var n: usize = 0;
    while (n < numbers.len) : (n += 1) {
        const v = rd16(list, n * 2);
        if (v == 0xFFFF) break;
        numbers[n] = v;
    }
    for (numbers[0..n]) |number| {
        if (vbe_count == max_vbe) break;
        @memset(buf[0..256], 0);
        r = .{ .eax = 0x4F01, .ecx = number, .es = realmode.segment(at), .edi = realmode.offset(at) };
        realmode.call(0x10, &r);
        if (r.eax & 0xFFFF != 0x004F) continue;
        const attr = rd16(buf, 0);
        if (attr & 0x99 != 0x99) continue; // supported, color, graphics, linear
        const m: Vbe = .{
            .number = number,
            .w = rd16(buf, 0x12),
            .h = rd16(buf, 0x14),
            .bits = buf[0x19],
            // VBE 3: the linear framebuffer's own row length
            .pitch = if (version >= 0x300 and rd16(buf, 0x32) != 0) rd16(buf, 0x32) else rd16(buf, 0x10),
            .lfb = rd32(buf, 0x28),
            .rs = buf[0x1F],
            .rp = buf[0x20],
            .gs = buf[0x21],
            .gp = buf[0x22],
            .bs = buf[0x23],
            .bp = buf[0x24],
        };
        const model = buf[0x1B];
        const ok_bits = (m.bits == 8 and model == 4) or (model == 6 and (m.bits == 15 or m.bits == 16 or m.bits == 24 or m.bits == 32));
        if (!ok_bits or m.lfb == 0 or m.w < 320 or m.w > max_width or m.h < 200 or m.pitch < m.w * m.bytes()) continue;
        vbe_modes[vbe_count] = m;
        vbe_count += 1;
    }
}

// The smallest mode a w x h picture fits (palette or true
// color ones), of those the most bits
fn pick(w: u32, h: u32, palette_mode: bool) ?usize {
    var best: ?usize = null;
    for (vbe_modes[0..vbe_count], 0..) |m, i| {
        if (m.w < w or m.h < h or (m.bits == 8) != palette_mode) continue;
        if (best) |b| {
            const o = vbe_modes[b];
            const area = @as(u64, m.w) * m.h;
            const o_area = @as(u64, o.w) * o.h;
            if (area > o_area or (area == o_area and m.bits <= o.bits)) continue;
        }
        best = i;
    }
    return best;
}

// MODES

var sizes: [max_vbe + 2]platform.ScreenSize = undefined;
var size_count: usize = 0;

// 320 x 200 and 640 x 480, the VESA modes' sizes, smallest first
pub fn modes() []const platform.ScreenSize {
    if (size_count > 0) return sizes[0..size_count];
    probe();
    addSize(320, 200);
    addSize(640, 480);
    for (vbe_modes[0..vbe_count]) |m| addSize(m.w, m.h);
    return sizes[0..size_count];
}

fn addSize(w: u32, h: u32) void {
    for (sizes[0..size_count]) |s| {
        if (s.width == w and s.height == h) return;
    }
    var i = size_count;
    while (i > 0 and @as(u64, sizes[i - 1].width) * sizes[i - 1].height > @as(u64, w) * h) : (i -= 1) sizes[i] = sizes[i - 1];
    sizes[i] = .{ .width = w, .height = h };
    size_count += 1;
}

// The screen programs asking for "the screen" get: the
// largest true color VESA mode up to 1024 x 768, else a
// palette one, else 320 x 200 in 256 colors
pub fn screen() ?platform.ScreenInfo {
    probe();
    for ([_]bool{ false, true }) |palette_mode| {
        var best: ?Vbe = null;
        for (vbe_modes[0..vbe_count]) |m| {
            if ((m.bits == 8) != palette_mode or m.w > 1024 or m.h > 768) continue;
            if (best) |b| {
                if (@as(u64, m.w) * m.h < @as(u64, b.w) * b.h) continue;
                if (m.w == b.w and m.h == b.h and m.bits <= b.bits) continue;
            }
            best = m;
        }
        if (best) |b| return .{ .width = b.w, .height = b.h, .true_color = !palette_mode };
    }
    return .{ .width = 320, .height = 200, .true_color = false };
}

// BEGIN

// dos_aspect has no effect: the monitor shows VGA's modes 4:3
// itself, VESA's pictures are scaled alike both ways
pub fn begin(w: u32, h: u32, dos_aspect: bool) platform.Error!void {
    _ = dos_aspect;
    if (w == 0 or h == 0) return error.InvalidArgument;
    if (w <= 320 and h <= 200) return beginVga(.m13, w, h);
    probe();
    if (pick(w, h, true) orelse pick(w, h, false)) |i| return beginVesa(i, w, h, false);
    if (w <= 640 and h <= 480) return beginVga(.m12, w, h);
    return error.NotSupported;
}

pub fn beginRgb(w: u32, h: u32) platform.Error!void {
    if (w == 0 or h == 0) return error.InvalidArgument;
    probe();
    const i = pick(w, h, false) orelse return error.NotSupported;
    return beginVesa(i, w, h, true);
}

fn failed() platform.Error {
    setMode(0x03);
    console.unhide();
    mode = .none;
    freeShadow();
    return error.NotSupported;
}

fn beginVga(want: Mode, w: u32, h: u32) platform.Error!void {
    if (mode != want) {
        if (mode == .none) console.hide();
        const number: u8 = if (want == .m13) 0x13 else 0x12;
        setMode(number);
        if (bda_video_mode.* & 0x7F != number) return failed(); // a VGA BIOS that can't
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
    true_color = false;
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

// 4F02h with bit 14: the linear framebuffer
fn beginVesa(i: usize, w: u32, h: u32, rgb: bool) platform.Error!void {
    const m = vbe_modes[i];
    if (mode != .vesa or current != m.number) {
        if (mode == .none) console.hide();
        var r: realmode.Regs = .{ .eax = 0x4F02, .ebx = @as(u32, m.number) | 0x4000 };
        realmode.call(0x10, &r);
        if (r.eax & 0xFFFF != 0x004F) return failed();
        mode = .vesa;
        current = m.number;
    }
    freeShadow();
    vm = m;
    true_color = rgb;
    width = w;
    height = h;
    scale = @min(m.w / w, m.h / h);
    screen_width = m.w;
    screen_height = m.h;
    left = (m.w - w * scale) / 2;
    top = (m.h - h * scale) / 2;
    const fb: [*]u8 = @ptrFromInt(m.lfb);
    for (0..m.h) |y| @memset(fb[y * m.pitch ..][0 .. m.w * m.bytes()], 0);
    @memset(&colors, 0);
    if (m.bits == 8) {
        port.outb(0x3C8, 0); // the whole palette black
        for (0..256 * 3) |_| port.outb(0x3C9, 0);
    }
}

// Mode 12h: the planes the next writes go to (the sequencer's map mask)
fn setPlanes(mask: u8) void {
    port.outb(0x3C4, 2);
    port.outb(0x3C5, mask);
}

// DRAW

pub fn palette(first: u8, rgb: []const u8) void {
    if (mode == .none) return;
    const count = @min(rgb.len / 3, 256 - @as(usize, first));
    if (mode == .vesa and vm.bits != 8) {
        for (0..count) |i| colors[first + i] = vm.encode(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2]);
        return;
    }
    port.outb(0x3C8, first);
    for (rgb[0 .. count * 3]) |c| port.outb(0x3C9, c >> 2);
}

pub fn draw(pixels: []const u8) void {
    if (mode == .none or true_color or pixels.len < width * height) return;
    if (mode == .vesa) {
        for (0..height) |y| {
            const src = pixels[y * width ..][0..width];
            if (vm.bits == 8 and scale == 1) {
                copyRow(y, src);
                continue;
            }
            var x: usize = 0;
            for (src) |p| {
                const c: u32 = if (vm.bits == 8) p else colors[p];
                for (0..scale) |_| {
                    put(x, c);
                    x += 1;
                }
            }
            copyRow(y, line[0 .. x * vm.bytes()]);
        }
        return;
    }
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

// A true color picture: each pixel 0x00RRGGBB
pub fn drawRgb(picture: []const u32) void {
    if (mode != .vesa or !true_color or picture.len < width * height) return;
    const native = vm.native();
    for (0..height) |y| {
        const src = picture[y * width ..][0..width];
        if (native and scale == 1) {
            copyRow(y, std.mem.sliceAsBytes(src));
            continue;
        }
        var x: usize = 0;
        for (src) |p| {
            const c = if (native) p else vm.encode(@truncate(p >> 16), @truncate(p >> 8), @truncate(p));
            for (0..scale) |_| {
                put(x, c);
                x += 1;
            }
        }
        copyRow(y, line[0 .. x * vm.bytes()]);
    }
}

// Pixel x of the row being made, in the mode's bytes
fn put(x: usize, c: u32) void {
    switch (vm.bytes()) {
        1 => line[x] = @truncate(c),
        2 => std.mem.writeInt(u16, line[x * 2 ..][0..2], @truncate(c), .little),
        3 => {
            line[x * 3] = @truncate(c);
            line[x * 3 + 1] = @truncate(c >> 8);
            line[x * 3 + 2] = @truncate(c >> 16);
        },
        else => std.mem.writeInt(u32, line[x * 4 ..][0..4], c, .little),
    }
}

// Picture row y, made, onto its scale's screen rows
fn copyRow(y: usize, row: []const u8) void {
    const fb: [*]u8 = @ptrFromInt(vm.lfb);
    const x0 = left * vm.bytes();
    for (0..scale) |k| {
        const sy = top + y * scale + k;
        @memcpy(fb[sy * vm.pitch + x0 ..][0..row.len], row);
    }
}

pub fn end() void {
    if (mode == .none) return;
    mode = .none;
    current = 0;
    freeShadow();
    setMode(0x03);
    console.unhide();
}
