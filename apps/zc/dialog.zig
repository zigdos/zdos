// Boxes over the panels: questions, messages, input.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const screen = @import("screen.zig");
const frames = @import("frames.zig");
const edit = @import("edit.zig");
const theme = @import("theme.zig");

pub var set: frames.Set = frames.of(.double);
// Draws the panels under a box:
pub var redraw: *const fn () void = noRedraw;

fn noRedraw() void {}

const Look = struct { fg: screen.Color, bg: screen.Color };
const normal: Look = .{ .fg = .black, .bg = .light_gray };
const alarm: Look = .{ .fg = .white, .bg = .red };

const Box = struct { x: u32, y: u32, w: u32, h: u32, look: Look };

// Centred, with room for lines and a key hint:
fn box(title: []const u8, inner_w: usize, inner_h: usize, look: Look) Box {
    redraw();
    // The frame on the box's edges, a space inside it:
    const w: u32 = @intCast(@min(inner_w + 4, screen.cols));
    const h: u32 = @intCast(@min(inner_h + 2, screen.rows));
    const x = (screen.cols - w) / 2;
    const y = (screen.rows -| h) / 2;
    screen.fill(x, y, w, h, ' ', look.fg, look.bg);
    frame(x, y, w, h, title, look);
    return .{ .x = x + 2, .y = y + 1, .w = w -| 4, .h = h -| 2, .look = look };
}

// A frame with title in its top line:
fn frame(fx: u32, fy: u32, fw: u32, fh: u32, title: []const u8, look: Look) void {
    for (fx + 1..fx + fw - 1) |i| {
        screen.put(@intCast(i), fy, set.h, look.fg, look.bg);
        screen.put(@intCast(i), fy + fh - 1, set.h, look.fg, look.bg);
    }
    for (fy + 1..fy + fh - 1) |j| {
        screen.put(fx, @intCast(j), set.v, look.fg, look.bg);
        screen.put(fx + fw - 1, @intCast(j), set.v, look.fg, look.bg);
    }
    screen.put(fx, fy, set.tl, look.fg, look.bg);
    screen.put(fx + fw - 1, fy, set.tr, look.fg, look.bg);
    screen.put(fx, fy + fh - 1, set.bl, look.fg, look.bg);
    screen.put(fx + fw - 1, fy + fh - 1, set.br, look.fg, look.bg);
    frameText(fx, fy, fw, title, look);
}

// Text centred in a frame line, a space either side:
fn frameText(fx: u32, y: u32, fw: u32, text: []const u8, look: Look) void {
    if (text.len == 0) return;
    const tw: u32 = @intCast(@min(screen.textWidth(text) + 2, fw -| 2));
    const tx = fx + (fw - tw) / 2;
    screen.put(tx, y, ' ', look.fg, look.bg);
    _ = screen.text(tx + 1, y, text, tw -| 2, look.fg, look.bg);
    screen.put(tx + tw - 1, y, ' ', look.fg, look.bg);
}

fn widest(lines: []const []const u8, hint: []const u8) usize {
    var w: usize = screen.textWidth(hint);
    for (lines) |l| w = @max(w, screen.textWidth(l));
    return @max(w, 20);
}

fn body(b: Box, lines: []const []const u8, hint: []const u8) void {
    for (lines, 0..) |l, i| centre(b, b.y + @as(u32, @intCast(i)), l);
    centre(b, b.y + b.h - 1, hint);
    screen.flush();
}

fn centre(b: Box, y: u32, s: []const u8) void {
    const n: u32 = @intCast(@min(screen.textWidth(s), b.w));
    _ = screen.text(b.x + (b.w - n) / 2, y, s, n, b.look.fg, b.look.bg);
}

fn hideCursor() void {
    zdos.showCursor(false);
}

