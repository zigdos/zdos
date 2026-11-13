// Frame characters, and which set the screen can show.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");

// double: double outer frame, single inner lines;
// single: all single (codepages without the mixed joints);
// ascii: codepages without box drawing (CP1251, CP1252)
pub const Style = enum { double, single, ascii };

pub const Set = struct {
    h: u21, // outer frame
    v: u21,
    tl: u21,
    tr: u21,
    bl: u21,
    br: u21,
    sh: u21, // inner lines
    sv: u21,
    top_t: u21, // inner column at the top frame
    cross_up: u21, // inner column ending at an inner line
    left_t: u21, // inner line at the left and right frame
    right_t: u21,
    done: u21 = '█', // progress bars
    todo: u21 = '░',
};

pub fn of(style: Style) Set {
    return switch (style) {
        .double => .{
            .h = '═', .v = '║', .tl = '╔', .tr = '╗', .bl = '╚', .br = '╝',
            .sh = '─', .sv = '│', .top_t = '╤', .cross_up = '┴',
            .left_t = '╟', .right_t = '╢',
        },
        .single => .{
            .h = '─', .v = '│', .tl = '┌', .tr = '┐', .bl = '└', .br = '┘',
            .sh = '─', .sv = '│', .top_t = '┬', .cross_up = '┴',
            .left_t = '├', .right_t = '┤',
        },
        .ascii => .{
            .h = '=', .v = '|', .tl = '+', .tr = '+', .bl = '+', .br = '+',
            .sh = '-', .sv = '|', .top_t = '+', .cross_up = '+',
            .left_t = '+', .right_t = '+',
            .done = '#', .todo = '.',
        },
    };
}

pub fn parse(word: []const u8) ?Style {
    inline for (std.meta.fields(Style)) |f| {
        if (std.ascii.eqlIgnoreCase(word, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

// The BIOS screen shows the bytes of CODEPAGE= (with a FONT=
// other than firmware); the ROM font and the drawn fonts of the
// other editions have every frame character.
pub fn detect() Style {
    var buf: [32]u8 = undefined;
    const platform = zdos.getVar("PLATFORM", &buf) orelse "";
    if (!std.ascii.eqlIgnoreCase(platform, "BIOS")) return .double;
    const font = zdos.getVar("FONT", &buf) orelse "firmware";
    if (std.ascii.eqlIgnoreCase(font, "firmware")) return .double;
    const cp = zdos.getVar("CODEPAGE", &buf) orelse "CP437";
    for ([_][]const u8{ "CP1251", "CP1252" }) |name| {
        if (std.ascii.eqlIgnoreCase(cp, name)) return .ascii;
    }
    for ([_][]const u8{ "CP850", "CP852", "CP855", "CP857" }) |name| {
        if (std.ascii.eqlIgnoreCase(cp, name)) return .single;
    }
    return .double;
}
