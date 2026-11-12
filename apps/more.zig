// MORE: text a screen at a time, both ways. Each row keeps its ANSI colors;
// drawing is kept small for the slow UEFI console.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

const Scan = zdos.Scan;
const List = std.ArrayListUnmanaged;
const alloc = zdos.allocator;

// VGA numbers, as the ZDOS screen keeps them.
const Colors = struct {
    fg: u8 = 7, // 0-15
    bg: u8 = 0, // 0-7
    bold: bool = false,
    reverse: bool = false,
};

const Row = struct {
    start: u32,
    colors: Colors,
};

pub fn main(args: []const u8) u8 {
    // Quotes are removed wherever they are ("My Folder"\x.txt):
    var name_buf: [1024]u8 = undefined;
    var name_len: usize = 0;
    for (std.mem.trim(u8, args, " \t")) |c| {
        if (c == '"' or name_len == name_buf.len) continue;
        name_buf[name_len] = c;
        name_len += 1;
    }
    const name = name_buf[0..name_len];
    var text: List(u8) = .{};
    if (name.len > 0) {
        const f = zdos.open(name, .read) catch |err| {
            zdos.printf("{s}: {s}\n", .{ name, zdos.message(err) });
            return 1;
        };
        defer f.close();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = f.read(&buf) catch |err| {
                // Show what was read; the error comes after:
                showText(text.items);
                zdos.printf("Read error: {s}\n", .{zdos.message(err)});
                return 1;
            };
            if (n == 0) break;
            if (!add(&text, &buf, n)) return 1;
        }
    } else if (zdos.inputRedirected()) {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = zdos.readInput(&buf);
            if (n == 0) break;
            if (!add(&text, &buf, n)) return 1;
        }
    } else {
        zdos.print("Usage: MORE file, MORE < file, or command | MORE\n");
        return 1;
    }
    showText(text.items);
    return 0;
}

// As TYPE: no '\r', ESC kept for colors, other control characters '.'.
fn add(text: *List(u8), buf: []u8, n: usize) bool {
    var m: usize = 0;
    for (buf[0..n]) |c| {
        if (c == '\r') continue;
        buf[m] = if (c >= 0x20 or c == '\n' or c == '\t' or c == 0x1B) c else '.';
        m += 1;
    }
    text.appendSlice(alloc, buf[0..m]) catch {
        zdos.print("Not enough memory for MORE\n");
        return false;
    };
    return true;
}

fn showText(data: []const u8) void {
    if (zdos.outputRedirected()) {
        zdos.print(data);
        return;
    }
    const screen = zdos.screenSize();
    const width: usize = @max(screen.col, 20);
    const page: usize = @max(screen.row, 2) - 1; // the last row is for the status

    var rows: List(Row) = .{};
    if (!wrapRows(data, width, &rows)) {
        zdos.print("Not enough memory for MORE\n");
        return;
    }
    if (rows.items.len <= page) {
        // A full row has moved the cursor to the next already; a shorter one
        // ends with a newline:
        for (0..rows.items.len) |r| {
            if (printRow(data, rows.items, r, width, false) < width) zdos.print("\n");
        }
        return;
    }
    view(data, rows.items, width, page);
}

// At word boundaries; escape sequences take no room, their colors are
// noted for the next rows.
fn wrapRows(data: []const u8, width: usize, rows: *List(Row)) bool {
    var colors: Colors = .{};
    var i: usize = 0;
    while (i < data.len) {
        rows.append(alloc, .{ .start = @intCast(i), .colors = colors }) catch return false;
        var col: usize = 0;
        // The last place after a blank, and the colors there:
        var cut: ?usize = null;
        var cut_colors = colors;
        while (i < data.len and data[i] != '\n') {
            if (data[i] == 0x1B) {
                i = escape(data, i, &colors);
                continue;
            }
            const blank = data[i] == ' ' or data[i] == '\t';
            const advance: usize = if (data[i] == '\t') 8 - col % 8 else if (data[i] & 0xC0 == 0x80) 0 else 1;
            if (col + advance > width) { // continues on the next row
                if (blank) {
                    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) i += 1;
                } else if (cut) |c| {
                    i = c;
                    colors = cut_colors;
                }
                break;
            }
            col += advance;
            i += 1;
            if (blank) {
                cut = i;
                cut_colors = colors;
            }
        }
        if (i < data.len and data[i] == '\n') i += 1;
    }
    return true;
}

