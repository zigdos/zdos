// An ANSI terminal on a serial port: output with escape
// sequences, keys decoded from the terminal's sequences.
// Assumes 80x25. Port: put(u8), get() ?u8.
const std = @import("std");
const platform = @import("../../platform.zig");

pub fn Terminal(comptime Port: type) type {
    return struct {

        const cols = 80;
        const rows = 25;

        // Where the terminal's cursor is, as far as the text written tells
        var col: u32 = 0;
        var row: u32 = 0;

        pub fn clear() void {
            writeRaw("\x1b[0m\x1b[2J\x1b[H");
            col = 0;
            row = 0;
        }

        pub fn write(str: []const u8) void {
            for (str) |c| {
                switch (c) {
                    '\n' => {
                        writeRaw("\r\n");
                        col = 0;
                        row = @min(row + 1, rows - 1);
                    },
                    '\r' => {
                        Port.put(c);
                        col = 0;
                    },
                    0x08 => {
                        Port.put(c);
                        col -|= 1;
                    },
                    else => {
                        Port.put(c);
                        // UTF-8 continuation bytes don't move the cursor
                        if (c & 0xC0 != 0x80) col += 1;
                        if (col == cols) {
                            col = 0;
                            row = @min(row + 1, rows - 1);
                        }
                    },
                }
            }
        }

        // The terminal's own rows don't match the framebuffer's: its
        // current line and below are cleared
        pub fn clearBelow() void {
            writeRaw("\r\x1b[J");
            col = 0;
        }

        pub fn getCursor() platform.Position {
            return .{ .col = col, .row = row };
        }

        pub fn setCursor(pos: platform.Position) void {
            col = @min(pos.col, cols - 1);
            row = @min(pos.row, rows - 1);
            var buf: [16]u8 = undefined;
            writeRaw(std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch return);
        }

        // The 16 PC colors (black, blue, green, cyan, red, magenta,
        // brown, light gray, then the bright ones) as ANSI colors
        const ansi_color = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

        pub fn setColor(fg: u8, bg: u8) void {
            const f = @as(u32, ansi_color[fg & 7]) + @as(u32, if (fg & 8 != 0) 90 else 30);
            const b = @as(u32, ansi_color[bg & 7]) + @as(u32, if (bg & 8 != 0) 100 else 40);
            var buf: [16]u8 = undefined;
            writeRaw(std.fmt.bufPrint(&buf, "\x1b[{d};{d}m", .{ f, b }) catch return);
        }

        pub fn showCursor(visible: bool) void {
            writeRaw(if (visible) "\x1b[?25h" else "\x1b[?25l");
        }

        pub fn size() platform.Position {
            return .{ .col = cols, .row = rows };
        }

        fn writeRaw(bytes: []const u8) void {
            for (bytes) |c| Port.put(c);
        }

        pub fn pollKey() ?platform.Key {
            const c = Port.get() orelse return null;
            return switch (c) {
                0x1b => escape(),
                '\n' => .{ .char = '\r', .scan = 0 },
                0x7f => .{ .char = 0x08, .scan = 0 }, // Backspace sends DEL on most terminals
                else => .{ .char = c, .scan = 0 },
            };
        }

        // After ESC: a key's sequence (ESC [ A, ESC [ 3 ~, ESC O P ...)
        // follows at once; nothing within a
        // few milliseconds means Esc itself
        fn escape() platform.Key {
            const S = platform.Scan;
            const esc: platform.Key = .{ .char = 0, .scan = S.esc };
            const intro = nextByte() orelse return esc;
            if (intro != '[' and intro != 'O') return esc;
            var number: u16 = 0;
            while (true) {
                const c = nextByte() orelse return esc;
                switch (c) {
                    '0'...'9' => number = number *| 10 +| (c - '0'),
                    ';' => number = 0, // modifiers: ignored
                    else => return .{ .char = 0, .scan = switch (c) {
                        'A' => S.up,
                        'B' => S.down,
                        'C' => S.right,
                        'D' => S.left,
                        'H' => S.home,
                        'F' => S.end,
                        'P', 'Q', 'R', 'S' => S.f1 + (c - 'P'), // F1-F4 (ESC O P ...)
                        '~' => switch (number) {
                            1, 7 => S.home,
                            2 => S.insert,
                            3 => S.delete,
                            4, 8 => S.end,
                            5 => S.page_up,
                            6 => S.page_down,
                            11...15 => S.f1 + (number - 11), // F1-F5
                            17...21 => S.f1 + 5 + (number - 17), // F6-F10
                            23 => S.f11,
                            24 => S.f12,
                            else => return esc,
                        },
                        else => return esc,
                    } },
                }
            }
        }

        // The next byte of a sequence, waiting up to 20 ms
        fn nextByte() ?u8 {
            const until = platform.clock.millis() + 20;
            while (platform.clock.millis() < until) {
                if (Port.get()) |c| return c;
                std.atomic.spinLoopHint();
            }
            return null;
        }
    };
}
