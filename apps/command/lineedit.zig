// Line input with editing and history. The cursor is placed directly,
// so wrapped lines work. Background output makes it redraw below.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const term = @import("term.zig");
const complete = @import("complete.zig");
const Scan = zdos.Scan;
const Position = zdos.Pos;

const history_size = 32;
const max_line = 1024;

var history: [history_size][max_line]u8 = undefined;
var history_len: [history_size]usize = undefined;
var history_count: usize = 0; // entries stored, up to history_size
var history_next: usize = 0; // slot the next entry goes to

// Set by the shell.
pub var reprompt: ?*const fn () void = null;

// UTF-8. With prompt: history and Tab completion. Ctrl+C gives an
// empty line and stops the command that asked.
pub fn read(buf: []u8, prompt: bool) []u8 {
    return readLine(buf, prompt, null);
}

// COPY CON: Ctrl+Z or F6 ends the whole input, as in DOS.
pub fn readText(buf: []u8, ended: *bool) []u8 {
    ended.* = false;
    return readLine(buf, false, ended);
}

fn readLine(buf: []u8, prompt: bool, ended: ?*bool) []u8 {
    // Typing is always shown, even while the output is redirected:
    const prev = term.toScreen();
    defer term.restore(prev);
    // Ctrl+C is a key here, so it ends the line; one pressed before is kept:
    _ = term.breakRequested();
    zdos.setCtrlC(true);
    defer sys.catchCtrlC(true);
    const remember = prompt;
    var e: Editor = .{
        .buf = buf[0..@min(buf.len, max_line)],
        .start = zdos.getCursor(),
        .width = @max(1, zdos.screenSize().col),
    };
    var draft: [max_line]u8 = undefined; // typed before browsing history
    var draft_len: usize = 0;
    var browse: usize = 0; // 0: the line typed, n: entry n
    defer zdos.editLine(null);

    while (true) {
        zdos.editLine(e.start.row);
        const key = zdos.readKey();
        if (key.scan == Scan.redraw) {
            // Another task wrote where the line was:
            // prompt and line again below:
            if (zdos.getCursor().col != 0) term.print("\n");
            if (prompt) if (reprompt) |p| p();
            e.start = zdos.getCursor();
            e.redraw(0, 0);
            continue;
        }
        if (ended) |end| {
            if (key.char == 0x1A or key.scan == Scan.f1 + 5) { // Ctrl+Z, F6
                e.moveTo(e.len);
                term.print("^Z\n");
                end.* = true;
                return e.buf[0..e.len];
            }
        }
        if (key.char == 3) { // Ctrl+C, as in DOS: "^C", the line is dropped
            e.moveTo(e.len);
            term.print("^C\n");
            term.interrupt();
            return e.buf[0..0];
        }
        switch (key.scan) {
            Scan.left => e.left(),
            Scan.right => e.right(),
            Scan.home => e.moveTo(0),
            Scan.end => e.moveTo(e.len),
            Scan.delete => e.deleteAt(),
            Scan.up => if (remember and browse < history_count) {
                if (browse == 0) {
                    draft_len = e.len;
                    @memcpy(draft[0..e.len], e.buf[0..e.len]);
                }
                browse += 1;
                e.replace(entry(browse));
            },
            Scan.down => if (remember and browse > 0) {
                browse -= 1;
                e.replace(if (browse == 0) draft[0..draft_len] else entry(browse));
            },
            else => switch (key.char) {
                '\r', '\n' => {
                    e.moveTo(e.len); // so the next output starts after the line
                    term.print("\n");
                    const line = e.buf[0..e.len];
                    if (remember) add(line);
                    return line;
                },
                0x08, 0x7f => e.backspace(), // some terminals send 0x7f
                '\t' => if (prompt) {
                    if (complete.complete(e.buf[0..e.pos])) |c| e.splice(c.start, c.text);
                },
                else => if (key.char >= 0x20) e.insert(key.char),
            },
        }
    }
}

// 1 = newest.
fn entry(n: usize) []const u8 {
    const slot = (history_next + history_size - n) % history_size;
    return history[slot][0..history_len[slot]];
}

fn add(line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return;
    if (history_count > 0 and std.mem.eql(u8, entry(1), line)) return; // no repeats in a row
    @memcpy(history[history_next][0..line.len], line);
    history_len[history_next] = line.len;
    history_next = (history_next + 1) % history_size;
    history_count = @min(history_count + 1, history_size);
}

