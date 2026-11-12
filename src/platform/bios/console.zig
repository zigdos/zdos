// Console: VGA text mode written directly into video memory,
// mirrored to COM1 (serial.zig); PS/2 keyboard and mouse: their
// IRQs queue the bytes during waits, polling takes the rest;
// keys from COM1 too
const std = @import("std");
const platform = @import("../../platform.zig");
const port = @import("../../arch/x86_port.zig");
const cp437 = @import("../../drivers/cp437.zig");
const realmode = @import("realmode.zig");
const kbd = @import("../../drivers/ps2kbd.zig");
const arch = @import("../../arch/x86.zig");
const mouse = @import("../../drivers/ps2mouse.zig");
const serial = @import("serial.zig");
const terminal = @import("../../drivers/serial/terminal.zig").Terminal(serial);

const text_memory: [*]volatile u16 = @ptrFromInt(0xB8000);
// The screen, or during graphics (graphics.zig) a shadow copy
// that is put back afterwards
var video: [*]volatile u16 = text_memory;
var shadow: [132 * 60]u16 = undefined;
var hidden = false;
// While the scrollback (kernel/scrollback.zig) shows history on
// the screen, the live text goes here; the
// main screen while the alternate one is on
var live: [132 * 60]u16 = undefined;
var viewing = false;
var alt_saved: [132 * 60]u16 = undefined;
var alt_col: u32 = 0;
var alt_row: u32 = 0;
var scroll_hook: ?*const fn () void = null;
var cursor_visible = true;
const crtc_index = 0x3D4;
const crtc_data = 0x3D5;

var cols: u32 = 80;
var rows: u32 = 25;
var col: u32 = 0;
var row: u32 = 0;
var attr: u8 = 0x07; // light gray on black
var cursor_start: u8 = 0x0D; // the cursor's shape, as the BIOS set it
var cursor_end: u8 = 0x0E;

pub fn init() void {
    // Screen size from the BIOS data area (stage 2 set 80x25)
    const bda_cols: *const volatile u16 = @ptrFromInt(0x44A);
    const bda_rows: *const volatile u8 = @ptrFromInt(0x484);
    if (bda_cols.* >= 40 and bda_cols.* <= 132) cols = bda_cols.*;
    if (bda_rows.* >= 24 and bda_rows.* < 60) rows = @as(u32, bda_rows.*) + 1;
    cursor_start = crtc(0x0A) & 0x1F;
    cursor_end = crtc(0x0B) & 0x1F;
    serial.init();
    kbd.init();
    mouse.init();
    clear();
    showCursor(true);
}

fn crtc(reg: u8) u8 {
    port.outb(crtc_index, reg);
    return port.inb(crtc_data);
}

fn setCrtc(reg: u8, val: u8) void {
    port.outb(crtc_index, reg);
    port.outb(crtc_data, val);
}

fn cell(c: u8) u16 {
    return @as(u16, attr) << 8 | c;
}

pub fn clear() void {
    for (0..cols * rows) |i| video[i] = cell(' ');
    col = 0;
    row = 0;
    terminal.clear();
    updateCursor();
}

fn scroll() void {
    if (scroll_hook) |f| f(); // the top row into the scrollback, before it goes
    const n = cols * (rows - 1);
    for (0..n) |i| video[i] = video[i + cols];
    for (n..n + cols) |i| video[i] = cell(' ');
}

fn newline() void {
    col = 0;
    if (row + 1 < rows) {
        row += 1;
    } else {
        scroll();
    }
}

fn put(c: u8) void {
    video[row * cols + col] = cell(c);
    col += 1;
    if (col >= cols) newline();
}

// Each byte's character, for the scrollback (CP437's until setCodepage)
var to_char: [256]u21 = undefined;
var have_to_char = false;

fn charOf(b: u8) u21 {
    return if (have_to_char) to_char[b] else cp437.toUnicode(b);
}

// The codepage's byte for each character, sorted by character
// for byteOf's binary search.
// Empty until setCodepage: CP437 (cp437.zig).
const Entry = struct { char: u21, byte: u8 };
var by_char: [256]Entry = undefined;
var by_char_count: usize = 0;

