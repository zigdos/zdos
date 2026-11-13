// Colors: blue (the classic look) or dark (theme= in ZC.CFG).
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");

const Color = zdos.Color;

pub const Theme = struct {
    panel: Color, // panel and viewer background
    frame: Color, // frames, column lines, info line
    text: Color, // file names without a color of their own
    folder: Color, // folder names
    heading: Color, // column titles
    accent: Color, // cursor bar, active path, key labels, bars
    field_fg: Color, // input fields in the light gray boxes
    field_bg: Color,
    pick_bg: Color, // a box's chosen entry (white text)
};

pub const blue: Theme = .{
    .panel = .blue, .frame = .light_cyan, .text = .light_cyan, .folder = .white, .heading = .yellow, .accent = .cyan,
    .field_fg = .black, .field_bg = .cyan, .pick_bg = .cyan,
};

pub const dark: Theme = .{
    .panel = .black, .frame = .light_gray, .text = .light_gray, .folder = .light_blue, .heading = .white, .accent = .light_gray,
    .field_fg = .white, .field_bg = .black, .pick_bg = .black,
};

pub var now: Theme = blue;

pub fn parse(word: []const u8) ?Theme {
    if (std.ascii.eqlIgnoreCase(word, "blue")) return blue;
    if (std.ascii.eqlIgnoreCase(word, "dark")) return dark;
    return null;
}
