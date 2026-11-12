// Console through the firmware's ConOut / ConIn. Once a font
// file is loaded (loadFontFile) ZDOS draws the text itself on
// the GOP screen; keys still come from the firmware.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const text = @import("text.zig");
const memory = @import("memory.zig");

var con_out: *uefi.protocol.SimpleTextOutput = undefined;
var con_in: *uefi.protocol.SimpleTextInput = undefined;
// SimpleTextInputEx, which reports modifier keys;
// null: firmware without it
var con_in_ex: ?*const uefi.protocol.SimpleTextInputEx = null;
const KeyEx = uefi.protocol.SimpleTextInputEx.Key;
var boot_services: *uefi.tables.BootServices = undefined;
// Text isn't drawn during graphics (graphics.zig): it would
// land on the picture
var paused = false;
var cursor_visible = true;

pub const font_files = true;
// Keys arrive translated for US, not as positions:
// keyb.fromFirmware applies the layout
pub const firmware_keys = true;

// TEXT DRAWN BY ZDOS
//
// Text is drawn into `shadow`, a copy of the screen
// without the cursor, and the changed rows go to the
// screen with one Blt per write. The cursor (an underline)
// is drawn on the screen only and erased from the copy
// before anything changes.

const Gop = uefi.protocol.GraphicsOutput;
const Pixel = Gop.BltPixel;

const header_size = 16; // "ZFNT" file header, see tools/make-fonts.py

// Colors 0-15 as on the VGA text screen
const vga_rgb = [16][3]u8{
    .{ 0, 0, 0 },     .{ 0, 0, 170 },    .{ 0, 170, 0 },    .{ 0, 170, 170 },
    .{ 170, 0, 0 },   .{ 170, 0, 170 },  .{ 170, 85, 0 },   .{ 170, 170, 170 },
    .{ 85, 85, 85 },  .{ 85, 85, 255 },  .{ 85, 255, 85 },  .{ 85, 255, 255 },
    .{ 255, 85, 85 }, .{ 255, 85, 255 }, .{ 255, 255, 85 }, .{ 255, 255, 255 },
};

fn pixelOf(color: u8) Pixel {
    const rgb = vga_rgb[color & 0x0F];
    return .{ .red = rgb[0], .green = rgb[1], .blue = rgb[2], .reserved = 0 };
}

// The loaded font file (kept for the rest of the run)
const Font = struct {
    data: []const u8,
    cell_w: u32,
    cell_h: u32,
    count: usize, // glyphs, in code point order
    row_bytes: usize, // (cell_w + 7) / 8
    entry: usize, // bytes per glyph: code point + cell_h rows
};

var font: ?Font = null; // null: the firmware's text
var shadow: []Pixel = &.{}; // the screen's pixels, text only
var shadow_mem: ?[*]align(8) u8 = null; // the memory of shadow, to free it
var gop_ptr: ?*Gop = null;
var screen_w: u32 = 0;
var screen_h: u32 = 0;
var grid_cols: u32 = 0;
var grid_rows: u32 = 0;
var col: u32 = 0; // the cursor
var row: u32 = 0;
// light gray on black
var fg_px: Pixel = .{ .red = 170, .green = 170, .blue = 170, .reserved = 0 };
var bg_px: Pixel = .{ .red = 0, .green = 0, .blue = 0, .reserved = 0 };
var drawn: ?platform.Position = null; // where the cursor is drawn on the screen now
var dirty_lo: u32 = 0; // pixel rows [dirty_lo, dirty_hi) changed in the copy
var dirty_hi: u32 = 0;

// The text as cells, for
// the scrollback (kernel/scrollback.zig): character (21 bits),
// foreground (4), background (4). While it shows history the
// text goes only into the cells.
var cells: []u32 = &.{};
var cells_mem: ?[*]align(8) u8 = null;
var cur_fg: u8 = 7;
var cur_bg: u8 = 0;
var viewing = false;
var scroll_hook: ?*const fn () void = null;
var alt_cells: []u32 = &.{}; // the main screen while the alternate one is on
var alt_mem: ?[*]align(8) u8 = null;
var alt_col: u32 = 0;
var alt_row: u32 = 0;

fn pack(ch: u21, fg: u8, bg: u8) u32 {
    return @as(u32, ch) | @as(u32, fg & 15) << 21 | @as(u32, bg & 15) << 25;
}

fn blank() u32 {
    return pack(' ', cur_fg, cur_bg);
}

