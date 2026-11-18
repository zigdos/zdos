// Text output (UTF-8) and keyboard input. Output goes to
// the standard output; screen control and ANSI sequences
// count only when that is the screen. A task with a remote
// console (term.zig) has its screen and keys there.
const std = @import("std");
const platform = @import("../platform.zig");
const stdio = @import("stdio.zig");
const ansi = @import("ansi.zig");
const keyb = @import("keyb.zig");
const tasks = @import("tasks.zig");
const Term = @import("term.zig").Term;
const scrollback = @import("scrollback.zig");
const api = @import("api.zig");
const events = @import("events.zig");

pub const Key = platform.Key;
pub const Position = platform.Position;

// The running task's remote console, if it has one
pub fn term() ?*Term {
    return if (tasks.active()) tasks.currentTask().term else null;
}

pub fn clearScreen() void {
    if (!stdio.outputIsScreen()) return;
    if (term()) |t| return t.clear();
    // CLS: the history goes too (not a full-screen program's clear)
    if (!scrollback.alt) scrollback.clear();
    platform.console.clear();
}

pub fn print(str: []const u8) void {
    if (stdio.outputIsScreen()) {
        if (term()) |t| return t.write(str);
        if (edit_row != null and tasks.active() and !tasks.foreground()) overEditedLine();
        ansi.write(str);
        pumpScroll();
    } else stdio.write(str);
}

// Another task's output replaces the line editor's line
// (edit_line), and the editor gets a redraw key to show it
// again below, as zsh or fish do.

// OUTPUT OF OTHER TASKS WHILE A LINE IS BEING TYPED
pub var edit_row: ?u32 = null;
var redraw_pending = false;

// The edited line and what is below it cleared, the cursor at its start
fn overEditedLine() void {
    const row = edit_row orelse return;
    edit_row = null;
    const sz = platform.console.size();
    if (row >= sz.row or sz.col == 0) return;
    redraw_pending = true;
    keyArrived(); // the waiter redraws
    if (@hasDecl(platform.console, "clearBelow")) return platform.console.clearBelow(row);
    var spaces: [256]u8 = undefined;
    @memset(&spaces, ' ');
    var r = row;
    while (r < sz.row) : (r += 1) {
        platform.console.setCursor(.{ .col = 0, .row = r });
        // The last cell of the last row stays: writing it would scroll
        var left: u32 = if (r + 1 == sz.row) sz.col - 1 else sz.col;
        while (left > 0) {
            const n = @min(left, spaces.len);
            platform.console.write(spaces[0..n]);
            left -= @intCast(n);
        }
    }
    platform.console.setCursor(.{ .col = 0, .row = row });
    redraw_pending = true;
    keyArrived();
}

// The foreground's line editor: its line starts at row (null: no line)
pub fn setEditRow(row: ?u32) void {
    if (term() != null or (tasks.active() and !tasks.foreground())) return;
    edit_row = row;
    if (row == null) redraw_pending = false;
}

const redraw_key: Key = .{ .scan = platform.Scan.redraw, .char = 0, .mods = 0 };

// A redraw is due for the foreground's line editor (readKey answers it)
fn takeRedraw() bool {
    if (!redraw_pending or !tasks.foreground()) return false;
    redraw_pending = false;
    return true;
}