fn view(data: []const u8, rows: []const Row, width: usize, page: usize) void {
    const last_top = rows.len - page;
    var top: usize = 0;
    // Ctrl+C quits like Q, so the status row is cleaned up:
    zdos.setCtrlC(true);
    zdos.clearScreen();
    drawPage(data, rows, top, width, page);
    while (true) {
        // The key, and any already waiting behind it:
        var next: ?usize = move(zdos.readKey(), top, last_top, page);
        while (next != null) {
            const k = zdos.pollKey() orelse break;
            next = move(k, next.?, last_top, page);
        }
        const new_top = next orelse break;
        if (new_top == top) continue;
        if (new_top > top and new_top - top < page / 2) {
            // A few lines on: let the screen scroll, then draw the new lines:
            const lines = new_top - top;
            for (0..lines) |n| {
                zdos.setCursor(0, @intCast(page)); // the status row, the last one
                zdos.print("\n"); // scrolls everything up by one
                drawRow(data, rows, top + page + n, page - 1, width);
            }
            top = new_top;
            drawStatus(rows.len, top, width, page);
        } else {
            top = new_top;
            drawPage(data, rows, top, width, page);
        }
    }
    // Leave the text on the screen; the prompt comes on the status row:
    zdos.setColor(.light_gray, .black);
    zdos.setCursor(0, @intCast(page));
    spaces(width - 1);
    zdos.setCursor(0, @intCast(page));
}

// Null to stop.
fn move(k: zdos.Key, top: usize, last_top: usize, page: usize) ?usize {
    // Ctrl+C: character 3, or C with Ctrl as some firmware reports it:
    const ctrl = k.mods & (zdos.Mod.left_ctrl | zdos.Mod.right_ctrl) != 0;
    if (k.char == 3 or (ctrl and (k.char == 'c' or k.char == 'C'))) return null;
    return switch (k.scan) {
        Scan.down => @min(top + 1, last_top),
        Scan.up => top -| 1,
        Scan.page_down => @min(top + page, last_top),
        Scan.page_up => top -| page,
        Scan.home => 0,
        Scan.end => last_top,
        Scan.esc => null,
        else => switch (k.char) {
            '\r' => @min(top + 1, last_top),
            ' ' => if (top == last_top) null else @min(top + page, last_top),
            'b', 'B' => top -| page,
            'q', 'Q' => null,
            else => top,
        },
    };
}

fn drawPage(data: []const u8, rows: []const Row, top: usize, width: usize, page: usize) void {
    for (0..page) |r| drawRow(data, rows, top + r, r, width);
    drawStatus(rows.len, top, width, page);
}

// Padded with blanks.
fn drawRow(data: []const u8, rows: []const Row, index: usize, screen_row: usize, width: usize) void {
    zdos.setCursor(0, @intCast(screen_row));
    const col = printRow(data, rows, index, width, true);
    // A full row moves the cursor on: fine, the status row is below:
    zdos.setColor(.light_gray, .black);
    if (col < width) spaces(width - col);
}

