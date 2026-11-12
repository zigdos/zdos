// Remote consoles (SSHD's sessions): a task's screen and
// keyboard as bytes for the holder of the other side. Output as
// written, "\n" as "\r\n"; cursor and color calls become VT100;
// keys are parsed from VT100 / xterm sequences.
const std = @import("std");
const platform = @import("../platform.zig");
const stdio = @import("stdio.zig");
const tasks = @import("tasks.zig");
const abi = @import("abi.zig");

const Key = platform.Key;
const Scan = platform.Scan;
const Position = platform.Position;

pub const Term = struct {
    output: *stdio.Channel, // read by the holder (readers), written by the tasks (writers)
    holders: u32 = 1, // handles of the other side
    attached: u32 = 0, // tasks using it as their console
    hung_up: bool = false, // no holder left
    cols: u32,
    rows: u32,
    // Where the cursor is, as the output moved it (getCursor)
    col: u32 = 0,
    row: u32 = 0,
    wrap_pending: bool = false, // written into the last column: the next character wraps
    saved: Position = .{ .col = 0, .row = 0 },
    esc: enum { text, esc, csi } = .text,
    params: [4]u32 = .{ 0, 0, 0, 0 },
    count: usize = 0,
    // Typed, not yet parsed into keys
    in_buf: [1024]u8 = undefined,
    in_len: usize = 0,
    esc_since: u64 = 0, // a lone ESC waits briefly for the rest of a sequence
    // Parsed keys not yet read (keyWaiting, breakRequested)
    keys: [32]Key = undefined,
    keys_start: usize = 0,
    keys_len: usize = 0,

    // THE OTHER SIDE: ITS HANDLE

    pub fn create(cols: u32, rows: u32) ?*Term {
        const out = stdio.Channel.create() orelse return null;
        const mem = platform.memory.alloc(@sizeOf(Term)) orelse {
            platform.memory.free(@ptrCast(@alignCast(out)));
            return null;
        };
        const t: *Term = @ptrCast(@alignCast(mem));
        out.readers = 1;
        t.* = .{ .output = out, .cols = clampCols(cols), .rows = clampRows(rows) };
        return t;
    }

    pub fn resize(self: *Term, cols: u32, rows: u32) void {
        self.cols = clampCols(cols);
        self.rows = clampRows(rows);
        self.col = @min(self.col, self.cols - 1);
        self.row = @min(self.row, self.rows - 1);
        self.signalAll(abi.Signal.winch);
    }

    // Keys typed at the other end
    pub fn input(self: *Term, data: []const u8) usize {
        const n = @min(data.len, self.in_buf.len - self.in_len);
        @memcpy(self.in_buf[self.in_len..][0..n], data[0..n]);
        self.in_len += n;
        tasks.wake(self);
        return n;
    }

    pub fn retainHolder(self: *Term) void {
        self.holders += 1;
        self.output.readers += 1;
    }

    // The last holder gone: the tasks get SIGHUP, their output is dropped
    pub fn releaseHolder(self: *Term) void {
        self.holders -= 1;
        if (self.holders == 0) {
            self.hung_up = true;
            self.signalAll(abi.Signal.hup);
            tasks.wake(self);
        }
        self.output.closeReader();
        self.freeIfUnused();
    }

    // THE TASKS USING IT

    pub fn attach(self: *Term) void {
        self.attached += 1;
        self.output.writers += 1;
    }

    // The last task gone: the holder reads the end
    pub fn detach(self: *Term) void {
        self.attached -= 1;
        self.output.closeWriter();
        self.freeIfUnused();
    }

    fn freeIfUnused(self: *Term) void {
        if (self.holders == 0 and self.attached == 0) platform.memory.free(@ptrCast(@alignCast(self)));
    }

    fn signalAll(self: *Term, sig: u32) void {
        for (&tasks.tasks) |*x| {
            if (x.state != .free and x.state != .zombie and x.term == self) tasks.kill(x.id, sig) catch {};
        }
    }

    fn send(self: *Term, bytes: []const u8) void {
        if (self.hung_up) return;
        _ = self.output.write(bytes) catch 0;
    }

    pub fn write(self: *Term, text: []const u8) void {
        var start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                self.send(text[start..i]);
                self.send("\r\n");
                start = i + 1;
            }
            self.track(c);
        }
        self.send(text[start..]);
    }

    // The cursor as the terminal moves it for c
    fn track(self: *Term, c: u8) void {
        switch (self.esc) {
            .esc => {
                self.esc = .text;
                switch (c) {
                    '[' => {
                        self.esc = .csi;
                        self.params = .{ 0, 0, 0, 0 };
                        self.count = 0;
                    },
                    '7' => self.saved = .{ .col = self.col, .row = self.row },
                    '8' => self.moveTo(self.saved.col, self.saved.row),
                    'c' => self.moveTo(0, 0),
                    else => {},
                }
                return;
            },
            .csi => {
                switch (c) {
                    '0'...'9' => {
                        if (self.count == 0) self.count = 1;
                        const p = &self.params[@min(self.count - 1, 3)];
                        p.* = p.* *| 10 +| (c - '0');
                    },
                    ';' => {
                        if (self.count == 0) self.count = 1;
                        self.count = @min(self.count + 1, 4);
                    },
                    0x40...0x7E => {
                        self.esc = .text;
                        self.csiDone(c);
                    },
                    else => {},
                }
                return;
            },
            .text => {},
        }
        switch (c) {
            0x1B => self.esc = .esc,
            '\r' => self.moveTo(0, self.row),
            '\n' => {
                self.wrap_pending = false;
                self.col = 0;
                if (self.row + 1 < self.rows) self.row += 1;
            },
            8 => if (self.col > 0) self.moveTo(self.col - 1, self.row),
            '\t' => self.moveTo(@min((self.col / 8 + 1) * 8, self.cols - 1), self.row),
            0...7, 0x0B, 0x0C, 0x0E...0x1A, 0x1C...0x1F, 0x7F => {},
            0x80...0xBF => {}, // a character's continuation bytes
            else => {
                if (self.wrap_pending) {
                    self.wrap_pending = false;
                    self.col = 0;
                    if (self.row + 1 < self.rows) self.row += 1;
                }
                if (self.col + 1 >= self.cols) self.wrap_pending = true else self.col += 1;
            },
        }
    }

    fn param(self: *const Term, i: usize, default: u32) u32 {
        if (i >= self.count or self.params[i] == 0) return default;
        return self.params[i];
    }

    fn csiDone(self: *Term, final: u8) void {
        const n = self.param(0, 1);
        switch (final) {
            'H', 'f' => self.moveTo(self.param(1, 1) - 1, self.param(0, 1) - 1),
            'A' => self.moveTo(self.col, self.row -| n),
            'B' => self.moveTo(self.col, self.row + n),
            'C' => self.moveTo(self.col + n, self.row),
            'D' => self.moveTo(self.col -| n, self.row),
            'G' => self.moveTo(n - 1, self.row),
            'd' => self.moveTo(self.col, n - 1),
            's' => self.saved = .{ .col = self.col, .row = self.row },
            'u' => self.moveTo(self.saved.col, self.saved.row),
            else => {},
        }
    }

    fn moveTo(self: *Term, col: u32, row: u32) void {
        self.wrap_pending = false;
        self.col = @min(col, self.cols - 1);
        self.row = @min(row, self.rows - 1);
    }

    pub fn clear(self: *Term) void {
        self.send("\x1b[0m\x1b[2J\x1b[H");
        self.moveTo(0, 0);
    }

    pub fn setCursor(self: *Term, pos: Position) void {
        var buf: [24]u8 = undefined;
        self.send(std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ pos.row + 1, pos.col + 1 }) catch return);
        self.moveTo(pos.col, pos.row);
    }

    pub fn getCursor(self: *const Term) Position {
        return .{ .col = self.col, .row = self.row };
    }

    pub fn size(self: *const Term) Position {
        return .{ .col = self.cols, .row = self.rows };
    }

    // VGA color numbers as ANSI's
    pub fn setColor(self: *Term, fg: u8, bg: u8) void {
        const ansi_of = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };
        const f = fg & 0x0F;
        var buf: [24]u8 = undefined;
        const fg_code: u32 = @as(u32, ansi_of[f & 7]) + @as(u32, if (f >= 8) 90 else 30);
        self.send(std.fmt.bufPrint(&buf, "\x1b[0;{d};{d}m", .{ fg_code, @as(u32, ansi_of[bg & 7]) + 40 }) catch return);
    }

    pub fn showCursor(self: *Term, visible: bool) void {
        self.send(if (visible) "\x1b[?25h" else "\x1b[?25l");
    }

    pub fn push(self: *Term, k: Key) void {
        if (self.keys_len == self.keys.len) return;
        self.keys[(self.keys_start + self.keys_len) % self.keys.len] = k;
        self.keys_len += 1;
    }

    pub fn pop(self: *Term) ?Key {
        if (self.keys_len == 0) return null;
        const k = self.keys[self.keys_start];
        self.keys_start = (self.keys_start + 1) % self.keys.len;
        self.keys_len -= 1;
        return k;
    }

    // The next key typed, if a whole one is there
    pub fn parseKey(self: *Term) ?Key {
        if (self.in_len == 0) return null;
        const b = self.in_buf[0..self.in_len];
        if (b[0] == 0x1B) {
            if (b.len == 1) {
                // ESC alone, unless more comes soon
                const now = platform.clock.millis();
                if (self.esc_since == 0) self.esc_since = now;
                if (now - self.esc_since < 50) return null;
                self.esc_since = 0;
                self.take(1);
                return .{ .char = 0, .scan = Scan.esc };
            }
            self.esc_since = 0;
            if (escapeKey(b)) |r| {
                if (r.len == 0) return null; // not complete yet
                self.take(r.len);
                return r.key;
            }
            self.take(1);
            return .{ .char = 0, .scan = Scan.esc };
        }
        // UTF-8: one character
        const len = std.unicode.utf8ByteSequenceLength(b[0]) catch {
            self.take(1);
            return .{ .char = b[0], .scan = 0 };
        };
        if (b.len < len) return null;
        const cp = std.unicode.utf8Decode(b[0..len]) catch {
            self.take(len);
            return null;
        };
        self.take(len);
        return switch (cp) {
            0x7F => .{ .char = 8, .scan = 0 }, // Backspace sends DEL
            '\n' => .{ .char = '\r', .scan = 0 },
            else => .{ .char = cp, .scan = 0 },
        };
    }

    fn take(self: *Term, n: usize) void {
        std.mem.copyForwards(u8, self.in_buf[0 .. self.in_len - n], self.in_buf[n..self.in_len]);
        self.in_len -= n;
    }

    // Waits for a key; after a hang-up, Ctrl+C now and then (SIGHUP
    // ends the program unless it ignores it)
    pub fn waitKey(self: *Term) Key {
        while (true) {
            if (self.parseKey()) |k| return k;
            if (self.hung_up) {
                _ = tasks.sleep(100);
                return .{ .char = 3, .scan = 0 };
            }
            tasks.handleSignals();
            _ = tasks.waitObject(self, if (self.esc_since != 0) 20 else 500);
        }
    }
};

