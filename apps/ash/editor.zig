// The interactive command line: editing, history and Tab completion.
// Background output makes it redraw below (Scan.redraw).
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const complete = @import("complete.zig");

pub const max_line = 1024;
const history_size = 32;

var command_history: [history_size][max_line]u8 = undefined;
var command_history_lengths: [history_size]usize = undefined;
var command_history_count: usize = 0;
var command_history_next: usize = 0;

// As shell.zig's printPrompt last showed it, to show it again.
var prompt_buf: [512]u8 = undefined;
var prompt_len: usize = 0;

pub fn setPrompt(text: []const u8) void {
    prompt_len = @min(text.len, prompt_buf.len);
    @memcpy(prompt_buf[0..prompt_len], text[0..prompt_len]);
}

pub fn readLine(buffer: []u8) ?[]const u8 {
    var editor: LineEditor = .{
        .buffer = buffer[0..@min(buffer.len, max_line)],
        .start = zdos.getCursor(),
        .width = @max(1, zdos.screenSize().col),
    };
    var browse: usize = 0;
    var draft: [max_line]u8 = undefined;
    var draft_len: usize = 0;
    defer zdos.editLine(null);
    while (true) {
        zdos.editLine(editor.start.row);
        const key = zdos.readKey();
        if (key.scan == zdos.Scan.redraw) {
            // Another task wrote where the line was:
            // prompt and line again below:
            if (zdos.getCursor().col != 0) zdos.print("\n");
            zdos.print(prompt_buf[0..prompt_len]);
            editor.start = zdos.getCursor();
            editor.redraw(0, 0);
            continue;
        }
        if (key.char == 3) {
            editor.moveTo(editor.len);
            zdos.print("^C\n");
            return editor.buffer[0..0];
        }
        if (key.char == 4 and editor.len == 0) {
            zdos.print("\n");
            return null;
        }
        if (key.char == '\r' or key.char == '\n') {
            editor.moveTo(editor.len);
            zdos.print("\n");
            addHistory(editor.buffer[0..editor.len]);
            return editor.buffer[0..editor.len];
        }
        if (key.scan == zdos.Scan.up) {
            if (browse < command_history_count) {
                if (browse == 0) {
                    draft_len = editor.len;
                    @memcpy(draft[0..editor.len], editor.buffer[0..editor.len]);
                }
                browse += 1;
                editor.replace(historyEntry(browse));
            }
            continue;
        }
        if (key.scan == zdos.Scan.down) {
            if (browse > 0) {
                browse -= 1;
                editor.replace(if (browse == 0) draft[0..draft_len] else historyEntry(browse));
            }
            continue;
        }
        if (key.char == '\t') {
            if (complete.complete(editor.buffer[0..editor.pos])) |completion| {
                editor.splice(completion.start, completion.text);
                browse = 0;
            }
            continue;
        }
        switch (key.scan) {
            zdos.Scan.left => editor.left(),
            zdos.Scan.right => editor.right(),
            zdos.Scan.home => editor.moveTo(0),
            zdos.Scan.end => editor.moveTo(editor.len),
            zdos.Scan.delete => editor.deleteAt(),
            else => switch (key.char) {
                0x08, 0x7f => editor.backspace(),
                else => if (key.char >= 0x20) {
                    editor.insert(key.char);
                    browse = 0;
                },
            },
        }
    }
}

fn historyEntry(n: usize) []const u8 {
    const slot = (command_history_next + history_size - n) % history_size;
    return command_history[slot][0..command_history_lengths[slot]];
}

fn addHistory(line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return;
    if (command_history_count > 0 and std.mem.eql(u8, historyEntry(1), line)) return;
    @memcpy(command_history[command_history_next][0..line.len], line);
    command_history_lengths[command_history_next] = line.len;
    command_history_next = (command_history_next + 1) % history_size;
    command_history_count = @min(command_history_count + 1, history_size);
}

