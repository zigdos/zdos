// Text console on the GOP framebuffer after
// leaving the firmware. Text goes into `shadow`
// (RAM, without the cursor) and changed rows are
// copied out, so video memory is never read.
// Built-in font until FONT= loads a .zfn.
// While a program's picture shows, text goes
// only into the shadow. The text is also kept as
// cells (character and colors) for the
// scrollback (kernel/scrollback.zig),
// which while it shows history has the screen.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const memory = @import("memory.zig");

const Gop = uefi.protocol.GraphicsOutput;

const header_size = 16; // "ZFNT" file header

const vga_rgb = [16][3]u8{
    .{ 0, 0, 0 },     .{ 0, 0, 170 },    .{ 0, 170, 0 },    .{ 0, 170, 170 },
    .{ 170, 0, 0 },   .{ 170, 0, 170 },  .{ 170, 85, 0 },   .{ 170, 170, 170 },
    .{ 85, 85, 85 },  .{ 85, 85, 255 },  .{ 85, 255, 85 },  .{ 85, 255, 255 },
    .{ 255, 85, 85 }, .{ 255, 85, 255 }, .{ 255, 255, 85 }, .{ 255, 255, 255 },
};

// The screen as the firmware set it up: 32 bits per pixel, the
// color channels where the masks say
const Screen = struct {
    base: [*]volatile u32,
    width: u32,
    height: u32,
    pitch: u32, // pixels from one row to the next
    red: u32, // channel masks
    green: u32,
    blue: u32,
};

const Font = struct {
    data: []const u8,
    cell_w: u32,
    cell_h: u32,
    count: usize, // glyphs, in code point order
    row_bytes: usize, // (cell_w + 7) / 8
    entry: usize, // bytes per glyph: code point + cell_h rows
};

var screen: ?Screen = null;
var font: Font = undefined;
var shadow: []u32 = &.{};
var shadow_mem: ?[*]align(8) u8 = null;
var grid_cols: u32 = 0;
var grid_rows: u32 = 0;
var col: u32 = 0; // the cursor
var row: u32 = 0;
var fg_px: u32 = 0;
var bg_px: u32 = 0;
var cursor_visible = true;
var drawn: ?platform.Position = null; // where the cursor is drawn on the screen now
var dirty_lo: u32 = 0; // pixel rows [dirty_lo, dirty_hi) changed in the copy
var dirty_hi: u32 = 0;
var paused = false; // a picture is on the screen (graphics.zig)

// The text as cells: character (21
// bits), foreground (4), background (4)
var cells: []u32 = &.{};
var cur_fg: u8 = 7;
var cur_bg: u8 = 0;
var viewing = false; // the scrollback has the screen: text goes to cells only
var scroll_hook: ?*const fn () void = null;
// The main screen while the alternate one is on
var alt_cells: []u32 = &.{};
var alt_col: u32 = 0;
var alt_row: u32 = 0;

fn pack(ch: u21, fg: u8, bg: u8) u32 {
    return @as(u32, ch) | @as(u32, fg & 15) << 21 | @as(u32, bg & 15) << 25;
}

fn blank() u32 {
    return pack(' ', cur_fg, cur_bg);
}

// While the firmware runs: the console's GOP, or any, if it has
// a linear framebuffer of 32-bit pixels;
// set_mode may switch its mode first
pub fn capture(set_mode: *const fn (*Gop) void) void {
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.console_out_handle) |h| {
        if (bs.handleProtocol(h, &Gop.guid, &ptr) != .success) ptr = null;
    }
    if (ptr == null and bs.locateProtocol(&Gop.guid, null, &ptr) != .success) return;
    const gop: *Gop = @ptrCast(@alignCast(ptr orelse return));
    set_mode(gop);
    const mode = gop.mode;
    const info = mode.info;
    var masks: [3]u32 = undefined;
    switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => masks = .{ 0x0000FF, 0x00FF00, 0xFF0000 },
        .blue_green_red_reserved_8_bit_per_color => masks = .{ 0xFF0000, 0x00FF00, 0x0000FF },
        .bit_mask => masks = .{ info.pixel_information.red_mask, info.pixel_information.green_mask, info.pixel_information.blue_mask },
        .blt_only => return, // no framebuffer (virtio-gpu): no screen
    }
    if (mode.frame_buffer_base == 0 or info.pixels_per_scan_line < info.horizontal_resolution) return;
    screen = .{
        .base = @ptrFromInt(mode.frame_buffer_base),
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = info.pixels_per_scan_line,
        .red = masks[0],
        .green = masks[1],
        .blue = masks[2],
    };
}