// set_colors: start with the colors in effect at the row. Returns the
// columns it filled.
fn printRow(data: []const u8, rows: []const Row, index: usize, width: usize, set_colors: bool) usize {
    var line: [1024]u8 = undefined;
    var n: usize = 0;
    var col: usize = 0;
    if (index < rows.len) {
        if (set_colors) n = colorSequence(rows[index].colors, &line);
        var i: usize = rows[index].start;
        const end = if (index + 1 < rows.len) rows[index + 1].start else data.len;
        while (i < end and data[i] != '\n') : (i += 1) {
            if (n + 8 > line.len) { // long escape sequences: print what we have
                zdos.print(line[0..n]);
                n = 0;
            }
            if (data[i] == 0x1B) { // colors copied as they are
                const e = escape(data, i, null);
                if (!isColor(data[i..e])) {
                    i = e - 1;
                    continue;
                }
                const len = e - i;
                if (n + len > line.len) {
                    zdos.print(line[0..n]);
                    n = 0;
                }
                if (len <= line.len) { // longer ones can't be colors anyway
                    @memcpy(line[n..][0..len], data[i..e]);
                    n += len;
                }
                i = e - 1;
                continue;
            }
            if (data[i] == '\t') {
                const to = @min(width, col + 8 - col % 8);
                while (col < to) : (col += 1) {
                    line[n] = ' ';
                    n += 1;
                    if (n == line.len) {
                        zdos.print(line[0..n]);
                        n = 0;
                    }
                }
                continue;
            }
            if (data[i] == ' ' and col >= width) continue; // blanks past the row's end
            if (data[i] & 0xC0 != 0x80) col += 1;
            line[n] = data[i];
            n += 1;
        }
    }
    zdos.print(line[0..n]);
    return col;
}

// "ESC [ digits and ; m"
fn isColor(seq: []const u8) bool {
    if (seq.len < 3 or seq[1] != '[' or seq[seq.len - 1] != 'm') return false;
    for (seq[2 .. seq.len - 1]) |c| {
        if (!(c >= '0' and c <= '9') and c != ';') return false;
    }
    return true;
}

fn drawStatus(count: usize, top: usize, width: usize, page: usize) void {
    zdos.setCursor(0, @intCast(page));
    zdos.setColor(.black, .light_gray);
    var status: [160]u8 = undefined;
    const bottom = @min(top + page, count);
    const s = std.fmt.bufPrint(&status, " -- MORE -- rows {d}-{d} of {d} ({d}%)   Space PgDn PgUp Up Down Home End   Q quit", .{
        top + 1, bottom, count, bottom * 100 / count,
    }) catch "";
    const shown = s[0..@min(s.len, width - 1)];
    zdos.print(shown);
    spaces(width - 1 - shown.len); // the last cell would scroll
    zdos.setColor(.light_gray, .black);
}

fn spaces(count: usize) void {
    const blanks = " " ** 80;
    var left = count;
    while (left > 0) {
        const n = @min(left, blanks.len);
        zdos.print(blanks[0..n]);
        left -= n;
    }
}

// COLORS: the rules of src/kernel/ansi.zig, so MORE knows the colors at
// the start of each row

// ANSI color order as VGA numbers; the table also maps back.
const vga = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

// The 16 colors as RGB in VGA order (xterm's), for 256-color and RGB:
const palette = [16][3]u8{
    .{ 0, 0, 0 },       .{ 0, 0, 238 },   .{ 0, 205, 0 },   .{ 0, 205, 205 },
    .{ 205, 0, 0 },     .{ 205, 0, 205 }, .{ 205, 205, 0 }, .{ 229, 229, 229 },
    .{ 127, 127, 127 }, .{ 92, 92, 255 }, .{ 0, 255, 0 },   .{ 0, 255, 255 },
    .{ 255, 0, 0 },     .{ 255, 0, 255 }, .{ 255, 255, 0 }, .{ 255, 255, 255 },
};