const Editor = struct {
    buf: []u8,
    len: usize = 0, // bytes in the line
    pos: usize = 0, // cursor, as a byte offset
    start: Position, // screen position of the line's first character
    width: u32, // screen columns

    fn prevLen(self: *const Editor, at: usize) usize {
        var i = at - 1;
        while (i > 0 and isContinuation(self.buf[i])) i -= 1;
        return at - i;
    }

    fn nextLen(self: *const Editor, at: usize) usize {
        var i = at + 1;
        while (i < self.len and isContinuation(self.buf[i])) i += 1;
        return i - at;
    }

    fn screenPos(self: *const Editor, at: usize) Position {
        const cell = self.start.col + columns(self.buf[0..at]);
        return .{ .col = @intCast(cell % self.width), .row = self.start.row + @as(u32, @intCast(cell / self.width)) };
    }

    fn setCursor(pos: Position) void {
        zdos.setCursor(pos.col, pos.row);
    }

    fn moveTo(self: *Editor, at: usize) void {
        self.pos = at;
        setCursor(self.screenPos(at));
    }

    fn left(self: *Editor) void {
        if (self.pos > 0) self.moveTo(self.pos - self.prevLen(self.pos));
    }

    fn right(self: *Editor) void {
        if (self.pos < self.len) self.moveTo(self.pos + self.nextLen(self.pos));
    }

    // From byte offset from, then blanks where a longer line used to be;
    // the cursor goes back to pos.
    fn redraw(self: *Editor, from: usize, blanks: usize) void {
        setCursor(self.screenPos(from));
        term.print(self.buf[from..self.len]);
        term.spaces(blanks);
        const cells = self.start.col + columns(self.buf[0..self.len]) + blanks;
        // At the right edge a pty's terminal (TERM, SSH) wraps only with
        // the next character, as a VT does; the screen at once: there too
        if (cells > 0 and cells % self.width == 0 and zdos.getCursor().col != 0) term.print("\r\n");
        // Printing past the bottom row scrolls the line's start up too:
        const expected_row = self.start.row + @as(u32, @intCast(cells / self.width));
        const row = zdos.getCursor().row;
        if (row < expected_row) self.start.row -|= expected_row - row;
        setCursor(self.screenPos(self.pos));
    }

    fn insert(self: *Editor, c: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &tmp) catch return;
        if (self.len + n > self.buf.len) return;
        std.mem.copyBackwards(u8, self.buf[self.pos + n .. self.len + n], self.buf[self.pos..self.len]);
        @memcpy(self.buf[self.pos..][0..n], tmp[0..n]);
        self.len += n;
        const from = self.pos;
        self.pos += n;
        self.redraw(from, 0);
    }

    fn backspace(self: *Editor) void {
        if (self.pos == 0) return;
        self.pos -= self.prevLen(self.pos);
        self.deleteAt();
    }

    fn deleteAt(self: *Editor) void {
        if (self.pos == self.len) return;
        const n = self.nextLen(self.pos);
        std.mem.copyForwards(u8, self.buf[self.pos .. self.len - n], self.buf[self.pos + n .. self.len]);
        self.len -= n;
        self.redraw(self.pos, 1); // one column is now unused at the end
    }

    // From start up to the cursor; the cursor goes after it.
    fn splice(self: *Editor, start: usize, text: []const u8) void {
        const tail = self.len - self.pos;
        const new_len = start + text.len + tail;
        if (new_len > self.buf.len) return;
        const old_cols = columns(self.buf[0..self.len]);
        // The direction matters when the regions overlap:
        const dst = self.buf[start + text.len .. new_len];
        const src = self.buf[self.pos..self.len];
        if (start + text.len > self.pos) std.mem.copyBackwards(u8, dst, src) else std.mem.copyForwards(u8, dst, src);
        @memcpy(self.buf[start..][0..text.len], text);
        self.len = new_len;
        self.pos = start + text.len;
        self.redraw(start, old_cols -| columns(self.buf[0..self.len]));
    }

    // For the history; the cursor goes to the end.
    fn replace(self: *Editor, line: []const u8) void {
        const old_cols = columns(self.buf[0..self.len]);
        const n = @min(line.len, self.buf.len);
        @memcpy(self.buf[0..n], line[0..n]);
        self.len = n;
        self.pos = n;
        self.redraw(0, old_cols -| columns(self.buf[0..n]));
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

// One per character.
fn columns(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (!isContinuation(b)) n += 1;
    }
    return n;
}