// points[b]: the character of byte b (0 for none), as
// in a codepage file. Set together with the font, so
// bytes and glyphs agree.
pub fn setCodepage(points: *const [256]u32) void {
    for (points, 0..) |p, b| to_char[b] = if (p == 0 or p > 0x10FFFF) '?' else @intCast(p);
    have_to_char = true;
    var n: usize = 0;
    for (points, 0..) |p, b| {
        if (p == 0 or p > 0x10FFFF) continue;
        by_char[n] = .{ .char = @intCast(p), .byte = @intCast(b) };
        n += 1;
    }
    // insertion sort: 256 entries, once
    for (1..n) |i| {
        const e = by_char[i];
        var j = i;
        while (j > 0 and by_char[j - 1].char > e.char) : (j -= 1) by_char[j] = by_char[j - 1];
        by_char[j] = e;
    }
    by_char_count = n;
}

fn byteOf(c: u21) ?u8 {
    if (by_char_count == 0) return cp437.fromUnicode(c);
    var lo: usize = 0;
    var hi: usize = by_char_count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (by_char[mid].char < c) lo = mid + 1 else hi = mid;
    }
    if (lo < by_char_count and by_char[lo].char == c) return by_char[lo].byte;
    return null;
}

// UTF-8 text; characters the codepage has no byte for become '?'
pub fn write(str: []const u8) void {
    var i: usize = 0;
    while (i < str.len) {
        const len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const c: u21 = if (i + len <= str.len) std.unicode.utf8Decode(str[i..][0..len]) catch '?' else '?';
        i += if (i + len <= str.len) len else 1;
        switch (c) {
            '\n' => newline(),
            '\r' => col = 0,
            '\t' => {
                put(' ');
                while (col % 8 != 0) put(' ');
            },
            0x08 => { // erase the character before the cursor
                if (col > 0) {
                    col -= 1;
                } else if (row > 0) {
                    row -= 1;
                    col = cols - 1;
                }
                video[row * cols + col] = cell(' ');
            },
            else => put(byteOf(c) orelse '?'),
        }
    }
    updateCursor();
    terminal.write(str);
}

fn updateCursor() void {
    if (hidden) return;
    const pos: u16 = @intCast(row * cols + col);
    setCrtc(0x0F, @truncate(pos));
    setCrtc(0x0E, @truncate(pos >> 8));
}

pub fn getCursor() platform.Position {
    return .{ .col = col, .row = row };
}

pub fn setCursor(pos: platform.Position) void {
    col = @min(pos.col, cols - 1);
    row = @min(pos.row, rows - 1);
    updateCursor();
    terminal.setCursor(pos);
}

// Colors 0-15 as in DOS; backgrounds 8-15
// would blink, so they are reduced to 0-7
pub fn setColor(fg: u8, bg: u8) void {
    attr = (fg & 0x0F) | ((bg & 0x07) << 4);
    terminal.setColor(fg, bg);
}

pub fn showCursor(visible: bool) void {
    cursor_visible = visible;
    terminal.showCursor(visible);
    if (hidden) return;
    // Bit 5 of the cursor start register hides the cursor
    setCrtc(0x0A, cursor_start | (if (visible) @as(u8, 0) else 0x20));
    setCrtc(0x0B, cursor_end);
}

// Graphics on: text goes to the shadow copy
pub fn hide() void {
    for (0..cols * rows) |i| shadow[i] = text_memory[i];
    video = &shadow;
    hidden = true;
}

// Back in text mode (set by the BIOS): restore the text and cursor
pub fn unhide() void {
    hidden = false;
    video = text_memory;
    for (0..cols * rows) |i| video[i] = shadow[i];
    showCursor(cursor_visible);
    updateCursor();
}

pub fn size() platform.Position {
    return .{ .col = cols, .row = rows };
}

pub fn pollKey() ?platform.Key {
    return kbd.poll() orelse terminal.pollKey();
}