// A screen was found
pub fn found() bool {
    return screen != null;
}

// Where its memory is (paging.zig maps it); empty without a screen
pub fn range() memory.Device {
    const s = screen orelse return .{ .start = 0, .end = 0 };
    const base = @intFromPtr(s.base);
    return .{ .start = base, .end = base + @as(u64, s.pitch) * s.height * 4 };
}

// After leaving the firmware (memory works): the screen with
// the built-in font.
// False: no screen, or no memory for the copy.
pub fn start() bool {
    if (screen == null) return false;
    fg_px = pixelOf(7);
    bg_px = pixelOf(0);
    const res: bool = loadFontFile(@embedFile("default_font.zfn"));
    clear();
    return res;
}

pub fn active() bool {
    return shadow.len > 0;
}

// An 8-bit channel value (0-255) scaled into a channel mask's bits
fn channel(value: u8, mask: u32) u32 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const scaled: u32 = @intCast(@as(u64, value) * (mask >> shift) / 255);
    return (scaled << shift) & mask;
}

fn pixelOf(color: u8) u32 {
    const s = screen.?;
    const rgb = vga_rgb[color & 0x0F];
    return channel(rgb[0], s.red) | channel(rgb[1], s.green) | channel(rgb[2], s.blue);
}

fn markDirty(lo: u32, hi: u32) void {
    dirty_lo = @min(dirty_lo, lo);
    dirty_hi = @max(dirty_hi, hi);
}

// Pixel rows [lo, hi) from the copy to the screen
fn flushRows(lo: u32, hi: u32) void {
    if (paused or viewing) return;
    const s = screen.?;
    var y = lo;
    while (y < hi) : (y += 1) {
        const from = shadow[@as(usize, y) * s.width ..][0..s.width];
        const to = s.base + @as(usize, y) * s.pitch;
        for (from, 0..) |p, x| to[x] = p;
    }
}

const Rect = struct { x: usize, y: usize, w: usize, h: usize };

// The cursor's underline: the bottom rows of its cell
fn cursorRect(at: platform.Position) Rect {
    const h: usize = @max(1, font.cell_h / 8);
    return .{
        .x = @as(usize, at.col) * font.cell_w,
        .y = (@as(usize, at.row) + 1) * font.cell_h - h,
        .w = font.cell_w,
        .h = h,
    };
}

fn eraseCursor() void {
    if (paused or viewing) return;
    const at = drawn orelse return;
    drawn = null;
    const s = screen.?;
    const r = cursorRect(at);
    for (r.y..r.y + r.h) |y| {
        for (r.x..r.x + r.w) |x| s.base[y * s.pitch + x] = shadow[y * s.width + x];
    }
}

fn showCursorNow() void {
    if (paused or viewing or !cursor_visible or drawn != null) return;
    const s = screen.?;
    const at: platform.Position = .{ .col = col, .row = row };
    const r = cursorRect(at);
    for (r.y..r.y + r.h) |y| {
        for (r.x..r.x + r.w) |x| s.base[y * s.pitch + x] = fg_px;
    }
    drawn = at;
}

// A character in the current colors: into the cells, and drawn
fn drawCell(c: u32, r: u32, ch: u21) void {
    cells[@as(usize, r) * grid_cols + c] = pack(ch, cur_fg, cur_bg);
    if (!viewing) paintCell(c, r, if (ch == ' ') null else glyphOf(ch), fg_px, bg_px);
}

