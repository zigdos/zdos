// Keyboard and mouse of the metal editions. Set-1 scan codes
// (E0 keys as 0xE0xx) from usb.zig and ps2.zig become
// platform.Key values as UEFI reports them (US characters; the
// kernel applies the layout). USB keyboards don't repeat, so
// held keys repeat here; PS/2 keyboards repeat themselves.
// USB reports arrive from the controller's interrupt (usb.zig):
// the queues are taken with interrupts off, a release stops its
// repeat at once, and a release finding the event queue full
// waits beside it, never dropped.
const std = @import("std");
const platform = @import("../../platform.zig");
const layouts = @import("../../kernel/keyb_layouts.zig");
const clock = @import("clock.zig");
const switching = @import("switching.zig");
const Key = platform.Key;
const Scan = platform.Scan;
const Mod = platform.Mod;

const repeat_delay = 500; // ms until a held key repeats
const repeat_interval = 33; // ms between repeats: 30 per second

var held: u16 = 0; // modifier keys held down (Mod bits)
var locks: u16 = Mod.num_lock; // lock keys that are on; Num Lock starts on, as on most PCs
var is_down = [_]bool{false} ** 256; // by code, E0 keys from 128

// The held key that repeats and when it does next
var repeating: ?u16 = null;
var repeat_at: u64 = 0;

// Key presses not yet read
var keys: [32]Key = undefined;
var keys_start: usize = 0;
var keys_len: usize = 0;

// Presses and releases, recorded while
// a program asks for them (keyEvents)
var recording = false;
var events: [64]platform.KeyEvent = undefined;
var events_start: usize = 0;
var events_len: usize = 0;
// Releases that found the event queue full, by code (E0
// keys from 128): in as soon as there is room, so a game
// never keeps a key down
var released = [_]bool{false} ** 256;
var released_any = false;

// The mouse's movement since pollMouse was last called, and its buttons
var mouse: platform.Mouse = .{};
var mouse_moved = false;

fn push(k: Key) void {
    if (keys_len == keys.len) return; // full: dropped
    keys[(keys_start + keys_len) % keys.len] = k;
    keys_len += 1;
}

// Shared with the USB and PS/2 interrupts (core 0) and read on
// any core running tasks: interrupts off and a spinlock.
var queue_lock = std.atomic.Value(bool).init(false);