fn clampCols(c: u32) u32 {
    return std.math.clamp(c, 20, 500);
}

fn clampRows(r: u32) u32 {
    return std.math.clamp(r, 5, 300);
}

const Parsed = struct { key: Key, len: usize };

// An escape sequence at the start of b (b[0] is ESC): its key,
// len 0 if incomplete; null if it isn't one of the keys
fn escapeKey(b: []const u8) ?Parsed {
    const k = struct {
        fn scan(s: u16, n: usize) Parsed {
            return .{ .key = .{ .char = 0, .scan = s }, .len = n };
        }
    };
    const incomplete: Parsed = .{ .key = .{ .char = 0, .scan = 0 }, .len = 0 };
    if (b.len < 2) return incomplete;
    if (b[1] == 'O') {
        if (b.len < 3) return incomplete;
        return switch (b[2]) {
            'A' => k.scan(Scan.up, 3),
            'B' => k.scan(Scan.down, 3),
            'C' => k.scan(Scan.right, 3),
            'D' => k.scan(Scan.left, 3),
            'H' => k.scan(Scan.home, 3),
            'F' => k.scan(Scan.end, 3),
            'P'...'S' => k.scan(@intCast(Scan.f1 + (b[2] - 'P')), 3),
            else => null,
        };
    }
    if (b[1] != '[') {
        // Alt+key: the key with Alt
        if (b[1] < 0x20 or b[1] >= 0x7F) return null;
        return .{ .key = .{ .char = b[1], .scan = 0, .mods = platform.Mod.left_alt }, .len = 2 };
    }
    // CSI: digits and ';', then the final byte
    var i: usize = 2;
    var first: u32 = 0;
    var mod_param: u32 = 0;
    var which: usize = 0;
    while (i < b.len) : (i += 1) {
        const c = b[i];
        switch (c) {
            '0'...'9' => {
                if (which == 0) first = first *| 10 +| (c - '0') else if (which == 1) mod_param = mod_param *| 10 +| (c - '0');
            },
            ';' => which += 1,
            '<'...'?' => {},
            0x40...0x7E => {
                const mods = modsOf(mod_param);
                const n = i + 1;
                var r: ?Parsed = switch (c) {
                    'A' => k.scan(Scan.up, n),
                    'B' => k.scan(Scan.down, n),
                    'C' => k.scan(Scan.right, n),
                    'D' => k.scan(Scan.left, n),
                    'H' => k.scan(Scan.home, n),
                    'F' => k.scan(Scan.end, n),
                    'Z' => .{ .key = .{ .char = '\t', .scan = 0, .mods = platform.Mod.left_shift }, .len = n },
                    '~' => switch (first) {
                        1, 7 => k.scan(Scan.home, n),
                        2 => k.scan(Scan.insert, n),
                        3 => k.scan(Scan.delete, n),
                        4, 8 => k.scan(Scan.end, n),
                        5 => k.scan(Scan.page_up, n),
                        6 => k.scan(Scan.page_down, n),
                        11...15 => k.scan(@intCast(Scan.f1 + (first - 11)), n),
                        17...21 => k.scan(@intCast(Scan.f1 + 5 + (first - 17)), n),
                        23 => k.scan(Scan.f11, n),
                        24 => k.scan(Scan.f12, n),
                        else => .{ .key = .{ .char = 0, .scan = 0 }, .len = n }, // unknown: dropped
                    },
                    else => .{ .key = .{ .char = 0, .scan = 0 }, .len = n },
                };
                if (r) |*p| p.key.mods |= mods;
                return r;
            },
            else => return .{ .key = .{ .char = 0, .scan = 0 }, .len = i + 1 },
        }
    }
    return incomplete;
}

// xterm's modifier parameter: 1 + shift (1), alt (2), ctrl (4)
fn modsOf(p: u32) u16 {
    if (p < 2) return 0;
    const bits = p - 1;
    var m: u16 = 0;
    if (bits & 1 != 0) m |= platform.Mod.left_shift;
    if (bits & 2 != 0) m |= platform.Mod.left_alt;
    if (bits & 4 != 0) m |= platform.Mod.left_ctrl;
    return m;
}
