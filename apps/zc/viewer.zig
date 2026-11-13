// The internal viewer: a file's text over the whole screen.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const screen = @import("screen.zig");
const dialog = @import("dialog.zig");
const edit = @import("edit.zig");
const theme = @import("theme.zig");

const Scan = zdos.Scan;
const max_size = 64 * 1024 * 1024;
const tab = 8;

pub fn view(path: []const u8) void {
    const f = zdos.open(path, .read) catch |err| {
        _ = dialog.message("Error", &.{ path, zdos.message(err) }, true);
        return;
    };
    const size: usize = @intCast(@min(f.size() catch 0, max_size));
    const data = zdos.allocator.alloc(u8, size) catch {
        f.close();
        _ = dialog.message("Error", &.{ path, "is too big for the memory" }, true);
        return;
    };
    defer zdos.allocator.free(data);
    var n: usize = 0;
    while (n < size) {
        const got = f.read(data[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    f.close();
    const text = data[0..n];

    // Where each line starts:
    var starts: std.ArrayListUnmanaged(usize) = .{};
    defer starts.deinit(zdos.allocator);
    starts.append(zdos.allocator, 0) catch return;
    for (text, 0..) |c, i| {
        if (c == '\n' and i + 1 < text.len) starts.append(zdos.allocator, i + 1) catch break;
    }
    const lines = starts.items;

    var top: usize = 0;
    var left: usize = 0;
    while (true) {
        if (!screen.resize()) return;
        const h = screen.rows -| 2; // the text rows
        const max_top = lines.len -| h;
        top = @min(top, max_top);
        draw(path, text, lines, top, left, h);
        screen.flush();
        zdos.showCursor(false);
        const k = zdos.readKey();
        if (k.scan == Scan.redraw) {
            screen.invalidate();
            continue;
        }
        if (edit.isEsc(k) or k.char == 'q' or k.char == 'Q') return;
        if (edit.fkey(k)) |fk| {
            if (fk == 3 or fk == 10) return;
        }
        const page = @max(h, 2) - 1;
        switch (k.scan) {
            Scan.up => top -|= 1,
            Scan.down => top = @min(top + 1, max_top),
            Scan.page_up => top -|= page,
            Scan.page_down => top = @min(top + page, max_top),
            Scan.home => {
                top = 0;
                left = 0;
            },
            Scan.end => top = max_top,
            Scan.left => left -|= tab,
            Scan.right => left += tab,
            else => if (k.char == ' ') {
                top = @min(top + page, max_top);
            },
        }
    }
}

fn draw(path: []const u8, text: []const u8, lines: []const usize, top: usize, left: usize, h: u32) void {
    const w = screen.cols;
    // Name and place at the top:
    var info_buf: [64]u8 = undefined;
    const last = @min(top + h, lines.len);
    const pct = if (lines.len <= h) 100 else last * 100 / lines.len;
    const info = std.fmt.bufPrint(&info_buf, "  Line {d}/{d}  Col {d}  {d}%", .{ top + 1, lines.len, left + 1, pct }) catch "";
    const iw: u32 = @intCast(@min(info.len, w));
    _ = screen.text(0, 0, path, w - iw, .black, theme.now.accent);
    _ = screen.text(w - iw, 0, info, iw, .black, theme.now.accent);

    for (0..h) |row| {
        const y: u32 = @intCast(1 + row);
        const i = top + row;
        if (i >= lines.len) {
            screen.fill(0, y, w, 1, ' ', theme.now.text, theme.now.panel);
            continue;
        }
        const end = if (i + 1 < lines.len) lines[i + 1] else text.len;
        drawLine(text[lines[i]..end], y, left, w);
    }

    const hint = " Esc, F3, F10: close   Arrows, PgUp, PgDn, Home, End, Space: move";
    _ = screen.text(0, screen.rows - 1, hint, w, .black, theme.now.accent);
}

// One line from column left; tabs every 8 columns,
// control bytes as '.':
fn drawLine(line: []const u8, y: u32, left: usize, w: u32) void {
    var col: usize = 0;
    var i: usize = 0;
    while (i < line.len and col < left + w) {
        const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        var c: u21 = '.';
        if (i + len <= line.len) c = std.unicode.utf8Decode(line[i..][0..len]) catch '.';
        i += if (i + len <= line.len) len else 1;
        if (c == '\n' or c == '\r') continue;
        if (c == '\t') {
            const next = (col / tab + 1) * tab;
            while (col < next) : (col += 1) cell(col, left, w, y, ' ');
            continue;
        }
        if (c < 0x20 or c == 0x7F) c = '.';
        cell(col, left, w, y, c);
        col += 1;
    }
    while (col < left + w) : (col += 1) cell(col, left, w, y, ' ');
}

fn cell(col: usize, left: usize, w: u32, y: u32, c: u21) void {
    if (col < left or col >= left + w) return;
    screen.put(@intCast(col - left), y, c, theme.now.text, theme.now.panel);
}