// The console's GOP, or any; also used by graphics.zig
pub fn gop() ?*Gop {
    if (gop_ptr) |g| return g;
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.console_out_handle) |h| {
        if (boot_services.handleProtocol(h, &Gop.guid, &ptr) != .success) ptr = null;
    }
    if (ptr == null and boot_services.locateProtocol(&Gop.guid, null, &ptr) != .success) return null;
    gop_ptr = @ptrCast(@alignCast(ptr orelse return null));
    return gop_ptr;
}

fn drawing() bool {
    return font != null;
}

fn markDirty(lo: u32, hi: u32) void {
    dirty_lo = @min(dirty_lo, lo);
    dirty_hi = @max(dirty_hi, hi);
}

fn flushRows(lo: u32, hi: u32) void {
    if (hi <= lo or viewing) return;
    _ = gop_ptr.?.blt(shadow.ptr, .blt_buffer_to_video, 0, lo, 0, lo, screen_w, hi - lo, @as(usize, screen_w) * @sizeOf(Pixel));
}

// The cursor's underline: the bottom rows of its cell, in pixels
const Rect = struct { x: usize, y: usize, w: usize, h: usize };

fn cursorRect(at: platform.Position) Rect {
    const f = font.?;
    const h: usize = @max(1, f.cell_h / 8);
    const cell_h: usize = f.cell_h;
    const cell_w: usize = f.cell_w;
    return .{
        .x = @as(usize, at.col) * cell_w,
        .y = (@as(usize, at.row) + 1) * cell_h - h,
        .w = cell_w,
        .h = h,
    };
}

fn eraseCursor() void {
    if (viewing) return;
    const at = drawn orelse return;
    drawn = null;
    const r = cursorRect(at);
    _ = gop_ptr.?.blt(shadow.ptr, .blt_buffer_to_video, r.x, r.y, r.x, r.y, r.w, r.h, @as(usize, screen_w) * @sizeOf(Pixel));
}

fn showCursorNow() void {
    if (!cursor_visible or paused or viewing or drawn != null) return;
    const at: platform.Position = .{ .col = col, .row = row };
    const r = cursorRect(at);
    var fill = fg_px;
    _ = gop_ptr.?.blt(@ptrCast(&fill), .blt_video_fill, 0, 0, r.x, r.y, r.w, r.h, 0);
    drawn = at;
}

// A character in the current colors: into the cells, and drawn
fn drawCell(c: u32, r: u32, ch: u21) void {
    cells[@as(usize, r) * grid_cols + c] = pack(ch, cur_fg, cur_bg);
    if (!viewing) paintCell(c, r, if (ch == ' ') null else glyphOf(ch), fg_px, bg_px);
}

fn paintPacked(c: u32, r: u32, v: u32) void {
    const ch: u21 = @intCast(v & 0x1FFFFF);
    paintCell(c, r, if (ch == ' ') null else glyphOf(ch), pixelOf(@intCast(v >> 21 & 15)), pixelOf(@intCast(v >> 25 & 15)));
}

fn paintAll() void {
    for (0..grid_rows) |r| {
        for (0..grid_cols) |c| paintPacked(@intCast(c), @intCast(r), cells[r * grid_cols + c]);
    }
}

