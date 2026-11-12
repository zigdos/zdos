// Console of the metal editions: the framebuffer once started,
// and always the serial port (terminal.zig); keys from
// keyboard.zig and the terminal.
const std = @import("std");
const platform = @import("../../platform.zig");
const framebuffer = @import("framebuffer.zig");
const terminal = @import("terminal.zig");
const serial = @import("serial.zig");
const keyboard = @import("keyboard.zig");
const usb = @import("usb.zig");
const ps2 = @import("ps2.zig");
const builtin = @import("builtin");
const cpu = @import("cpu.zig");

// .zfn font files are drawn (FONT=); the codepage is unused
pub const font_files = true;
// Keys arrive as on a US keyboard, as from UEFI:
// the kernel applies the layout
pub const firmware_keys = true;

// Before leaving the firmware: the serial port only
pub fn init() void {
    terminal.init();
}

pub fn clear() void {
    if (framebuffer.active()) framebuffer.clear();
    terminal.clear();
}

pub fn write(str: []const u8) void {
    if (framebuffer.active()) framebuffer.write(str);
    terminal.write(str);
}

// Row `from` and below cleared, the cursor at its start
// (optional for backends: kernel/console.zig
// writes spaces without it)
pub fn clearBelow(from: u32) void {
    if (framebuffer.active()) framebuffer.clearBelow(from);
    terminal.clearBelow();
}

pub fn getCursor() platform.Position {
    return if (framebuffer.active()) framebuffer.getCursor() else terminal.getCursor();
}

pub fn setCursor(pos: platform.Position) void {
    if (framebuffer.active()) framebuffer.setCursor(pos);
    terminal.setCursor(pos);
}

pub fn setColor(fg: u8, bg: u8) void {
    if (framebuffer.active()) framebuffer.setColor(fg, bg);
    terminal.setColor(fg, bg);
}

pub fn showCursor(visible: bool) void {
    if (framebuffer.active()) framebuffer.showCursor(visible);
    terminal.showCursor(visible);
}

pub fn size() platform.Position {
    return if (framebuffer.active()) framebuffer.size() else terminal.size();
}

// KEYS AND MOUSE

// The keyboards' new presses and releases into keyboard.zig
fn pollDevices() void {
    usb.poll();
    switch (builtin.cpu.arch) {
        .x86_64 => ps2.poll(),
        else => {},
    }
}

pub fn pollKey() ?platform.Key {
    pollDevices();
    return keyboard.poll() orelse terminal.pollKey();
}

// Once tasks run, a waiter for keys sleeps (kernel console.zig):
// USB keys wake it through keyboard.feed from their interrupt
pub fn setInputWake(f: *const fn () void) void {
    keyboard.on_key = f;
    serial.setInputWake(f);
}

// How long it may sleep (null: until woken). PS/2 or a serial
// port without its interrupt: it looks every millisecond (a
// paste at 115200 baud fills a 16-byte FIFO in about 1.4 ms);
// a held key repeats by time
pub fn inputPollMs() ?u32 {
    const every: ?u32 = if (serial.polled() or (builtin.cpu.arch == .x86_64 and ps2.polled())) 1 else null;
    const r = keyboard.msToRepeat() orelse return every;
    return @max(@min(r, every orelse r), 1);
}

// Between looks the CPU sleeps until its
// next wake-up (cpu.zig): at most a
// millisecond's delay, no busy core
pub fn readKey() platform.Key {
    while (true) {
        if (pollKey()) |k| return k;
        cpu.wait();
    }
}

pub fn keyEvents(on: bool) bool {
    keyboard.keyEvents(on);
    return true;
}

pub fn keyEvent() ?platform.KeyEvent {
    pollDevices();
    return keyboard.keyEvent();
}

// A mouse's movement since the last call; null if there is no mouse
pub fn pollMouse() ?platform.Mouse {
    pollDevices();
    const ps2_mouse = builtin.cpu.arch == .x86_64 and ps2.hasMouse();
    return keyboard.pollMouse(ps2_mouse or usb.hasMouse());
}

pub fn loadFont(glyphs: *const [4096]u8) bool {
    _ = glyphs;
    return false;
}

// Text is drawn by code point
pub fn setCodepage(points: *const [256]u32) void {
    _ = points;
}

pub fn loadFontFile(data: []const u8) bool {
    return framebuffer.loadFontFile(data);
}

// THE SCROLLBACK'S SIDE (kernel/scrollback.zig): THE SCREEN'S TEXT

pub fn cellsReady() bool {
    return framebuffer.active() and framebuffer.cellsReady();
}

pub const cellAt = framebuffer.cellAt;
pub const setScrollHook = framebuffer.setScrollHook;
pub const viewBegin = framebuffer.viewBegin;
pub const viewCell = framebuffer.viewCell;
pub const viewFlush = framebuffer.viewFlush;
pub const viewEnd = framebuffer.viewEnd;
pub const altEnter = framebuffer.altEnter;
pub const altLeave = framebuffer.altLeave;