pub fn confirm(title: []const u8, lines: []const []const u8, warn: bool) bool {
    const hint = "Enter: yes   Esc: no";
    const b = box(title, widest(lines, hint), lines.len + 2, if (warn) alarm else normal);
    body(b, lines, hint);
    hideCursor();
    while (true) {
        const k = zdos.readKey();
        if (edit.isEnter(k) or k.char == 'y' or k.char == 'Y') return true;
        if (edit.isEsc(k) or k.char == 'n' or k.char == 'N') return false;
    }
}

pub const Answer = enum { yes, all, skip, cancel };

pub fn ask(title: []const u8, lines: []const []const u8) Answer {
    const hint = "Y: yes   A: all   N: skip   Esc: stop";
    const b = box(title, widest(lines, hint), lines.len + 2, alarm);
    body(b, lines, hint);
    hideCursor();
    while (true) {
        const k = zdos.readKey();
        if (edit.isEnter(k) or k.char == 'y' or k.char == 'Y') return .yes;
        if (k.char == 'a' or k.char == 'A') return .all;
        if (k.char == 'n' or k.char == 'N' or k.char == 's' or k.char == 'S') return .skip;
        if (edit.isEsc(k)) return .cancel;
    }
}

// False: Esc (stop what is under way)
pub fn message(title: []const u8, lines: []const []const u8, warn: bool) bool {
    const hint = "Enter: go on   Esc: stop";
    const b = box(title, widest(lines, hint), lines.len + 2, if (warn) alarm else normal);
    body(b, lines, hint);
    hideCursor();
    while (true) {
        const k = zdos.readKey();
        if (edit.isEnter(k) or k.char == ' ') return true;
        if (edit.isEsc(k)) return false;
    }
}

// Work under way: name, its bar, the total's bar and a
// line under them; no key.
pub fn progress(title: []const u8, name: []const u8, file: [2]u64, total: [2]u64, info: []const u8) void {
    const hint = "Esc: stop";
    const w = @min(screen.cols -| 10, 60);
    const b = box(title, w, 6, normal);
    _ = screen.text(b.x, b.y, name, b.w, b.look.fg, b.look.bg);
    bar(b.x, b.y + 1, b.w, file[0], file[1]);
    bar(b.x, b.y + 2, b.w, total[0], total[1]);
    centre(b, b.y + 3, info);
    centre(b, b.y + b.h - 1, hint);
    screen.flush();
    hideCursor();
}

fn bar(x: u32, y: u32, w: u32, done: u64, all: u64) void {
    const filled: u32 = if (all == 0) w else @intCast(@min(done, all) * w / all);
    for (0..w) |i| {
        const c = if (i < filled) set.done else set.todo;
        screen.put(x + @as(u32, @intCast(i)), y, c, .blue, normal.bg);
    }
}

// Lines from the left; any key closes it:
pub fn help(title: []const u8, lines: []const []const u8) void {
    // The hint in the bottom frame line, so 25 rows hold it:
    const hint = "Any key: close";
    const b = box(title, widest(lines, hint), lines.len, .{ .fg = .black, .bg = theme.now.accent });
    frameText(b.x - 2, b.y + b.h, b.w + 4, hint, b.look);
    for (lines, 0..) |l, i| {
        if (i >= b.h) break;
        _ = screen.text(b.x, b.y + @as(u32, @intCast(i)), l, b.w, b.look.fg, b.look.bg);
    }
    screen.flush();
    hideCursor();
    // Not a modifier alone (Shift on the way to a key):
    while (edit.isModifierOnly(zdos.readKey())) {}
}

// Shown while work goes on; no key:
pub fn status(title: []const u8, lines: []const []const u8) void {
    const b = box(title, widest(lines, ""), lines.len + 2, normal);
    body(b, lines, "");
    hideCursor();
}