// To the error output (tasks.world().errout):
// the screen unless redirected
pub fn printError(str: []const u8) void {
    if (tasks.world().errout == .screen) {
        const prev = stdio.toScreen();
        defer stdio.restore(prev);
        print(str);
    } else stdio.writeTo(tasks.world().errout, str);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

pub fn getCursor() Position {
    if (!stdio.outputIsScreen()) return .{ .col = 0, .row = 0 };
    if (term()) |t| return t.getCursor();
    return platform.console.getCursor();
}

pub fn setCursor(pos: Position) void {
    if (!stdio.outputIsScreen()) return;
    if (term()) |t| return t.setCursor(pos);
    platform.console.setCursor(pos);
}

pub fn size() Position {
    if (term()) |t| return t.size();
    return platform.console.size();
}

pub const default_fg = ansi.default_fg; // light gray
pub const default_bg = ansi.default_bg; // black

pub fn setColor(fg: u8, bg: u8) void {
    if (!stdio.outputIsScreen()) return;
    if (term()) |t| return t.setColor(fg, bg);
    ansi.setColor(fg, bg);
}

// Forgets an escape sequence a program left unfinished
pub fn resetEscape() void {
    ansi.reset();
}

pub fn showCursor(visible: bool) void {
    if (!stdio.outputIsScreen()) return;
    if (term()) |t| return t.showCursor(visible);
    platform.console.showCursor(visible);
}

// KEYBOARD AND CTRL+C
//
// Keys go through a queue so that polling for Ctrl+C
// (breakRequested) doesn't lose keys typed meanwhile.
// While `catching`, Ctrl+C is not a key: it prints "^C" and
// sets break_pending, which api.zig
// checks at the program's next call.

// Set per program by api.zig: on unless it asked for Ctrl+C as a key

var queue: [32]Key = undefined;
var queue_start: usize = 0;
var queue_len: usize = 0;

var last_mods: u16 = 0; // modifiers of the previous firmware key (UEFI)

// A platform key as programs get it. With firmware keys (UEFI)
// the layout is applied here and Left Alt+Shift / Ctrl+Space
// switch it (the BIOS driver does both itself). Null when the
// key was consumed: a layout switch or a pending dead key; the
// second character a dead key may produce is queued.

fn fromKeyboard(raw: Key) ?Key {
    if (term() != null) return raw; // typed remotely: characters already
    var k = raw;
    if (platform.console.firmware_keys) {
        const M = platform.Mod;
        // On the transition to both held, whatever event shows it:
        // firmware may not report modifier keys alone
        const alt_shift = raw.mods & M.left_alt != 0 and raw.mods & (M.left_shift | M.right_shift) != 0;
        const was_alt_shift = last_mods & M.left_alt != 0 and last_mods & (M.left_shift | M.right_shift) != 0;
        last_mods = raw.mods;
        if (alt_shift and !was_alt_shift) keyb.switchLayout();
        // Ctrl+Space too: some firmware never reports Alt+Shift
        const ctrl = raw.mods & (M.left_ctrl | M.right_ctrl) != 0;
        if (raw.char == ' ' and ctrl) {
            keyb.switchLayout();
            return null;
        }
        if (raw.char == 0 and raw.scan == 0) {
            if (alt_shift) return null;
        } else {
            const c = keyb.fromFirmware(raw.char) orelse return null;
            if (keyb.takeExtra()) |e| {
                var second = raw;
                second.char = e;
                push(second);
            }
            k.char = c;
        }
    }
    return withCtrl(k);
}

// Ctrl+letter becomes control character 1-26 (DOS, terminals);
// mods still says Ctrl was held.
// Not with Alt: Ctrl+Alt is AltGr on many keyboards.
fn withCtrl(k: Key) Key {
    const M = platform.Mod;
    if (k.mods & (M.left_ctrl | M.right_ctrl) == 0 or k.mods & (M.left_alt | M.right_alt) != 0) return k;
    var c = k;
    if ((k.char >= 'a' and k.char <= 'z') or (k.char >= 'A' and k.char <= 'Z')) c.char = k.char & 0x1F;
    return c;
}

// Character 3, or C with Ctrl should a key come in unconverted
pub fn isCtrlC(k: Key) bool {
    const ctrl = k.mods & (platform.Mod.left_ctrl | platform.Mod.right_ctrl) != 0;
    return k.char == 3 or (ctrl and (k.char == 'c' or k.char == 'C'));
}

// True if k is Ctrl+C taken as a break
fn take(k: Key) bool {
    if (!tasks.world().catching or !isCtrlC(k)) return false;
    if (!tasks.world().break_pending) {
        tasks.world().break_pending = true;
        const prev = stdio.toScreen();
        defer stdio.restore(prev);
        print("^C\n");
    }
    return true;
}

fn push(k: Key) void {
    if (term()) |t| return t.push(k);
    if (queue_len == queue.len) return; // full: dropped
    queue[(queue_start + queue_len) % queue.len] = k;
    queue_len += 1;
}

fn pop() ?Key {
    if (term()) |t| return t.pop();
    if (queue_len == 0) return null;
    const k = queue[queue_start];
    queue_start = (queue_start + 1) % queue.len;
    queue_len -= 1;
    return k;
}

// Shift+PgUp / PgDn / Home / End and the wheel move through the
// lines that left the screen; any other key returns. Only for
// the screen's foreground, never on the alternate screen
// (full-screen programs), during graphics or key events; the
// wheel only while no program reads the mouse.

// THE SCROLLBACK (scrollback.zig)
fn canScroll() bool {
    if (term() != null) return false;
    if (tasks.active() and !tasks.foreground()) return false;
    return scrollback.usable();
}

// Alt+Tab, Win+Tab: the next tab to the front (api.zig); used up
fn switchKey(k: Key) bool {
    const M = platform.Mod;
    if (k.char != '\t' or term() != null) return false;
    if (k.mods & (M.left_alt | M.right_alt | M.left_logo | M.right_logo) == 0) return false;
    api.switchTab();
    return true;
}

// True if k moved the view or switched tabs (and is used up)
fn scrollKey(k: Key) bool {
    if (switchKey(k)) return true;
    const M = platform.Mod;
    const S = platform.Scan;
    if (k.mods & (M.left_shift | M.right_shift) != 0 and canScroll()) {
        switch (k.scan) {
            S.page_up => scrollback.scrollBy(scrollback.pageSize()),
            S.page_down => scrollback.scrollBy(-scrollback.pageSize()),
            S.home => scrollback.toTop(),
            S.end => scrollback.leave(),
            else => return leaveFor(k),
        }
        return true;
    }
    return leaveFor(k);
}

// A key, not a modifier pressed alone (no character,
// no scan code): back to the live screen
fn leaveFor(k: Key) bool {
    if (k.char != 0 or k.scan != 0) scrollback.leave();
    return false;
}

// The wheel's turns: 3 lines each
// (positive is toward the user: forward)
fn scrollWheel() void {
    if (!canScroll() or api.mouseTaken()) return;
    const m = platform.console.pollMouse() orelse return;
    if (m.wheel != 0) scrollback.scrollBy(-@as(i64, m.wheel) * 3);
}

// While output goes on (a program that doesn't read keys):
// the wheel and the scroll keys now and then;
// other keys wait in the queue
var last_pump: u64 = 0;
var pumping = false;

fn pumpScroll() void {
    if (pumping or !scrollback.available or !canScroll()) return;
    const now = platform.clock.millis();
    if (now -% last_pump < 30) return;
    last_pump = now;
    pumping = true;
    defer pumping = false;
    _ = breakRequested();
}

// The next key from the keyboard. With tasks the wait lets the
// others run, and only the first task (the command
// interpreter's) gets keys: the others wait.
fn nextRaw() Key {
    if (!tasks.active()) return platform.console.readKey();
    if (term()) |t| return t.waitKey();
    while (true) {
        if (tasks.foreground()) {
            if (takeRedraw()) return redraw_key;
            scrollWheel();
            if (platform.console.pollKey()) |k| return k;
        }
        // Waiting for a key: signals still come through
        // (KILL, a handler). Where a key wakes it (BIOS's
        // interrupt, UEFI's key event) it may sleep long.
        tasks.handleSignals();
        if (input_wakes) {
            // UEFI: the idle task watches the key event only while asked
            const ask = @hasDecl(platform.console, "wantInput") and tasks.foreground();
            if (ask) platform.console.wantInput(true);
            const ms: ?u32 = if (@hasDecl(platform.console, "inputPollMs")) platform.console.inputPollMs() else 50;
            _ = tasks.waitObject(&key_waiters, ms);
            if (ask) platform.console.wantInput(false);
        } else tasks.nap(1);
    }
}

const input_wakes = @hasDecl(platform.console, "setInputWake");
var key_waiters: u8 = 0;

// From the keyboard's interrupt (BIOS, metal's USB) or the idle
// task (UEFI); outside the scheduler
fn keyArrived() void {
    tasks.wake(&key_waiters);
    events.notify(&key_waiters); // waiting polls
}

// For poll (api.zig): what notifies when keys come for this
// task (its remote console, else the keyboard)
pub fn inputObject() *const anyopaque {
    if (term()) |t| return t;
    return &key_waiters;
}

// How long poll may wait before looking at the keys again,
// null until they notify: for an escape sequence's end, keys
// that wake nobody, UEFI's and polled keyboards' keys. Behind
// the front none come (coming to the front notifies)
pub fn inputLookMs() ?u32 {
    if (term()) |t| return if (t.esc_since != 0) 20 else null;
    if (tasks.active() and !tasks.foreground()) return null;
    if (!input_wakes) return 1;
    if (@hasDecl(platform.console, "inputPollMs")) return platform.console.inputPollMs();
    if (@hasDecl(platform.console, "wantInput")) return 50;
    return null;
}

// UEFI's idle task watches the key event only while asked:
// true if asked now (inputUnwanted then)
pub fn inputWanted() bool {
    if (!@hasDecl(platform.console, "wantInput") or term() != null or !tasks.foreground()) return false;
    platform.console.wantInput(true);
    return true;
}

pub fn inputUnwanted(asked: bool) void {
    if (@hasDecl(platform.console, "wantInput") and asked) platform.console.wantInput(false);
}

// At startup, once tasks run
pub fn initInput() void {
    if (input_wakes) platform.console.setInputWake(&keyArrived);
    tasks.front_hook = &keyArrived;
}

// Whether a key is waiting (for poll): only for the first task
pub fn keyWaiting() bool {
    if (term()) |t| return termKeys(t);
    if (tasks.active() and !tasks.foreground()) return false;
    scrollWheel();
    while (platform.console.pollKey()) |raw| {
        const k = fromKeyboard(raw) orelse continue;
        if (scrollKey(k)) continue;
        if (!take(k)) push(k);
    }
    return queue_len > 0;
}

// Moves waiting keys to the queue; true
// if Ctrl+C was pressed while catching
pub fn breakRequested() bool {
    if (term()) |t| {
        _ = termKeys(t);
        return tasks.world().break_pending;
    }
    if (!tasks.foreground()) return tasks.world().break_pending;
    scrollWheel();
    while (platform.console.pollKey()) |raw| {
        const k = fromKeyboard(raw) orelse continue;
        if (scrollKey(k)) continue;
        if (!take(k)) push(k);
    }
    return tasks.world().break_pending;
}

// A remote console's typed keys to its
// queue (Ctrl+C taken); whether any wait
fn termKeys(t: *Term) bool {
    while (t.parseKey()) |k| {
        if (!take(k)) t.push(k);
    }
    return t.keys_len > 0;
}

pub fn clearBreak() void {
    tasks.world().break_pending = false;
}

// Waits for any key. Ctrl+C is returned too (so a prompt gets
// an answer) and, while catching, also sets break_pending.
pub fn readKey() Key {
    if (pop()) |k| return k;
    while (true) {
        const raw = nextRaw();
        if (raw.scan == platform.Scan.redraw) return raw;
        const k = fromKeyboard(raw) orelse continue;
        if (scrollKey(k)) continue;
        _ = take(k);
        return k;
    }
}

// The next key, or null on Ctrl+C
pub fn readKeyUnlessBreak() ?Key {
    if (tasks.world().break_pending) return null;
    if (pop()) |k| return k;
    while (true) {
        const raw = nextRaw();
        if (raw.scan == platform.Scan.redraw) return raw;
        const k = fromKeyboard(raw) orelse continue;
        if (scrollKey(k)) continue;
        if (take(k)) return null;
        return k;
    }
}

pub fn pollKey() ?Key {
    _ = breakRequested();
    return pop();
}

// Reading events drops the queued keys so
// they don't turn up later in the shell.

// KEY PRESSES AND RELEASES (GAMES)
pub fn keyEvents(on: bool) bool {
    if (term() != null) return false;
    return platform.console.keyEvents(on);
}

// Movement since the last call and buttons; null without a mouse
pub fn pollMouse() ?platform.Mouse {
    if (term() != null) return null;
    return platform.console.pollMouse();
}

pub fn keyEvent() ?platform.KeyEvent {
    _ = breakRequested();
    if (term() != null) return null;
    if (!text_wanted) queue_len = 0;
    const e = platform.console.keyEvent() orelse return null;
    // Tab (set-1 code 0x0F) with Alt or Win switches tabs (as a
    // key, in breakRequested above): not the program's
    const M = platform.Mod;
    if (e.code == 0x0F and e.mods & (M.left_alt | M.right_alt | M.left_logo | M.right_logo) != 0) return null;
    return e;
}

// Once a program asks for them, the characters the keys make
// are kept in the queue for it
// instead of being dropped by keyEvent

// TYPED CHARACTERS BESIDE KEY EVENTS (SDL'S TEXT INPUT)
var text_wanted = false;

pub fn textInput(on: bool) void {
    text_wanted = on;
}

// The characters typed since the last call, UTF-8, as many as fit
pub fn takeText(out: []u8) usize {
    text_wanted = true;
    _ = breakRequested(); // the keyboard's keys into the queue (layout applied)
    var n: usize = 0;
    while (queue_len > 0) {
        const k = queue[queue_start];
        if (k.char >= 0x20 and k.char != 0x7F) {
            var b: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(k.char, &b) catch 0;
            if (n + len > out.len) break;
            @memcpy(out[n..][0..len], b[0..len]);
            n += len;
        }
        queue_start = (queue_start + 1) % queue.len;
        queue_len -= 1;
    }
    return n;
}