// glyph null: blank
fn paintCell(c: u32, r: u32, glyph: ?[]const u8, fg: u32, bg: u32) void {
    const width: usize = screen.?.width;
    const x0 = @as(usize, c) * font.cell_w;
    const y0 = @as(usize, r) * font.cell_h;
    for (0..font.cell_h) |y| {
        const line = shadow[(y0 + y) * width + x0 ..][0..font.cell_w];
        const bits: []const u8 = if (glyph) |g| g[y * font.row_bytes ..][0..font.row_bytes] else &.{};
        for (line, 0..) |*p, x| {
            const ink = bits.len > 0 and bits[x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
            p.* = if (ink) fg else bg;
        }
    }
    markDirty(@intCast(y0), @intCast(y0 + font.cell_h));
}

fn paintPacked(c: u32, r: u32, v: u32) void {
    const ch: u21 = @intCast(v & 0x1FFFFF);
    paintCell(c, r, if (ch == ' ') null else glyphOf(ch), pixelOf(@intCast(v >> 21 & 15)), pixelOf(@intCast(v >> 25 & 15)));
}

// The whole text again from the cells
fn paintAll() void {
    for (0..grid_rows) |r| {
        for (0..grid_cols) |c| paintPacked(@intCast(c), @intCast(r), cells[r * grid_cols + c]);
    }
}

fn scroll() void {
    if (scroll_hook) |f| f(); // the top row into the scrollback, before it goes
    const n = @as(usize, grid_rows - 1) * grid_cols;
    std.mem.copyForwards(u32, cells[0..n], cells[grid_cols..][0..n]);
    @memset(cells[n..][0..grid_cols], blank());
    if (viewing) return;
    const s = screen.?;
    const width: usize = s.width;
    const cell_h: usize = font.cell_h;
    const text_h = @as(usize, grid_rows) * cell_h;
    const keep = (text_h - cell_h) * width; // pixels of the text rows below the first
    std.mem.copyForwards(u32, shadow[0..keep], shadow[cell_h * width ..][0..keep]);
    @memset(shadow[keep .. @as(usize, s.height) * width], bg_px);
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

// Binary search: glyphs are in code point order
fn findGlyph(code: u32) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = font.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = header_size + mid * font.entry;
        const c = std.mem.readInt(u32, font.data[at..][0..4], .little);
        if (c == code) return font.data[at + 4 ..][0 .. font.entry - 4];
        if (c < code) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn putChar(c: u21) void {
    drawCell(col, row, c);
    col += 1;
    if (col >= grid_cols) newline();
}

pub const Surface = struct {
    base: [*]u32, // written only, never read: video memory
    width: u32,
    height: u32,
    pitch: u32,
};

// The screen for a picture; null without
// one (no screen, or not started)
pub fn surface() ?Surface {
    const s = screen orelse return null;
    if (!active()) return null;
    return .{ .base = @volatileCast(s.base), .width = s.width, .height = s.height, .pitch = s.pitch };
}

// A color as the screen's pixel
pub fn rgbPixel(r: u8, g: u8, b: u8) u32 {
    const s = screen.?;
    return channel(r, s.red) | channel(g, s.green) | channel(b, s.blue);
}

// A picture takes the screen (true) or gives it back: the text
// as it is now, with its cursor
pub fn pause(on: bool) void {
    if (on) {
        eraseCursor();
        paused = true;
        return;
    }
    paused = false;
    drawn = null;
    flushRows(0, screen.?.height);
    showCursorNow();
}

// THE CONSOLE'S TEXT FUNCTIONS (console.zig), ONCE ACTIVE

// Same control characters as the BIOS text screen
pub fn write(str: []const u8) void {
    eraseCursor();
    dirty_lo = std.math.maxInt(u32);
    dirty_hi = 0;
    var i: usize = 0;
    while (i < str.len) {
        const len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const c: u21 = if (i + len <= str.len) std.unicode.utf8Decode(str[i..][0..len]) catch '?' else '?';
        i += if (i + len <= str.len) len else 1;
        switch (c) {
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
            else => if (c >= 0x20 and c != 0x7F) putChar(c),
        }
    }
    if (dirty_lo < dirty_hi) flushRows(dirty_lo, dirty_hi);
    showCursorNow();
}

pub fn clear() void {
    @memset(cells, blank());
    col = 0;
    row = 0;
    if (viewing) return;
    @memset(shadow, bg_px);
    flushRows(0, screen.?.height);
    drawn = null; // the screen has no cursor now
    col = 0;
    row = 0;
    showCursorNow();
}

// Text row `from` and those below it blank, the cursor at its start
pub fn clearBelow(from: u32) void {
    eraseCursor();
    const first = @as(usize, @min(from, grid_rows)) * grid_cols;
    @memset(cells[first..], blank());
    if (viewing) {
        col = 0;
        row = @min(from, grid_rows -| 1);
        return;
    }
    const s = screen.?;
    const y0 = @min(@as(usize, from) * font.cell_h, s.height);
    @memset(shadow[y0 * s.width .. @as(usize, s.height) * s.width], bg_px);
    flushRows(@intCast(y0), s.height);
    col = 0;
    row = @min(from, grid_rows -| 1);
    showCursorNow();
}

pub fn getCursor() platform.Position {
    return .{ .col = col, .row = row };
}

pub fn setCursor(pos: platform.Position) void {
    eraseCursor();
    col = @min(pos.col, grid_cols - 1);
    row = @min(pos.row, grid_rows - 1);
    showCursorNow();
}

pub fn setColor(fg: u8, bg: u8) void {
    cur_fg = fg & 15;
    cur_bg = bg & 15;
    fg_px = pixelOf(fg);
    bg_px = pixelOf(bg);
}

pub fn showCursor(visible: bool) void {
    cursor_visible = visible;
    if (visible) showCursorNow() else eraseCursor();
}

pub fn size() platform.Position {
    return .{ .col = grid_cols, .row = grid_rows };
}

// A .zfn font becomes the text font and the screen is cleared.
// data is kept: the caller must not free it. False, nothing
// changed, if the file is bad or the
// screen can't fit one character.
pub fn loadFontFile(data: []const u8) bool {
    const s = screen orelse return false;
    if (data.len < header_size) return false;
    if (!std.mem.eql(u8, data[0..4], "ZFNT") or data[4] != 1) return false;
    const w: u32 = data[5];
    const h: u32 = data[6];
    if (w == 0 or h == 0) return false;
    const count: usize = std.mem.readInt(u32, data[8..12], .little);
    const row_bytes = (w + 7) / 8;
    const entry = 4 + @as(usize, h) * row_bytes;
    if (data.len < header_size + count * entry) return false;
    if (s.width < w or s.height < h) return false;

    // The copy: allocated once, the screen's size doesn't change
    if (shadow_mem == null) {
        const pixels = @as(usize, s.width) * s.height;
        const mem = memory.alloc(pixels * @sizeOf(u32)) orelse return false;
        shadow_mem = mem;
        shadow = @as([*]u32, @ptrCast(mem))[0..pixels];
    }
    // The cells, for the new grid (a bigger one replaces them)
    const need = @as(usize, s.width / w) * (s.height / h);
    if (need > cells.len) {
        const mem = memory.alloc(need * @sizeOf(u32)) orelse return false;
        if (cells.len > 0) memory.free(@ptrCast(@alignCast(cells.ptr)));
        if (alt_cells.len > 0) memory.free(@ptrCast(@alignCast(alt_cells.ptr)));
        alt_cells = &.{};
        cells = @as([*]u32, @ptrCast(mem))[0..need];
    }
    font = .{ .data = data, .cell_w = w, .cell_h = h, .count = count, .row_bytes = row_bytes, .entry = entry };
    grid_cols = s.width / w;
    grid_rows = s.height / h;
    cells = cells.ptr[0..need];
    drawn = null;
    return true;
}

// THE SCROLLBACK'S SIDE (kernel/scrollback.zig)

pub fn cellsReady() bool {
    return cells.len > 0;
}

pub fn cellAt(c: u32, r: u32) platform.Cell {
    const v = cells[@as(usize, r) * grid_cols + c];
    return .{ .char = @intCast(v & 0x1FFFFF), .fg = @intCast(v >> 21 & 15), .bg = @intCast(v >> 25 & 15) };
}

pub fn setScrollHook(f: *const fn () void) void {
    scroll_hook = f;
}

// History takes the screen: text keeps going into the cells only
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

// The live text again
pub fn viewEnd() void {
    viewing = false;
    paintAll();
    flushRows(0, screen.?.height);
    drawn = null;
    showCursorNow();
}

// The alternate screen (full-screen programs): the main one is
// kept and comes back when it ends
pub fn altEnter() void {
    if (alt_cells.len != cells.len) {
        const mem = memory.alloc(cells.len * @sizeOf(u32)) orelse return;
        alt_cells = @as([*]u32, @ptrCast(mem))[0..cells.len];
    }
    @memcpy(alt_cells, cells);
    alt_col = col;
    alt_row = row;
}

pub fn altLeave() void {
    if (alt_cells.len != cells.len) return;
    eraseCursor();
    @memcpy(cells, alt_cells);
    col = alt_col;
    row = alt_row;
    paintAll();
    flushRows(0, screen.?.height);
    drawn = null;
    showCursorNow();
}