const LineEditor = struct {
    buffer: []u8,
    len: usize = 0,
    pos: usize = 0,
    start: zdos.Pos,
    width: u32,

    fn previousLength(self: *const LineEditor, at: usize) usize {
        var i = at - 1;
        while (i > 0 and isContinuation(self.buffer[i])) i -= 1;
        return at - i;
    }

    fn nextLength(self: *const LineEditor, at: usize) usize {
        var i = at + 1;
        while (i < self.len and isContinuation(self.buffer[i])) i += 1;
        return i - at;
    }

    fn moveTo(self: *LineEditor, at: usize) void {
        self.pos = at;
        const cells = self.start.col + @as(u32, @intCast(characterCount(self.buffer[0..at])));
        zdos.setCursor(cells % self.width, self.start.row + cells / self.width);
    }

    fn left(self: *LineEditor) void {
        if (self.pos > 0) self.moveTo(self.pos - self.previousLength(self.pos));
    }

    fn right(self: *LineEditor) void {
        if (self.pos < self.len) self.moveTo(self.pos + self.nextLength(self.pos));
    }

    fn redraw(self: *LineEditor, from: usize, blanks: usize) void {
        const cells_before = self.start.col + @as(u32, @intCast(characterCount(self.buffer[0..from])));
        zdos.setCursor(cells_before % self.width, self.start.row + cells_before / self.width);
        zdos.print(self.buffer[from..self.len]);
        for (0..blanks) |_| zdos.print(" ");
        const cells_after = self.start.col + @as(u32, @intCast(characterCount(self.buffer[0..self.len]))) + @as(u32, @intCast(blanks));
        // At the right edge a pty's terminal (TERM, SSH) wraps only with
        // the next character, as a VT does; the screen at once: there too
        if (cells_after > 0 and cells_after % self.width == 0 and zdos.getCursor().col != 0) zdos.print("\r\n");
        const expected_row = self.start.row + cells_after / self.width;
        const row = zdos.getCursor().row;
        if (row < expected_row) self.start.row -|= expected_row - row;
        self.moveTo(self.pos);
    }

    fn insert(self: *LineEditor, character: u21) void {
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(character, &encoded) catch return;
        if (self.len + count > self.buffer.len) return;
        std.mem.copyBackwards(u8, self.buffer[self.pos + count .. self.len + count], self.buffer[self.pos..self.len]);
        @memcpy(self.buffer[self.pos..][0..count], encoded[0..count]);
        self.len += count;
        const from = self.pos;
        self.pos += count;
        self.redraw(from, 0);
    }

    fn backspace(self: *LineEditor) void {
        if (self.pos == 0) return;
        self.pos -= self.previousLength(self.pos);
        self.deleteAt();
    }

    fn deleteAt(self: *LineEditor) void {
        if (self.pos == self.len) return;
        const count = self.nextLength(self.pos);
        std.mem.copyForwards(u8, self.buffer[self.pos .. self.len - count], self.buffer[self.pos + count .. self.len]);
        self.len -= count;
        self.redraw(self.pos, 1);
    }

    fn splice(self: *LineEditor, start: usize, text: []const u8) void {
        if (start > self.pos) return;
        const old_columns = characterCount(self.buffer[0..self.len]);
        const tail_len = self.len - self.pos;
        const new_len = start + text.len + tail_len;
        if (new_len > self.buffer.len) return;
        const destination = self.buffer[start + text.len .. new_len];
        const remaining = self.buffer[self.pos..self.len];
        if (start + text.len > self.pos) {
            std.mem.copyBackwards(u8, destination, remaining);
        } else {
            std.mem.copyForwards(u8, destination, remaining);
        }
        @memcpy(self.buffer[start..][0..text.len], text);
        self.len = new_len;
        self.pos = start + text.len;
        self.redraw(start, old_columns -| characterCount(self.buffer[0..self.len]));
    }

    fn replace(self: *LineEditor, line: []const u8) void {
        const old_columns = characterCount(self.buffer[0..self.len]);
        self.len = @min(line.len, self.buffer.len);
        @memcpy(self.buffer[0..self.len], line[0..self.len]);
        self.pos = self.len;
        self.redraw(0, old_columns -| characterCount(self.buffer[0..self.len]));
    }
};

fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn characterCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (!isContinuation(byte)) count += 1;
    }
    return count;
}
