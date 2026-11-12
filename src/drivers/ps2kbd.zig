// PS/2 keyboard (BIOS): set 1 (the controller
// translates set 2), by poll and the IRQ1 handler
// while readKey sleeps. Keys come as the UEFI
// backend gives them; unlike UEFI a modifier
// alone is reported too (char 0, scan 0).
// The layout is keyb.zig's. Mouse bytes on the
// data port go to ps2mouse.zig.
const port = @import("../arch/x86_port.zig");
const std = @import("std");
const platform = @import("../platform.zig");
const mouse = @import("ps2mouse.zig");
const layouts = @import("../kernel/keyb_layouts.zig");
const Key = platform.Key;
const Scan = platform.Scan;
const Mod = platform.Mod;

const data_port = 0x60;
const status_port = 0x64;
const status_output_full = 0x01;
const status_input_full = 0x02;
const status_from_mouse = 0x20;

var held: u16 = 0; // modifier keys held down (Mod bits)
var locks: u16 = 0; // lock keys that are on (Mod.caps_lock ...)
var locks_down: u16 = 0; // held lock keys, to ignore their repeat
var extended = false; // last byte was the 0xE0 prefix
var skip: u8 = 0; // bytes left of a Pause key sequence

// Recorded while a program asks for them (keyEvents):
var recording = false;
var events: [64]platform.KeyEvent = undefined;
var events_start: usize = 0;
var events_len: usize = 0;
var is_down = [_]bool{false} ** 256; // by code, E0 keys from 128: for repeat

// Read by pump before poll asked for them:
var keys: [16]Key = undefined;
var keys_start: usize = 0;
var keys_len: usize = 0;

// Raw scan codes from IRQ1: one producer, one consumer; atomic
// indexes publish each byte across the interrupt.
const irq_queue_len = 32;
var irq_bytes: [irq_queue_len]u8 = undefined;
var irq_head = std.atomic.Value(u8).init(0);
var irq_tail = std.atomic.Value(u8).init(0);

// dead: the waiting accent; extra: a key
// that didn't combine with it, returned next.
var table: *const layouts.Layout = &layouts.en;
var dead: u21 = 0;
var space_down = false; // Space is held (Ctrl + Space switches once per press)
var extra: ?Key = null;

// Left Alt+Shift or Ctrl+Space (keyb.switchLayout):
pub var hotkey: ?*const fn () void = null;

pub fn useLayout(l: *const layouts.Layout) void {
    table = l;
    dead = 0;
}

fn push(k: Key) void {
    if (keys_len == keys.len) return; // full: dropped
    keys[(keys_start + keys_len) % keys.len] = k;
    keys_len += 1;
}

pub fn irq1() callconv(.c) void {
    const status = port.inb(status_port);
    if (status & status_output_full == 0) return;
    const byte = port.inb(data_port);
    if (status & status_from_mouse != 0) {
        mouse.feed(byte);
        return;
    }
    const head = irq_head.load(.monotonic);
    const tail = irq_tail.load(.acquire);
    if (head -% tail >= irq_queue_len) return;
    irq_bytes[head & (irq_queue_len - 1)] = byte;
    irq_head.store(head +% 1, .release);
    if (on_byte) |f| f();
}

// From the interrupt after a key byte, to wake a waiting task.
pub var on_byte: ?*const fn () void = null;

fn takeIrqByte() ?u8 {
    const tail = irq_tail.load(.monotonic);
    if (tail == irq_head.load(.acquire)) return null;
    const byte = irq_bytes[tail & (irq_queue_len - 1)];
    irq_tail.store(tail +% 1, .release);
    return byte;
}

// From the BIOS's lock key state (0040:0017),
// so Num Lock stays as the setup left it.
pub fn init() void {
    const bios_flags: *const volatile u8 = @ptrFromInt(0x417);
    const f = bios_flags.*;
    if (f & 0x10 != 0) locks |= Mod.scroll_lock;
    if (f & 0x20 != 0) locks |= Mod.num_lock;
    if (f & 0x40 != 0) locks |= Mod.caps_lock;
    var n: usize = 0;
    while (port.inb(status_port) & status_output_full != 0 and n < 32) : (n += 1) {
        _ = port.inb(data_port);
    }
    setLeds();
}

// The IRQ handlers read the same ports (tasks switch with
// interrupts on), so a byte must not go to both.
fn saveAndDisable() u32 {
    return asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> u32),
        :
        : "memory"
    );
}

