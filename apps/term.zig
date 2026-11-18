// TERM [FONT]: a terminal in a tab of its own, with COMSPEC on a pty
// and ssh/vt.zig as the emulator.
// BIOS without VESA: 640 x 480 in 16 colors.
// Alt+Tab / Win+Tab switches tabs. FONT: spleen-8x16, terminus-12x24 ...
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const gfx = @import("zdos/gfx.zig");
const vt_mod = @import("ssh/vt.zig");

comptime {
    _ = zdos;
}

const header_size = 16; // "ZFNT" file header (tools/make-fonts.py)

const vga_rgb = [16]u32{
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
};

const Font = struct {
    data: []const u8,
    w: u32,
    h: u32,
    count: usize,
    row_bytes: usize,
    entry: usize,

    fn load(name: []const u8) ?Font {
        var vb: [300]u8 = undefined;
        const drive: u8 = if (zdos.getVar("COMSPEC", &vb)) |c| c[0] else 'C';
        var pb: [300]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{c}:\\SYSTEM\\FONTS\\{s}.zfn", .{ drive, name }) catch return null;
        const f = zdos.open(path, .read) catch return null;
        defer f.close();
        const size: usize = @intCast(f.size() catch return null);
        const data = zdos.allocator.alloc(u8, size) catch return null;
        var got: usize = 0;
        while (got < size) {
            const n = f.read(data[got..]) catch return null;
            if (n == 0) break;
            got += n;
        }
        if (got < header_size or !std.mem.eql(u8, data[0..4], "ZFNT") or data[4] != 1) return null;
        const w: u32 = data[5];
        const h: u32 = data[6];
        const count: usize = std.mem.readInt(u32, data[8..12], .little);
        const row_bytes = (w + 7) / 8;
        const entry = 4 + @as(usize, h) * row_bytes;
        if (w == 0 or h == 0 or got < header_size + count * entry) return null;
        return .{ .data = data[0..got], .w = w, .h = h, .count = count, .row_bytes = row_bytes, .entry = entry };
    }

    // Binary search: glyphs in code point order.
    fn glyph(self: *const Font, c: u21) ?[]const u8 {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = header_size + mid * self.entry;
            const code = std.mem.readInt(u32, self.data[at..][0..4], .little);
            if (code == c) return self.data[at + 4 ..][0 .. self.entry - 4];
            if (code < c) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

// 32-bit pixels (true color) or palette indexes (BIOS).
const Screen = struct {
    width: u32,
    height: u32,
    rgb: ?[]u32 = null,
    indexed: ?[]u8 = null,

    fn put(self: *Screen, x: usize, y: usize, color: u4) void {
        const i = y * self.width + x;
        if (self.rgb) |p| p[i] = vga_rgb[color] else self.indexed.?[i] = color;
    }

    fn show(self: *const Screen) void {
        if (self.rgb) |p| gfx.drawRgb(p) else gfx.draw(self.indexed.?);
    }
};

fn fontName(arg: []const u8, bios: bool, buf: []u8) []const u8 {
    if (arg.len > 0) return arg;
    if (!bios) {
        // FONT= when it names a family and size ("spleen-12x24"):
        if (zdos.getVar("FONT", buf)) |f| {
            if (std.mem.indexOfScalar(u8, f, '-') != null) return f;
        }
    }
    return "spleen-8x16";
}

pub fn main(args: []const u8) u8 {
    const arg = std.mem.trim(u8, args, " \t");
    const info = gfx.screen() catch {
        zdos.print("TERM: no graphics here\n");
        return 1;
    };
    // The screen's size (true color), else 640 x 480:
    var scr: Screen = .{ .width = info.width, .height = info.height };
    if (!info.true_color) {
        var sizes: [8]gfx.ScreenSize = undefined;
        scr.width = 0;
        for (gfx.modes(&sizes)) |s| {
            if (s.width == 640 and s.height == 480) {
                scr.width = 640;
                scr.height = 480;
            }
        }
        if (scr.width == 0) {
            scr.width = info.width;
            scr.height = info.height;
        }
    }
    var fb: [64]u8 = undefined;
    const name = fontName(arg, !info.true_color, &fb);
    const font = Font.load(name) orelse {
        zdos.printf("TERM: font {s} not found in \\SYSTEM\\FONTS\n", .{name});
        return 1;
    };
    const cols = scr.width / font.w;
    const rows = scr.height / font.h;
    if (cols < 20 or rows < 5) {
        zdos.print("TERM: the font is too big for the screen\n");
        return 1;
    }
    const pixels = @as(usize, scr.width) * scr.height;
    if (info.true_color) {
        scr.rgb = zdos.allocator.alloc(u32, pixels) catch return oom();
        @memset(scr.rgb.?, 0);
    } else {
        scr.indexed = zdos.allocator.alloc(u8, pixels) catch return oom();
        @memset(scr.indexed.?, 0);
    }

    const pty = sys.termCreate(cols, rows) catch |err| {
        zdos.printf("TERM: {s}\n", .{zdos.message(err)});
        return 1;
    };
    defer pty.close();
    var cb: [300]u8 = undefined;
    const shell = zdos.getVar("COMSPEC", &cb) orelse "C:\\APPS\\COMMAND.APP";
    const task = sys.taskSpawnWith(shell, "-d", .{ .term = pty.handle }) catch |err| {
        zdos.printf("TERM: can't start {s}: {s}\n", .{ shell, zdos.message(err) });
        return 1;
    };
    var vt = vt_mod.Vt.init(cols, rows) catch return oom();
    defer vt.deinit();
    vt.tell_console = false;

    if (info.true_color) {
        gfx.beginRgb(scr.width, scr.height) catch |err| return noGraphics(err);
    } else {
        gfx.begin(scr.width, scr.height) catch |err| return noGraphics(err);
        var pal: [16][3]u8 = undefined;
        for (vga_rgb, 0..) |c, i| pal[i] = .{ @intCast(c >> 16), @intCast(c >> 8 & 0xFF), @intCast(c & 0xFF) };
        gfx.palette(0, &pal);
    }
    defer gfx.end();
    gfx.setTitle("TERM");
    zdos.setCtrlC(true); // Ctrl+C is the shell's (a key), not ours

    var buf: [16 * 1024]u8 = undefined;
    var cursor_x: u32 = 0;
    var cursor_y: u32 = 0;
    var cursor_shown = false;
    while (sys.taskEnded(task) == null) {
        var changed = false;
        // All the shell wrote:
        var fds = [1]zdos.PollFd{.{ .handle = pty.handle, .events = zdos.Poll.in }};
        if (zdos.table().files.poll(&fds, 1, 15) > 0) {
            while (true) {
                const n = pty.read(&buf) catch 0;
                if (n == 0) break;
                vt.feed(buf[0..n]);
                changed = true;
                const reply = vt.takeReply();
                if (reply.len > 0) pty.writeAll(reply) catch {};
                fds[0].revents = 0;
                if (zdos.table().files.poll(&fds, 1, 0) <= 0) break;
            }
        }
        // Keys, as an xterm sends them:
        while (zdos.pollKey()) |k| {
            var kb: [16]u8 = undefined;
            const bytes = vt_mod.keyBytes(k, vt.app_cursor, &kb);
            if (bytes.len > 0) pty.writeAll(bytes) catch {};
        }
        // The cursor moved: its old and new rows again:
        if (vt.x != cursor_x or vt.y != cursor_y or vt.cursor_visible != cursor_shown) {
            if (cursor_y < rows) vt.dirty[cursor_y] = true;
            if (vt.y < rows) vt.dirty[vt.y] = true;
            cursor_x = vt.x;
            cursor_y = vt.y;
            cursor_shown = vt.cursor_visible;
            changed = true;
        }
        if (!changed) continue;
        for (0..rows) |y| {
            if (!vt.dirty[y]) continue;
            vt.dirty[y] = false;
            drawRow(&scr, &font, &vt, @intCast(y), cursor_x, cursor_y, cursor_shown);
        }
        scr.show();
    }
    return 0;
}

fn drawRow(scr: *Screen, font: *const Font, vt: *vt_mod.Vt, y: u32, cx: u32, cy: u32, cursor: bool) void {
    const row = vt.cells[@as(usize, y) * vt.cols ..][0..vt.cols];
    for (row, 0..) |cell, x| {
        var fg = cell.fg;
        var bg = cell.bg;
        if (cursor and y == cy and x == cx) std.mem.swap(u4, &fg, &bg); // a block cursor
        const g = if (cell.ch == ' ') null else font.glyph(cell.ch) orelse font.glyph(0xFFFD);
        const x0 = x * font.w;
        const y0 = @as(usize, y) * font.h;
        for (0..font.h) |gy| {
            const bits: []const u8 = if (g) |gl| gl[gy * font.row_bytes ..][0..font.row_bytes] else &.{};
            for (0..font.w) |gx| {
                const ink = bits.len > 0 and bits[gx / 8] & (@as(u8, 0x80) >> @intCast(gx % 8)) != 0;
                scr.put(x0 + gx, y0 + gy, if (ink) fg else bg);
            }
        }
    }
}

fn oom() u8 {
    zdos.print("TERM: out of memory\n");
    return 1;
}

fn noGraphics(err: zdos.Error) u8 {
    zdos.printf("TERM: graphics: {s}\n", .{zdos.message(err)});
    return 1;
}