// A task waiting for keys may sleep long: the keyboard's IRQ
// calls this (the kernel sets it) when a byte comes
pub fn setInputWake(f: *const fn () void) void {
    kbd.on_byte = f;
    serial.setInputWake(f);
}

// Mouse bytes arrive through the keyboard controller's port
pub fn pollMouse() ?platform.Mouse {
    kbd.pump();
    return mouse.take();
}

pub fn keyEvents(on: bool) bool {
    kbd.keyEvents(on);
    return true;
}

pub fn keyEvent() ?platform.KeyEvent {
    return kbd.keyEvent();
}

pub fn readKey() platform.Key {
    while (true) {
        if (kbd.poll()) |k| return k;
        const master_mask = port.inb(0x21);
        const slave_mask = port.inb(0xA1);
        port.outb(0x21, 0xF9); // only IRQ1 and the cascade (IRQ2)
        port.outb(0xA1, 0xEF); // and IRQ12, the mouse
        arch.waitForInputIrq(&kbd.irq1, &mouse.irq);
        port.outb(0x21, master_mask);
        port.outb(0xA1, slave_mask);
    }
}

// 256 glyphs of 8x16 into the VGA's font memory (int 10h
// AX=1100h), through the real-mode bounce buffer
pub fn loadFont(glyphs: *const [4096]u8) bool {
    const buf = realmode.bounce();
    if (buf.len < glyphs.len) return false;
    @memcpy(buf[0..glyphs.len], glyphs);
    const addr = realmode.info.bounce;
    var r: realmode.Regs = .{
        .eax = 0x1100,
        .ebx = 0x1000, // BH: 16 bytes per character; BL: font block 0
        .ecx = 256, // characters
        .edx = 0, // the first character
        .es = addr >> 4,
        .ebp = addr & 0xF,
    };
    realmode.call(0x10, &r);
    return !r.carry();
}

// Font files are drawn only on UEFI;
// VGA text mode takes just 8x16 (loadFont)
pub const font_files = false;
// Keys come as positions; ps2kbd.zig applies the layout
pub const firmware_keys = false;

pub fn loadFontFile(data: []const u8) bool {
    _ = data;
    return false;
}

// THE SCROLLBACK'S SIDE (kernel/scrollback.zig): THE SCREEN'S TEXT

pub fn cellsReady() bool {
    return true;
}

pub fn cellAt(c: u32, r: u32) platform.Cell {
    const v = video[r * cols + c];
    return .{ .char = charOf(@truncate(v)), .fg = @intCast(v >> 8 & 15), .bg = @intCast(v >> 12 & 7) };
}

pub fn setScrollHook(f: *const fn () void) void {
    scroll_hook = f;
}

// History takes the screen: the live text goes on in a copy
pub fn viewBegin() void {
    if (hidden) return;
    for (0..cols * rows) |i| live[i] = text_memory[i];
    video = &live;
    viewing = true;
    setCrtc(0x0A, cursor_start | 0x20); // no cursor meanwhile
}

pub fn viewCell(c: u32, r: u32, shown: platform.Cell) void {
    if (!viewing or c >= cols or r >= rows) return;
    const a: u16 = (shown.fg & 15) | @as(u16, shown.bg & 7) << 4;
    text_memory[r * cols + c] = a << 8 | (byteOf(shown.char) orelse '?');
}

pub fn viewFlush() void {} // written to the screen as drawn

pub fn viewEnd() void {
    if (!viewing) return;
    viewing = false;
    video = text_memory;
    for (0..cols * rows) |i| video[i] = live[i];
    showCursor(cursor_visible);
    updateCursor();
}

// The alternate screen (full-screen programs): the main
// one comes back after
pub fn altEnter() void {
    for (0..cols * rows) |i| alt_saved[i] = video[i];
    alt_col = col;
    alt_row = row;
}

pub fn altLeave() void {
    for (0..cols * rows) |i| video[i] = alt_saved[i];
    col = alt_col;
    row = alt_row;
    updateCursor();
}