fn restore(flags: u32) void {
    if (flags & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

pub fn poll() ?Key {
    const flags = saveAndDisable();
    defer restore(flags);
    if (keys_len > 0) {
        const k = keys[keys_start];
        keys_start = (keys_start + 1) % keys.len;
        keys_len -= 1;
        return k;
    }
    while (true) {
        const queued = takeIrqByte();
        const status = if (queued == null) port.inb(status_port) else status_output_full;
        if (status & status_output_full == 0) return null;
        const byte = queued orelse port.inb(data_port);
        if (status & status_from_mouse != 0) {
            mouse.feed(byte);
            continue;
        }
        if (decode(byte)) |k| {
            if (extra) |e| {
                extra = null;
                push(e);
            }
            return k;
        }
    }
}

// So mouse bytes get through; key presses are kept for poll.
pub fn pump() void {
    const flags = saveAndDisable();
    defer restore(flags);
    while (true) {
        // Bytes the interrupt queued are older:
        const queued = takeIrqByte();
        const status = if (queued == null) port.inb(status_port) else status_output_full;
        if (status & status_output_full == 0) return;
        const byte = queued orelse port.inb(data_port);
        if (status & status_from_mouse != 0) {
            mouse.feed(byte);
            continue;
        }
        if (decode(byte)) |k| push(k);
        if (extra) |e| {
            extra = null;
            push(e);
        }
    }
}

fn mods() u16 {
    return held | locks;
}

fn decode(byte: u8) ?Key {
    if (skip > 0) {
        skip -= 1;
        return null;
    }
    switch (byte) {
        0xE1 => { // Pause: E1 1D 45 E1 9D C5
            skip = 5;
            return null;
        },
        0xE0 => {
            extended = true;
            return null;
        },
        // Replies to commands (ACK, resend, echo) and error codes:
        0xFA, 0xFE, 0xEE, 0x00, 0xFF => {
            extended = false;
            return null;
        },
        else => {},
    }
    const ext = extended;
    extended = false;
    const release = byte & 0x80 != 0;
    const code = byte & 0x7F;

    // E0 2A / E0 36: "fake" Shift around some keys; E0 37: PrtSc:
    if (ext and (code == 0x2A or code == 0x36 or code == 0x37)) return null;
    record(ext, code, release);

    const modifier: u16 = if (ext) switch (code) {
        0x1D => Mod.right_ctrl,
        0x38 => Mod.right_alt,
        0x5B => Mod.left_logo,
        0x5C => Mod.right_logo,
        0x5D => Mod.menu,
        else => 0,
    } else switch (code) {
        0x2A => Mod.left_shift,
        0x36 => Mod.right_shift,
        0x1D => Mod.left_ctrl,
        0x38 => Mod.left_alt,
        else => 0,
    };
    if (modifier != 0) {
        if (release) {
            held &= ~modifier;
            return null;
        }
        if (held & modifier != 0) return null; // key repeat
        held |= modifier;
        // Left Alt+Shift switches the layout (not AltGr):
        const shift_key = modifier & (Mod.left_shift | Mod.right_shift) != 0;
        const alt_key = modifier == Mod.left_alt;
        if ((shift_key and held & Mod.left_alt != 0) or (alt_key and held & (Mod.left_shift | Mod.right_shift) != 0)) {
            if (hotkey) |switchLayout| switchLayout();
            return null;
        }
        return .{ .char = 0, .scan = 0, .mods = mods() };
    }

    const lock: u16 = if (ext) 0 else switch (code) {
        0x3A => Mod.caps_lock,
        0x45 => Mod.num_lock,
        0x46 => Mod.scroll_lock,
        else => 0,
    };
    if (lock != 0) {
        if (release) {
            locks_down &= ~lock;
            return null;
        }
        if (locks_down & lock != 0) return null;
        locks_down |= lock;
        locks ^= lock;
        setLeds();
        return .{ .char = 0, .scan = 0, .mods = mods() };
    }

    // Ctrl+Space switches it too:
    if (!ext and code == 0x39) {
        if (release) {
            space_down = false;
            return null;
        }
        if (!space_down and held & (Mod.left_ctrl | Mod.right_ctrl) != 0) {
            space_down = true;
            if (hotkey) |switchLayout| switchLayout();
            return null;
        }
    }
    if (release) return null;
    if (ext) return extendedKey(code);
    return mainKey(code);
}

fn record(ext: bool, code: u8, release: bool) void {
    const i = @as(usize, @intFromBool(ext)) << 7 | code;
    const repeat = !release and is_down[i];
    is_down[i] = !release;
    if (!recording or events_len == events.len) return; // full: dropped
    events[(events_start + events_len) % events.len] = .{
        .code = @as(u16, if (ext) 0xE000 else 0) | code,
        .pressed = !release,
        .repeat = repeat,
        .mods = mods(),
    };
    events_len += 1;
}

// Drops those recorded.
pub fn keyEvents(on: bool) void {
    recording = on;
    events_start = 0;
    events_len = 0;
}

pub fn keyEvent() ?platform.KeyEvent {
    if (events_len == 0) return null;
    const e = events[events_start];
    events_start = (events_start + 1) % events.len;
    events_len -= 1;
    return e;
}

fn key(char: u21, scan: u16) Key {
    return .{ .char = char, .scan = scan, .mods = mods() };
}

fn extendedKey(code: u8) ?Key {
    return switch (code) {
        0x1C => key('\r', 0), // keypad Enter
        0x35 => key('/', 0), // keypad /
        0x47 => key(0, Scan.home),
        0x48 => key(0, Scan.up),
        0x49 => key(0, Scan.page_up),
        0x4B => key(0, Scan.left),
        0x4D => key(0, Scan.right),
        0x4F => key(0, Scan.end),
        0x50 => key(0, Scan.down),
        0x51 => key(0, Scan.page_down),
        0x52 => key(0, Scan.insert),
        0x53 => key(0, Scan.delete),
        else => null,
    };
}

fn mainKey(code: u8) ?Key {
    const shift = held & (Mod.left_shift | Mod.right_shift) != 0;
    switch (code) {
        0x01 => return key(0, Scan.esc),
        0x3B...0x44 => return key(0, Scan.f1 + @as(u16, code - 0x3B)),
        0x57 => return key(0, Scan.f11),
        0x58 => return key(0, Scan.f12),
        0x4A => return key('-', 0),
        0x4E => return key('+', 0),
        // Keypad: digits with Num Lock (Shift
        // inverts it), else cursor keys:
        0x47...0x49, 0x4B...0x4D, 0x4F...0x53 => {
            const digits = (locks & Mod.num_lock != 0) != shift;
            if (digits) return key("789-456+1230."[code - 0x47], 0);
            return switch (code) {
                0x47 => key(0, Scan.home),
                0x48 => key(0, Scan.up),
                0x49 => key(0, Scan.page_up),
                0x4B => key(0, Scan.left),
                0x4D => key(0, Scan.right),
                0x4F => key(0, Scan.end),
                0x50 => key(0, Scan.down),
                0x51 => key(0, Scan.page_down),
                0x52 => key(0, Scan.insert),
                0x53 => key(0, Scan.delete),
                else => null, // keypad 5
            };
        },
        else => {},
    }
    if (code >= layouts.slots) return null;
    return typed(character(code, shift));
}

// For a main key with Shift, AltGr, Caps Lock; 0 if none.
fn character(code: u8, shift: bool) u21 {
    const plain = table.keys[0][code];
    const shifted = table.keys[1][code];
    // Caps Lock capitalizes letter keys, Shift undoes it:
    const caps = locks & Mod.caps_lock != 0 and isLetter(plain) and isLetter(shifted);
    const layer: usize = if (shift != caps) 1 else 0;
    if (held & Mod.right_alt != 0) {
        const alt = table.keys[layer + 2][code];
        if (alt != 0) return alt;
    }
    return table.keys[layer][code];
}

fn isLetter(c: u21) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= 0xC0 and c <= 0xFF and c != 0xD7 and c != 0xF7);
}