// Applies it to colors if it is a color sequence. Returns the index after it.
fn escape(data: []const u8, start: usize, colors: ?*Colors) usize {
    var i = start + 1;
    if (i >= data.len) return i;
    if (data[i] != '[') { // "ESC 7", "ESC ( B"
        while (i < data.len and data[i] >= 0x20 and data[i] <= 0x2F) i += 1;
        if (i < data.len and data[i] >= 0x30 and data[i] <= 0x7E) i += 1;
        return i;
    }
    i += 1;
    var params: [16]u16 = undefined;
    var count: usize = 0;
    var private = false;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        switch (c) {
            '0'...'9' => {
                if (count == 0) startParam(&params, &count);
                if (count <= params.len) {
                    const p = &params[count - 1];
                    p.* = p.* *| 10 +| (c - '0');
                }
            },
            ';' => {
                if (count == 0) startParam(&params, &count);
                startParam(&params, &count);
            },
            0x3A, 0x3C...0x3F => private = true,
            0x20...0x2F => {},
            0x40...0x7E => {
                if (c == 'm' and !private) {
                    if (colors) |col| sgr(col, params[0..@min(count, params.len)]);
                }
                return i + 1;
            },
            else => return i, // cancelled; the byte is text again
        }
    }
    return i;
}

fn startParam(params: *[16]u16, count: *usize) void {
    count.* += 1;
    if (count.* <= params.len) params[count.* - 1] = 0;
}

fn sgr(c: *Colors, params: []const u16) void {
    if (params.len == 0) {
        c.* = .{};
        return;
    }
    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => c.* = .{},
            1 => c.bold = true,
            22 => c.bold = false,
            7 => c.reverse = true,
            27 => c.reverse = false,
            30...37 => c.fg = vga[p - 30],
            39 => c.fg = 7,
            40...47 => c.bg = vga[p - 40],
            49 => c.bg = 0,
            90...97 => c.fg = vga[p - 90] + 8,
            100...107 => c.bg = vga[p - 100],
            38, 48 => {
                if (i + 1 >= params.len) break;
                var color: ?u8 = null;
                if (params[i + 1] == 5 and i + 2 < params.len) {
                    color = from256(params[i + 2]);
                    i += 2;
                } else if (params[i + 1] == 2 and i + 4 < params.len) {
                    color = nearest(clamp(params[i + 2]), clamp(params[i + 3]), clamp(params[i + 4]));
                    i += 4;
                } else {
                    break;
                }
                if (color) |col| {
                    if (p == 38) c.fg = col else c.bg = col & 7;
                }
            },
            else => {},
        }
    }
}

fn clamp(v: u16) u8 {
    return @intCast(@min(v, 255));
}

fn from256(n: u16) ?u8 {
    if (n < 8) return vga[n];
    if (n < 16) return vga[n - 8] + 8;
    if (n < 232) {
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        const k = n - 16;
        return nearest(levels[k / 36], levels[k / 6 % 6], levels[k % 6]);
    }
    if (n < 256) {
        const g: u8 = @intCast(8 + (n - 232) * 10);
        return nearest(g, g, g);
    }
    return null;
}

fn nearest(r: u8, g: u8, b: u8) u8 {
    var best: u8 = 0;
    var best_dist: u32 = ~@as(u32, 0);
    for (palette, 0..) |c, i| {
        const dr = @as(i32, r) - c[0];
        const dg = @as(i32, g) - c[1];
        const db = @as(i32, b) - c[2];
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(i);
        }
    }
    return best;
}

// "ESC [ 0 ; 38;5;f ; 48;5;b ... m": 38;5 with 0-15 is a plain color,
// so the screen ends up with the same state.
fn colorSequence(c: Colors, buf: []u8) usize {
    const s = std.fmt.bufPrint(buf, "\x1b[0;38;5;{d};48;5;{d}{s}{s}m", .{
        ansiNumber(c.fg),
        ansiNumber(c.bg),
        if (c.bold) ";1" else "",
        if (c.reverse) ";7" else "",
    }) catch return 0;
    return s.len;
}

fn ansiNumber(v: u8) u8 {
    return if (v < 8) vga[v] else vga[v - 8] + 8;
}