// glyph null: blank
fn paintCell(c: u32, r: u32, glyph: ?[]const u8, fg: Pixel, bg: Pixel) void {
    const f = font.?;
    const cell_w: usize = f.cell_w;
    const cell_h: usize = f.cell_h;
    const stride: usize = screen_w;
    const x0 = @as(usize, c) * cell_w;
    const y0 = @as(usize, r) * cell_h;
    for (0..cell_h) |y| {
        const line = shadow[(y0 + y) * stride + x0 ..][0..cell_w];
        const bits: []const u8 = if (glyph) |g| g[y * f.row_bytes ..][0..f.row_bytes] else &.{};
        for (line, 0..) |*p, x| {
            const ink = bits.len > 0 and bits[x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
            p.* = if (ink) fg else bg;
        }
    }
    markDirty(@intCast(y0), @intCast(y0 + cell_h));
}

fn scroll() void {
    if (scroll_hook) |h| h(); // the top row into the scrollback, before it goes
    const n = @as(usize, grid_rows - 1) * grid_cols;
    std.mem.copyForwards(u32, cells[0..n], cells[grid_cols..][0..n]);
    @memset(cells[n..][0..grid_cols], blank());
    if (viewing) return;
    const f = font.?;
    const stride: usize = screen_w;
    const cell_h: usize = f.cell_h;
    const text_h = @as(usize, grid_rows) * cell_h;
    const keep = (text_h - cell_h) * stride; // pixels of the text rows below the first
    std.mem.copyForwards(Pixel, shadow[0..keep], shadow[cell_h * stride ..][0..keep]);
    @memset(shadow[keep .. @as(usize, screen_h) * stride], bg_px);
    markDirty(0, @intCast(text_h));
}

fn newline() void {
    col = 0;
    if (row + 1 < grid_rows) {
        row += 1;
    } else {
        scroll();
    }
}

// The glyph of a character: its own, else U+FFFD's, else blank
fn glyphOf(c: u21) ?[]const u8 {
    return findGlyph(c) orelse findGlyph(0xFFFD);
}

// Binary search: glyphs are in code point order.
// Returns the glyph's rows
fn findGlyph(code: u32) ?[]const u8 {
    const f = font.?;
    var lo: usize = 0;
    var hi: usize = f.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = header_size + mid * f.entry;
        const c = std.mem.readInt(u32, f.data[at..][0..4], .little);
        if (c == code) return f.data[at + 4 ..][0 .. f.entry - 4];
        if (c < code) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn putChar(c: u21) void {
    drawCell(col, row, c);
    col += 1;
    if (col >= grid_cols) newline();
}

// Same control characters as the BIOS text screen
fn writeFont(str: []const u8) void {
    eraseCursor();
    dirty_lo = std.math.maxInt(u32);
    dirty_hi = 0;
    var i: usize = 0;
    while (i < str.len) {
        const d = text.decodeUtf8(str[i..]);
        i += d.len;
        switch (d.char) {
            '\n' => newline(),
            '\r' => col = 0,
            '\t' => {
                putChar(' ');
                while (col % 8 != 0) putChar(' ');
            },
            0x08 => { // erase the character before the cursor
                if (col > 0) {
                    col -= 1;
                } else if (row > 0) {
                    row -= 1;
                    col = grid_cols - 1;
                }
                drawCell(col, row, ' ');
            },
            else => if (d.char >= 0x20 and d.char != 0x7F) putChar(d.char),
        }
    }
    if (dirty_lo < dirty_hi) flushRows(dirty_lo, dirty_hi);
    showCursorNow();
}

fn clearFont() void {
    @memset(cells, blank());
    if (viewing) {
        col = 0;
        row = 0;
        return;
    }
    @memset(shadow, bg_px);
    flushRows(0, screen_h);
    drawn = null; // the screen has no cursor now
    col = 0;
    row = 0;
    showCursorNow();
}

pub fn init() void {
    const st = uefi.system_table;
    con_out = st.con_out.?;
    con_in = st.con_in.?;
    boot_services = st.boot_services.?;
    _ = con_in.reset(false);
    _ = con_out.enableCursor(true);

    if (st.console_in_handle) |h| {
        var ptr: ?*anyopaque = null;
        if (boot_services.handleProtocol(h, &uefi.protocol.SimpleTextInputEx.guid, &ptr) == .success) {
            const ex: *const uefi.protocol.SimpleTextInputEx = @ptrCast(@alignCast(ptr.?));
            con_in_ex = ex;
            // Also report modifier keys pressed on their
            // own ("partial" keystrokes). This sets the
            // lock keys too: all off.
            const toggle: KeyEx.State.Toggle = .{
                .scroll_lock_active = false,
                .num_lock_active = false,
                .caps_lock_active = false,
                .key_state_exposed = true,
                .toggle_state_valid = true,
            };
            _ = ex.setState(@ptrCast(&toggle));
        }
    }
    findPointer();
}

pub fn clear() void {
    if (paused) return;
    if (drawing()) return clearFont();
    _ = con_out.clearScreen();
}

// The firmware console needs "\r\n" for '\n'
pub fn write(str: []const u8) void {
    if (paused) return;
    if (drawing()) return writeFont(str);
    var buf: [128:0]u16 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const d = text.decodeUtf8(str[i..]);
        i += d.len;
        if (n + 2 >= buf.len) flush(&buf, &n);
        if (d.char == '\n') {
            buf[n] = '\r';
            n += 1;
        }
        buf[n] = text.toUcs2(d.char);
        n += 1;
    }
    flush(&buf, &n);
}

fn flush(buf: *[128:0]u16, n: *usize) void {
    if (n.* == 0) return;
    buf[n.*] = 0;
    _ = con_out.outputString(buf);
    n.* = 0;
}

pub fn getCursor() platform.Position {
    if (drawing()) return .{ .col = col, .row = row };
    return .{ .col = @intCast(@max(0, con_out.mode.cursor_column)), .row = @intCast(@max(0, con_out.mode.cursor_row)) };
}

pub fn setCursor(pos: platform.Position) void {
    if (drawing()) {
        eraseCursor();
        col = @min(pos.col, grid_cols - 1);
        row = @min(pos.row, grid_rows - 1);
        showCursorNow();
        return;
    }
    _ = con_out.setCursorPosition(pos.col, pos.row);
}

// UEFI's color numbers are the VGA's. The firmware's text
// limits backgrounds to 0-7; ZDOS's own text keeps all 16.
pub fn setColor(fg: u8, bg: u8) void {
    if (drawing()) {
        cur_fg = fg & 15;
        cur_bg = bg & 15;
        fg_px = pixelOf(fg);
        bg_px = pixelOf(bg);
        return;
    }
    _ = con_out.setAttribute((fg & 0x0F) | (@as(usize, bg & 0x07) << 4));
}

pub fn showCursor(visible: bool) void {
    cursor_visible = visible;
    if (drawing()) {
        if (visible) showCursorNow() else eraseCursor();
        return;
    }
    if (!paused) _ = con_out.enableCursor(visible);
}

pub fn pause(on: bool) void {
    paused = on;
    if (drawing()) {
        if (on) eraseCursor() else showCursorNow();
        return;
    }
    _ = con_out.enableCursor(!on and cursor_visible);
}

pub fn size() platform.Position {
    if (drawing()) return .{ .col = grid_cols, .row = grid_rows };
    var cols: usize = 80;
    var rows: usize = 25;
    if (con_out.queryMode(con_out.mode.mode, &cols, &rows) != .success) return .{ .col = 80, .row = 25 };
    return .{ .col = @intCast(cols), .row = @intCast(rows) };
}

pub fn pollKey() ?platform.Key {
    platform.idle.run();
    if (con_in_ex) |ex| {
        var key: KeyEx = undefined;
        if (ex.readKeyStrokeEx(&key) != .success) return null;
        // UEFI scan codes are the values ZDOS uses
        return .{ .char = key.input.unicode_char, .scan = key.input.scan_code, .mods = mods(key.state) };
    }
    var key: uefi.protocol.SimpleTextInput.Key.Input = undefined;
    if (con_in.readKeyStroke(&key) != .success) return null;
    return .{ .char = key.unicode_char, .scan = key.scan_code };
}

// MOUSE
//
// Simple Pointer protocol (needs a firmware mouse driver:
// USB usually). Declared here because std's
// SimplePointer isn't an extern struct.

const SimplePointer = extern struct {
    reset: *const fn (*const SimplePointer, bool) callconv(uefi.cc) uefi.Status,
    get_state: *const fn (*const SimplePointer, *State) callconv(uefi.cc) uefi.Status,
    wait_for_input: uefi.Event,
    mode: *const Mode,

    const guid align(8) = uefi.protocol.SimplePointer.guid;

    const State = extern struct {
        relative_movement_x: i32,
        relative_movement_y: i32,
        relative_movement_z: i32,
        left_button: bool,
        right_button: bool,
    };

    const Mode = extern struct {
        resolution_x: u64, // counts per millimeter; 0 if unknown
        resolution_y: u64,
        resolution_z: u64,
        left_button: bool, // the mouse has it
        right_button: bool,
    };
};

var pointer: ?*const SimplePointer = null;
var mouse_buttons: u8 = 0;
var rest_x: i64 = 0; // movement left over from scaling, in the mouse's counts
var rest_y: i64 = 0;

// The pointer on the console's input handle (the firmware
// merges all mice there), else any
fn findPointer() void {
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.console_in_handle) |h| {
        if (boot_services.handleProtocol(h, &SimplePointer.guid, &ptr) != .success) ptr = null;
    }
    if (ptr == null and boot_services.locateProtocol(&SimplePointer.guid, null, &ptr) != .success) return;
    const p: *const SimplePointer = @ptrCast(@alignCast(ptr orelse return));
    _ = p.reset(p, false);
    pointer = p;
}

