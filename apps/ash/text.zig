// Text files and stdin a line at a time, without "\n" or "\r\n".
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const errout = @import("errout.zig");

const Allocator = std.mem.Allocator;

pub const Reader = struct {
    file: ?zdos.File, // null: the standard input
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    newline: bool = false, // the last line read ended with a line end
    crlf: bool = false, // a line read so far ended with "\r\n"

    // "-" for the standard input.
    pub fn open(path: []const u8) zdos.Error!Reader {
        if (std.mem.eql(u8, path, "-")) return .{ .file = null };
        return .{ .file = try zdos.open(path, .read) };
    }

    pub fn stdin() Reader {
        return .{ .file = null };
    }

    pub fn close(self: *Reader) void {
        if (self.file) |f| f.close();
        self.file = null;
    }

    fn fill(self: *Reader) zdos.Error!bool {
        if (self.eof) return false;
        const n = if (self.file) |f|
            try f.read(&self.buf)
        else if (zdos.inputRedirected())
            zdos.readInput(&self.buf)
        else
            typedLine(&self.buf);
        self.start = 0;
        self.end = n;
        if (n == 0) self.eof = true;
        return n > 0;
    }

    pub fn peekByte(self: *Reader) zdos.Error!?u8 {
        if (self.start == self.end and !try self.fill()) return null;
        return self.buf[self.start];
    }

    pub fn readByte(self: *Reader) zdos.Error!?u8 {
        if (self.start == self.end and !try self.fill()) return null;
        const c = self.buf[self.start];
        self.start += 1;
        return c;
    }

    // Line ends included, valid until the next call; empty at the end.
    pub fn readChunk(self: *Reader) zdos.Error![]const u8 {
        if (self.start == self.end and !try self.fill()) return "";
        const chunk = self.buf[self.start..self.end];
        self.start = self.end;
        return chunk;
    }

    // Emptied first, without its line end; false at the end of the input.
    pub fn readLine(self: *Reader, a: Allocator, line: *std.ArrayListUnmanaged(u8)) (zdos.Error || Allocator.Error)!bool {
        line.clearRetainingCapacity();
        self.newline = false;
        var any = false;
        while (true) {
            if (self.start == self.end and !try self.fill()) break;
            any = true;
            const chunk = self.buf[self.start..self.end];
            if (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
                try line.appendSlice(a, chunk[0..nl]);
                self.start += nl + 1;
                self.newline = true;
                if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
                    line.items.len -= 1;
                    self.crlf = true;
                }
                return true;
            }
            try line.appendSlice(a, chunk);
            self.start = self.end;
        }
        if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') line.items.len -= 1;
        return any;
    }
};

// The keyboard: Ctrl+D (or Ctrl+Z) at the start of a line, or Ctrl+C,
// ends the input, as on Unix.
fn typedLine(buf: []u8) usize {
    var n: usize = 0;
    while (true) {
        const key = zdos.readKey();
        switch (key.char) {
            3 => return 0,
            4, 0x1a => return n, // mid-line: what is typed so far
            '\r', '\n' => {
                echo("\n");
                buf[n] = '\n';
                return n + 1;
            },
            0x08, 0x7f => if (n > 0) {
                n -= 1;
                while (n > 0 and buf[n] & 0xc0 == 0x80) n -= 1;
                echo("\x08 \x08");
            },
            else => if (key.char >= 0x20 and n + 5 < buf.len) {
                const len = std.unicode.utf8Encode(key.char, buf[n..][0..4]) catch continue;
                echo(buf[n .. n + len]);
                n += len;
            },
        }
    }
}

fn echo(s: []const u8) void {
    if (errout.output == sys.console or errout.output == sys.inherited and !zdos.outputRedirected()) {
        zdos.print(s);
        return;
    }
    sys.redirect(.output, sys.console) catch {};
    zdos.print(s);
    sys.redirect(.output, errout.output) catch {};
}

// Written in large pieces.
pub const Output = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},

    pub fn write(self: *Output, s: []const u8) void {
        self.buf.appendSlice(zdos.allocator, s) catch {
            self.flush();
            zdos.print(s);
            return;
        };
        if (self.buf.items.len >= 4096) self.flush();
    }

    pub fn flush(self: *Output) void {
        if (self.buf.items.len > 0) zdos.print(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn deinit(self: *Output) void {
        self.flush();
        self.buf.deinit(zdos.allocator);
    }
};