// The text typed into buf; null: Esc.
pub fn input(title: []const u8, prompt: []const u8, initial: []const u8, buf: []u8) ?[]const u8 {
    var line: edit.Line = .{};
    line.set(initial);
    const hint = "Enter: OK   Esc: cancel";
    const w = @max(@max(screen.textWidth(prompt), hint.len), @min(screen.cols -| 10, 60));
    while (true) {
        const b = box(title, w, 4, normal);
        _ = screen.text(b.x, b.y, prompt, b.w, b.look.fg, b.look.bg);
        const caret = line.draw(b.x, b.y + 1, b.w, theme.now.field_fg, theme.now.field_bg);
        centre(b, b.y + b.h - 1, hint);
        screen.flush();
        zdos.setCursor(caret, b.y + 1);
        zdos.showCursor(true);
        const k = zdos.readKey();
        if (edit.isEnter(k)) return line.utf8(buf);
        if (edit.isEsc(k)) return null;
        _ = line.key(k);
    }
}

// One of items (its index), or null: Esc. The list
// scrolls when the screen is too short for it.
pub fn menu(title: []const u8, items: []const []const u8, initial: usize) ?usize {
    if (items.len == 0) return null;
    var at = @min(initial, items.len - 1);
    var top: usize = 0;
    const hint = "Arrows, Enter   Esc: cancel";
    while (true) {
        const rows = @min(items.len, screen.rows -| 8);
        if (rows == 0) return null;
        const b = box(title, widest(items, hint) + 2, rows + 2, normal);
        if (at < top) top = at;
        if (at >= top + rows) top = at + 1 - rows;
        for (0..rows) |r| {
            const i = top + r;
            const on = i == at;
            const fg: screen.Color = if (on) .white else b.look.fg;
            const bg: screen.Color = if (on) .black else b.look.bg;
            const y = b.y + @as(u32, @intCast(r));
            screen.put(b.x, y, ' ', fg, bg);
            _ = screen.text(b.x + 1, y, items[i], b.w -| 1, fg, bg);
        }
        centre(b, b.y + b.h - 1, hint);
        screen.flush();
        hideCursor();
        const k = zdos.readKey();
        if (edit.isEsc(k)) return null;
        if (edit.isEnter(k)) return at;
        switch (k.scan) {
            zdos.Scan.up => at = if (at == 0) items.len - 1 else at - 1,
            zdos.Scan.down => at = (at + 1) % items.len,
            zdos.Scan.home, zdos.Scan.page_up => at = 0,
            zdos.Scan.end, zdos.Scan.page_down => at = items.len - 1,
            else => {},
        }
    }
}

// A drive letter, or null:
pub fn chooseDrive(title: []const u8, current: u8) ?u8 {
    var letters_buf: [26]u8 = undefined;
    const letters = zdos.getDrives(&letters_buf);
    if (letters.len == 0) return null;
    var at: usize = 0;
    for (letters, 0..) |l, i| {
        if (l == std.ascii.toUpper(current)) at = i;
    }
    const hint = "Arrows, Enter or a letter";
    while (true) {
        const b = box(title, @max(letters.len * 4, hint.len), 3, normal);
        const row_w: u32 = @intCast(letters.len * 4);
        const x0 = b.x + (b.w -| row_w) / 2;
        for (letters, 0..) |l, i| {
            const on = i == at;
            const fg: screen.Color = if (on) .white else .black;
            const bg: screen.Color = if (on) theme.now.pick_bg else b.look.bg;
            const x = x0 + @as(u32, @intCast(i * 4));
            screen.put(x, b.y, ' ', fg, bg);
            screen.put(x + 1, b.y, l, fg, bg);
            screen.put(x + 2, b.y, ' ', fg, bg);
        }
        centre(b, b.y + b.h - 1, hint);
        screen.flush();
        hideCursor();
        const k = zdos.readKey();
        if (edit.isEsc(k)) return null;
        if (edit.isEnter(k)) return letters[at];
        if (k.scan == zdos.Scan.left or k.scan == zdos.Scan.up) at = if (at == 0) letters.len - 1 else at - 1;
        if (k.scan == zdos.Scan.right or k.scan == zdos.Scan.down) at = (at + 1) % letters.len;
        if (k.char < 128 and std.ascii.isAlphabetic(@intCast(k.char))) {
            const want = std.ascii.toUpper(@intCast(k.char));
            if (std.mem.indexOfScalar(u8, letters, want) != null) return want;
        }
    }
}