// Scales to 4 counts per millimeter, as PS/2 mice count
fn scaled(counts: i32, resolution: u64, rest: *i64) i32 {
    if (resolution == 0 or resolution == 4) return counts;
    const total = rest.* + @as(i64, counts) * 4;
    const r: i64 = @intCast(@min(resolution, 1 << 20));
    const out = @divTrunc(total, r);
    rest.* = total - out * r;
    return @intCast(std.math.clamp(out, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub fn pollMouse() ?platform.Mouse {
    const p = pointer orelse return null;
    // The console's pointer exists even without a mouse; buttons
    // appear once one is there (also when plugged in later)
    if (!p.mode.left_button and !p.mode.right_button) return null;
    var state: SimplePointer.State = undefined;
    if (p.get_state(p, &state) != .success) return .{ .buttons = mouse_buttons }; // nothing new
    mouse_buttons = @as(u8, @intFromBool(state.left_button)) | @as(u8, @intFromBool(state.right_button)) << 1;
    return .{
        .dx = scaled(state.relative_movement_x, p.mode.resolution_x, &rest_x),
        .dy = scaled(state.relative_movement_y, p.mode.resolution_y, &rest_y),
        // UEFI's Z counts away from the user (as USB wheels do), ZDOS's toward
        .wheel = 0 -| state.relative_movement_z,
        .buttons = mouse_buttons,
    };
}

// No key releases on UEFI
pub fn keyEvents(on: bool) bool {
    _ = on;
    return false;
}

pub fn keyEvent() ?platform.KeyEvent {
    return null;
}

// WAKING A TASK THAT WAITS FOR KEYS (TASKS)
// The kernel's foreground task says when it waits (wantInput);
// the idle task then waits for the firmware's key event too,
// and a key wakes it at once. Only then: a key nobody reads
// keeps the event signalled.

var input_wake: ?*const fn () void = null;
var input_wanted = false;

pub fn setInputWake(f: *const fn () void) void {
    input_wake = f;
}

pub fn wantInput(on: bool) void {
    input_wanted = on;
}

// For the idle task: the key event, while a task waits for keys
pub fn inputEvent() ?uefi.Event {
    if (!input_wanted or input_wake == null) return null;
    return if (con_in_ex) |ex| ex.wait_for_key_ex else con_in.wait_for_key;
}

pub fn inputArrived() void {
    if (input_wake) |f| f();
}

// With devices to poll (platform.idle), a 10 ms tick wakes the wait too
var tick: ?uefi.Event = null;

pub fn readKey() platform.Key {
    const key_event = if (con_in_ex) |ex| ex.wait_for_key_ex else con_in.wait_for_key;
    var events = [2]uefi.Event{ key_event, undefined };
    var count: usize = 1;
    if (platform.idle.hook != null) {
        if (tick == null) {
            var e: uefi.Event = undefined;
            if (boot_services.createEvent(uefi.tables.BootServices.event_timer, 0, null, null, &e) == .success and
                boot_services.setTimer(e, .timer_periodic, 100_000) == .success) tick = e;
        }
        if (tick) |t| {
            events[1] = t;
            count = 2;
        }
    }
    while (true) {
        var index: usize = undefined;
        _ = boot_services.waitForEvent(count, &events, &index);
        if (pollKey()) |key| return key;
    }
}

fn mods(state: KeyEx.State) u16 {
    const M = platform.Mod;
    var m: u16 = 0;
    const s = state.shift;
    if (s.shift_state_valid) {
        if (s.left_shift_pressed) m |= M.left_shift;
        if (s.right_shift_pressed) m |= M.right_shift;
        if (s.left_control_pressed) m |= M.left_ctrl;
        if (s.right_control_pressed) m |= M.right_ctrl;
        if (s.left_alt_pressed) m |= M.left_alt;
        if (s.right_alt_pressed) m |= M.right_alt;
        if (s.left_logo_pressed) m |= M.left_logo;
        if (s.right_logo_pressed) m |= M.right_logo;
        if (s.menu_key_pressed) m |= M.menu;
    }
    const t = state.toggle;
    if (t.toggle_state_valid) {
        if (t.caps_lock_active) m |= M.caps_lock;
        if (t.num_lock_active) m |= M.num_lock;
        if (t.scroll_lock_active) m |= M.scroll_lock;
    }
    return m;
}

pub fn loadFont(glyphs: *const [4096]u8) bool {
    _ = glyphs;
    return false;
}

// A .zfn font (tools/make-fonts.py) becomes the text font
// and the screen is cleared. data is kept: the caller must
// not free it. False, nothing changed, if the file is bad or
// the screen can't fit one character. Text is drawn by code
// point, so the codepage is unused on UEFI
pub fn setCodepage(points: *const [256]u32) void {
    _ = points;
}

pub fn loadFontFile(data: []const u8) bool {
    if (data.len < header_size) return false;
    if (!std.mem.eql(u8, data[0..4], "ZFNT") or data[4] != 1) return false;
    const w: u32 = data[5];
    const h: u32 = data[6];
    if (w == 0 or h == 0) return false;
    const count: usize = std.mem.readInt(u32, data[8..12], .little);
    const row_bytes = (w + 7) / 8;
    const entry = 4 + @as(usize, h) * row_bytes;
    if (data.len < header_size + count * entry) return false;

    const g = gop() orelse return false;
    const sw = g.mode.info.horizontal_resolution;
    const sh = g.mode.info.vertical_resolution;
    if (sw < w or sh < h) return false;
    const pixels = @as(usize, sw) * sh;
    const mem = memory.alloc(pixels * @sizeOf(Pixel)) orelse return false;
    if (shadow_mem) |old| memory.free(old);
    shadow_mem = mem;
    shadow = @as([*]Pixel, @ptrCast(mem))[0..pixels];
    // The cells for this grid (the alternate screen's copy is made anew)
    const need = @as(usize, sw / w) * (sh / h);
    const cmem = memory.alloc(need * @sizeOf(u32)) orelse return false;
    if (cells_mem) |old| memory.free(old);
    if (alt_mem) |old| memory.free(old);
    alt_mem = null;
    alt_cells = &.{};
    cells_mem = cmem;
    cells = @as([*]u32, @ptrCast(cmem))[0..need];

    font = .{ .data = data, .cell_w = w, .cell_h = h, .count = count, .row_bytes = row_bytes, .entry = entry };
    gop_ptr = g;
    screen_w = sw;
    screen_h = sh;
    grid_cols = sw / w;
    grid_rows = sh / h;
    drawn = null;
    col = 0;
    row = 0;
    clearFont();
    return true;
}

// THE SCROLLBACK'S SIDE (KERNEL/SCROLLBACK.ZIG): THE SCREEN'S TEXT

// Only with ZDOS's own font: the firmware's text isn't kept
pub fn cellsReady() bool {
    return drawing() and cells.len > 0;
}

pub fn cellAt(c: u32, r: u32) platform.Cell {
    const v = cells[@as(usize, r) * grid_cols + c];
    return .{ .char = @intCast(v & 0x1FFFFF), .fg = @intCast(v >> 21 & 15), .bg = @intCast(v >> 25 & 15) };
}

pub fn setScrollHook(f: *const fn () void) void {
    scroll_hook = f;
}

pub fn viewBegin() void {
    eraseCursor();
    viewing = true;
    dirty_lo = std.math.maxInt(u32);
    dirty_hi = 0;
}

pub fn viewCell(c: u32, r: u32, cell: platform.Cell) void {
    if (c >= grid_cols or r >= grid_rows) return;
    paintPacked(c, r, pack(cell.char, cell.fg, cell.bg));
}

pub fn viewFlush() void {
    if (paused or dirty_lo >= dirty_hi) return;
    viewing = false;
    flushRows(dirty_lo, dirty_hi);
    viewing = true;
    dirty_lo = std.math.maxInt(u32);
    dirty_hi = 0;
}

pub fn viewEnd() void {
    viewing = false;
    paintAll();
    if (!paused) flushRows(0, grid_rows * font.?.cell_h);
    drawn = null;
    showCursorNow();
}

// The alternate screen (full-screen programs): the main
// one comes back after
pub fn altEnter() void {
    if (!drawing()) return;
    if (alt_cells.len != cells.len) {
        const mem = memory.alloc(cells.len * @sizeOf(u32)) orelse return;
        alt_mem = mem;
        alt_cells = @as([*]u32, @ptrCast(mem))[0..cells.len];
    }
    @memcpy(alt_cells, cells);
    alt_col = col;
    alt_row = row;
}

pub fn altLeave() void {
    if (!drawing() or alt_cells.len != cells.len) return;
    eraseCursor();
    @memcpy(cells, alt_cells);
    col = alt_col;
    row = alt_row;
    paintAll();
    if (!paused) flushRows(0, grid_rows * font.?.cell_h);
    drawn = null;
    showCursorNow();
}
