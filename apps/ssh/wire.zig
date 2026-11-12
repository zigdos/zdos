// SSH's data types (RFC 4251 section 5)
const std = @import("std");

pub const Error = error{ Malformed, TooLong };

pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn bytes(self: *Writer, b: []const u8) Error!void {
        if (self.buf.len - self.len < b.len) return error.TooLong;
        @memcpy(self.buf[self.len..][0..b.len], b);
        self.len += b.len;
    }

    pub fn byte(self: *Writer, v: u8) Error!void {
        return self.bytes(&[1]u8{v});
    }

    pub fn boolean(self: *Writer, v: bool) Error!void {
        return self.byte(@intFromBool(v));
    }

    pub fn int(self: *Writer, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        return self.bytes(&b);
    }

    pub fn string(self: *Writer, s: []const u8) Error!void {
        try self.int(@intCast(s.len));
        return self.bytes(s);
    }

    // Big-endian: no leading zeros, a zero byte first if the top bit is set.
    pub fn mpint(self: *Writer, magnitude: []const u8) Error!void {
        var m = magnitude;
        while (m.len > 0 and m[0] == 0) m = m[1..];
        const pad = m.len > 0 and m[0] & 0x80 != 0;
        try self.int(@intCast(m.len + @intFromBool(pad)));
        if (pad) try self.byte(0);
        return self.bytes(m);
    }

    pub fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.data.len - self.pos < n) return error.Malformed;
        const b = self.data[self.pos..][0..n];
        self.pos += n;
        return b;
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.bytes(1))[0];
    }

    pub fn boolean(self: *Reader) Error!bool {
        return try self.byte() != 0;
    }

    pub fn int(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.bytes(4))[0..4], .big);
    }

    pub fn string(self: *Reader) Error![]const u8 {
        const n = try self.int();
        return self.bytes(n);
    }

    // Without its sign byte.
    pub fn mpint(self: *Reader) Error![]const u8 {
        var m = try self.string();
        if (m.len > 0 and m[0] & 0x80 != 0) return error.Malformed; // negative
        while (m.len > 0 and m[0] == 0) m = m[1..];
        return m;
    }

    pub fn rest(self: *Reader) []const u8 {
        const r = self.data[self.pos..];
        self.pos = self.data.len;
        return r;
    }
};

// In a comma-separated name-list.
pub fn listHas(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn choose(client: []const u8, server: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, client, ',');
    while (it.next()) |n| {
        if (n.len > 0 and listHas(server, n)) return n;
    }
    return null;
}