// A waiting accent combines with c or is typed before it.
fn typed(c: u21) ?Key {
    if (c == 0) return null;
    if (dead != 0) {
        const accent = dead;
        dead = 0;
        if (layouts.compose(accent, c)) |r| return key(r, 0);
        // Typed twice (or with Space): the accent alone:
        if (c == accent or c == ' ') return key(accent, 0);
        extra = key(c, 0);
        return key(accent, 0);
    }
    for (table.dead) |d| {
        if (d == c) {
            dead = c;
            return null;
        }
    }
    return key(c, 0);
}

// The keyboard answers each byte with ACK (0xFA).
fn setLeds() void {
    var leds: u8 = 0;
    if (locks & Mod.scroll_lock != 0) leds |= 1;
    if (locks & Mod.num_lock != 0) leds |= 2;
    if (locks & Mod.caps_lock != 0) leds |= 4;
    if (!send(0xED)) return;
    _ = send(leds);
}

fn send(byte: u8) bool {
    var n: u32 = 0;
    while (port.inb(status_port) & status_input_full != 0) : (n += 1) {
        if (n > 100_000) return false;
    }
    port.outb(data_port, byte);
    // Wait for the ACK, so it is not taken for a key:
    n = 0;
    while (n < 100_000) : (n += 1) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) continue;
        const b = port.inb(data_port);
        if (status & status_from_mouse != 0) {
            mouse.feed(b);
            continue;
        }
        if (b == 0xFA) return true;
        if (b == 0xFE) return false;
        // Anything else is a key typed in between; lost (rare enough):
    }
    return false;
}