fn take() usize {
    const s = switching.disable();
    while (queue_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    return s;
}

fn give(s: usize) void {
    queue_lock.store(false, .release);
    switching.restore(s);
}

pub fn poll() ?Key {
    const s = take();
    defer give(s);
    repeat();
    if (keys_len == 0) return null;
    const k = keys[keys_start];
    keys_start = (keys_start + 1) % keys.len;
    keys_len -= 1;
    return k;
}

fn mods() u16 {
    return held | locks;
}

// The lock keys that are on (Mod.caps_lock ...), for keyboard lights
pub fn lockState() u16 {
    return locks;
}

fn key(char: u21, scan: u16) Key {
    return .{ .char = char, .scan = scan, .mods = mods() };
}

// Pause's code in key events (its PS/2 sequence starts E1 1D)
pub const pause = 0xE11D;

// A key went down or up: code is its set-1 make code, 0xE0xx
// for E0 keys, pause for Pause
// Called once a key came (console.setInputWake): its waiter wakes
pub var on_key: ?*const fn () void = null;

pub fn feed(code: u16, pressed: bool) void {
    {
        const s = take();
        defer give(s);
        feedLocked(code, pressed);
    }
    if (on_key) |f| f();
}

// Milliseconds until a held key repeats (null: none is held)
pub fn msToRepeat() ?u32 {
    if (repeating == null) return null;
    const now = clock.millis();
    return if (repeat_at > now) @intCast(@min(repeat_at - now, 1000)) else 0;
}

fn feedLocked(code: u16, pressed: bool) void {
    if (code == pause) return event(code, pressed, false); // only an event
    const ext = code & 0xFF00 == 0xE000;
    if (code & 0xFF00 != 0 and !ext) return;
    const c: u8 = @truncate(code & 0x7F);
    const again = pressed and is_down[@as(usize, @intFromBool(ext)) << 7 | c]; // the keyboard's own repeat
    record(ext, c, pressed, again);
    if (ext and c == 0x37) return; // Print Screen: only an event

    const modifier: u16 = if (ext) switch (c) {
        0x1D => Mod.right_ctrl,
        0x38 => Mod.right_alt,
        0x5B => Mod.left_logo,
        0x5C => Mod.right_logo,
        0x5D => Mod.menu,
        else => 0,
    } else switch (c) {
        0x2A => Mod.left_shift,
        0x36 => Mod.right_shift,
        0x1D => Mod.left_ctrl,
        0x38 => Mod.left_alt,
        else => 0,
    };
    if (modifier != 0) {
        if (pressed) held |= modifier else held &= ~modifier;
        if (pressed and !again) push(key(0, 0));
        return;
    }
    const lock: u16 = if (ext) 0 else switch (c) {
        0x3A => Mod.caps_lock,
        0x45 => Mod.num_lock,
        0x46 => Mod.scroll_lock,
        else => 0,
    };
    if (lock != 0) {
        if (pressed and !again) {
            locks ^= lock;
            push(key(0, 0));
        }
        return;
    }
    if (!pressed) {
        if (repeating != null and repeating.? == code) repeating = null;
        return;
    }
    if (keyOf(ext, c)) |k| push(k);
    repeating = code;
    repeat_at = clock.millis() + repeat_delay;
}

// The held key again, at the repeat rate
fn repeat() void {
    const code = repeating orelse return;
    const now = clock.millis();
    if (now < repeat_at) return;
    repeat_at = now + repeat_interval;
    const ext = code & 0xFF00 == 0xE000;
    const c: u8 = @truncate(code & 0x7F);
    record(ext, c, true, true);
    if (keyOf(ext, c)) |k| push(k);
}

fn record(ext: bool, code: u8, pressed: bool, repeated: bool) void {
    const i = @as(usize, @intFromBool(ext)) << 7 | code;
    is_down[i] = pressed;
    event(@as(u16, if (ext) 0xE000 else 0) | code, pressed, repeated);
}

fn event(code: u16, pressed: bool, repeated: bool) void {
    if (!recording) return;
    if (events_len == events.len) { // full: a press is dropped, a release waits
        if (!pressed and code != pause) {
            released[(code & 0x7F) | @as(usize, @intFromBool(code & 0xFF00 == 0xE000)) << 7] = true;
            released_any = true;
        }
        return;
    }
    events[(events_start + events_len) % events.len] = .{
        .code = code,
        .pressed = pressed,
        .repeat = repeated,
        .mods = mods(),
    };
    events_len += 1;
}

// Starts or stops recording presses and releases; drops those recorded
pub fn keyEvents(on: bool) void {
    const s = take();
    defer give(s);
    recording = on;
    events_start = 0;
    events_len = 0;
    @memset(&released, false);
    released_any = false;
}

pub fn keyEvent() ?platform.KeyEvent {
    const s = take();
    defer give(s);
    repeat();
    if (events_len == 0) return null;
    const e = events[events_start];
    events_start = (events_start + 1) % events.len;
    events_len -= 1;
    if (released_any) moveReleases();
    return e;
}

// Waiting releases into the event queue, as far as there is room
fn moveReleases() void {
    released_any = false;
    for (&released, 0..) |*r, i| {
        if (!r.*) continue;
        if (events_len == events.len) {
            released_any = true;
            return;
        }
        r.* = false;
        const code: u16 = @as(u16, if (i >= 128) 0xE000 else 0) | @as(u16, @intCast(i & 0x7F));
        events[(events_start + events_len) % events.len] = .{ .code = code, .pressed = false, .repeat = false, .mods = mods() };
        events_len += 1;
    }
}

fn keyOf(ext: bool, code: u8) ?Key {
    if (ext) return switch (code) {
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
    const shift = held & (Mod.left_shift | Mod.right_shift) != 0;
    switch (code) {
        0x01 => return key(0, Scan.esc),
        0x3B...0x44 => return key(0, Scan.f1 + @as(u16, code - 0x3B)),
        0x57 => return key(0, Scan.f11),
        0x58 => return key(0, Scan.f12),
        0x4A => return key('-', 0),
        0x4E => return key('+', 0),
        0x59 => return key('=', 0), // keypad = (Mac and some USB keyboards)
        // Keypad: digits with Num Lock (Shift inverts it), cursor keys without
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
    // US characters (the kernel applies the layout); Caps Lock
    // turns the letters to capitals, and Shift undoes it
    const plain = layouts.en.keys[0][code];
    const caps = locks & Mod.caps_lock != 0 and plain >= 'a' and plain <= 'z';
    const c = layouts.en.keys[@intFromBool(shift != caps)][code];
    if (c == 0) return null;
    return key(c, 0);
}

// Movement from the USB and PS/2 mouse drivers:
// added up until pollMouse
pub fn feedMouse(dx: i32, dy: i32, wheel: i32, buttons: u8) void {
    {
        const s = take();
        defer give(s);
        mouse.dx +|= dx;
        mouse.dy +|= dy;
        mouse.wheel +|= wheel;
        mouse.buttons = buttons;
        mouse_moved = true;
    }
    // The waiter for keys scrolls back on the wheel:
    if (wheel != 0) if (on_key) |f| f();
}

// Movement and buttons since the last call
// (all 0 if it didn't move); `present`:
// a mouse is there (null otherwise:
// programs learn there's none)
pub fn pollMouse(present: bool) ?platform.Mouse {
    const s = take();
    defer give(s);
    if (!present and !mouse_moved) return null;
    const m = mouse;
    mouse = .{ .buttons = m.buttons };
    mouse_moved = false;
    return m;
}
