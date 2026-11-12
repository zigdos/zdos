// Graphics for Zig programs: the 256-color picture, key events, the
// mouse and its cursor (group gfx).
const zdos = @import("zdos.zig");

const Error = zdos.Error;
pub const KeyEvent = @import("abi").KeyEvent;
pub const Mouse = @import("abi").Mouse;
pub const MouseButton = @import("abi").MouseButton;

fn api() *const zdos.Api {
    return zdos.table();
}

pub fn begin(width: u32, height: u32) Error!void {
    return zdos.check(api().gfx.begin(width, height));
}

// Shown 4:3, as a DOS screen did (320 x 200 has tall pixels), for DOS ports.
// UEFI only; on BIOS the monitor gives the shape.
pub fn beginDosAspect(width: u32, height: u32) Error!void {
    return zdos.check(api().gfx.begin_dos_aspect(width, height));
}

pub fn palette(first: u8, colors: []const [3]u8) void {
    api().gfx.palette(first, @intCast(colors.len), @ptrCast(colors.ptr));
}

pub fn draw(pixels: []const u8) void {
    api().gfx.draw(pixels.ptr);
}

pub fn end() void {
    api().gfx.end();
}

pub const ScreenInfo = @import("abi").ScreenInfo;

// A picture of the screen's size is shown 1:1, smaller ones
// scaled by a whole number.
pub const ScreenSize = @import("abi").ScreenSize;

// Smallest first, as many as fit in buf.
pub fn modes(buf: []ScreenSize) []ScreenSize {
    const n = api().gfx.modes(buf.ptr, buf.len);
    return buf[0..@min(n, buf.len)];
}

pub fn screen() Error!ScreenInfo {
    var info: ScreenInfo = undefined;
    try zdos.check(api().gfx.screen(&info));
    return info;
}

// drawRgb takes width * height pixels 0x00RRGGBB.
pub fn beginRgb(width: u32, height: u32) Error!void {
    return zdos.check(api().gfx.begin_rgb(width, height));
}

pub fn drawRgb(pixels: []const u32) void {
    api().gfx.draw_rgb(pixels.ptr);
}

// TABS: each program in graphics has one; Alt+Tab / Win+Tab brings the
// next to the front, which alone is shown and gets input

// A game may pause while not.
pub fn visible() bool {
    return api().gfx.visible();
}

// Its program's name until set.
pub fn setTitle(title: []const u8) void {
    api().gfx.set_title(title.ptr, title.len);
}

// KEY EVENTS

// Since the last call, UTF-8 with the layout applied.
pub fn textInput(buf: []u8) []u8 {
    return buf[0..api().gfx.text_input(buf.ptr, buf.len)];
}

pub fn keyEvent() Error!?KeyEvent {
    var e: KeyEvent = undefined;
    if (api().gfx.key_event(&e)) return e;
    if (zdos.lastErrorCode() == .not_supported) return error.NotSupported;
    return null;
}

// MOUSE

pub fn mouse() Error!Mouse {
    var m: Mouse = undefined;
    if (api().gfx.mouse(&m)) return m;
    return zdos.lastError();
}

// icons/cursor.png: ' ' transparent, '#' black, '+' gray, '.' white;
// the tip, at the top left, is the point.
pub const arrow = [_]*const [20]u8{
    ".                   ",
    "..                  ",
    "...                 ",
    "....                ",
    ".....               ",
    "..+...              ",
    "..#+...             ",
    "..##+...            ",
    "..###+...           ",
    "..####+...          ",
    "..#####+...         ",
    "..######+...        ",
    "..#######+...       ",
    "..########+...      ",
    "..#########+...     ",
    "..##########+...    ",
    "..###########+...   ",
    "..############+...  ",
    "..#############+... ",
    "..#######+..........",
    "..###.+###..        ",
    "..##...###+..       ",
    "..#....+###..       ",
    "..... ..###+..      ",
    "....  ..+###..      ",
    "...    ..###+.      ",
    "..     ..+###..     ",
    ".       ..###+.     ",
    "        ..+##+..    ",
    "         .......    ",
    "         ....       ",
    "         ..         ",
};

// icons/cursorsm.png, drawn the same way.
pub const small_arrow = [_]*const [10]u8{
    ".         ",
    "..        ",
    ".+.       ",
    ".#+.      ",
    ".##+.     ",
    ".###+.    ",
    ".####+.   ",
    ".#####+.  ",
    ".######+. ",
    ".#######..",
    ".####+..  ",
    ".#.+#+.   ",
    ".. .##+.  ",
    ".  .+#+.  ",
    "    .#+.  ",
    "     ..   ",
};

pub fn drawArrow(picture: []u8, width: usize, x: i32, y: i32, black: u8, gray: u8, white: u8) void {
    drawCursor(&arrow, picture, width, x, y, black, gray, white);
}

pub fn drawSmallArrow(picture: []u8, width: usize, x: i32, y: i32, black: u8, gray: u8, white: u8) void {
    drawCursor(&small_arrow, picture, width, x, y, black, gray, white);
}

fn drawCursor(shape: anytype, picture: []u8, width: usize, x: i32, y: i32, black: u8, gray: u8, white: u8) void {
    const height = picture.len / width;
    for (shape, 0..) |row, dy| {
        const py = y + @as(i32, @intCast(dy));
        if (py < 0 or py >= height) continue;
        for (row, 0..) |c, dx| {
            const px = x + @as(i32, @intCast(dx));
            if (px < 0 or px >= width or c == ' ') continue;
            picture[@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))] = switch (c) {
                '#' => black,
                '+' => gray,
                else => white,
            };
        }
    }
}
