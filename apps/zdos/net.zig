// The network for Zig programs (group net). Sockets are handles:
// zdos.File's read and write work on them too.
const std = @import("std");
const abi = @import("abi");
const zdos = @import("zdos.zig");

const Error = zdos.Error;
const check = zdos.check;

pub const Address = abi.NetAddress;
pub const Info = abi.NetInfo;
pub const Flags = abi.NetFlags;
pub const PingReply = abi.PingReply;
pub const PingResult = abi.PingResult;
pub const ArpEntry = abi.ArpEntry;
pub const Route = abi.NetRoute;
pub const Via = abi.NetVia;
pub const RouteFlags = abi.RouteFlags;
pub const Connection = abi.Connection;
pub const TcpState = abi.TcpState;
pub const SocketType = abi.SocketType;
pub const SocketFlags = abi.SocketFlags;
pub const SocketOption = abi.SocketOption;

fn api() *const abi.NetApi {
    return zdos.table().net;
}

pub fn info() Info {
    var i: Info = .{ .flags = 0 };
    api().info(&i);
    return i;
}

// Null past the last.
pub fn interface(index: u32) ?Info {
    var i: Info = .{ .flags = 0 };
    return if (api().interface(index, &i)) i else null;
}

// Null past the last.
pub fn route(index: u32) ?Route {
    var r: Route = .{};
    return if (api().route(index, &r)) r else null;
}

pub fn renew(timeout_ms: u32) Error!void {
    return check(api().renew(timeout_ms));
}

pub fn release() Error!void {
    return check(api().release());
}

pub fn resolve(name: []const u8) Error![4]u8 {
    var a: [4]u8 = undefined;
    try check(api().resolve(name.ptr, name.len, &a));
    return a;
}

pub fn ping(addr: [4]u8, seq: u16, size: u16, ttl: u8, timeout_ms: u32) Error!PingReply {
    var r: PingReply = undefined;
    try check(api().ping(&addr, seq, size, ttl, timeout_ms, &r));
    return r;
}

// Null past the last.
pub fn arpEntry(index: u32) ?ArpEntry {
    var e: ArpEntry = undefined;
    return if (api().arp_entry(index, &e)) e else null;
}

pub fn arpAdd(addr: [4]u8, mac: [6]u8) Error!void {
    return check(api().arp_add(&addr, &mac));
}

// Null: every entry.
pub fn arpRemove(addr: ?[4]u8) Error!void {
    return check(api().arp_remove(if (addr) |*a| a else null));
}

pub fn connection(index: u32) ?Connection {
    var c: Connection = undefined;
    return if (api().connection(index, &c)) c else null;
}

// "192.168.0.1"; null if it isn't one.
pub fn parseAddress(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

pub fn addressText(a: [4]u8, buf: *[16]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch unreachable;
}

// "00-11-22-33-44-55"
pub fn macText(m: [6]u8, buf: *[18]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}", .{ m[0], m[1], m[2], m[3], m[4], m[5] }) catch unreachable;
}

// With '-' or ':'; null if it isn't one.
pub fn parseMac(text: []const u8) ?[6]u8 {
    var out: [6]u8 = undefined;
    var it = std.mem.splitAny(u8, text, "-:");
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 6 or part.len == 0 or part.len > 2) return null;
        out[i] = std.fmt.parseInt(u8, part, 16) catch return null;
    }
    return if (i == 6) out else null;
}

pub const Socket = struct {
    handle: i32,

    pub fn open(kind: u32) Error!Socket {
        const h = api().socket(kind);
        if (h < 0) return zdos.lastError();
        return .{ .handle = h };
    }

    // To a name or an address.
    pub fn connectTo(name: []const u8, port: u16) Error!Socket {
        const addr = try resolve(name);
        const s = try open(SocketType.stream);
        errdefer s.close();
        try s.connect(.{ .addr = addr, .port = port });
        return s;
    }

    pub fn close(self: Socket) void {
        zdos.table().files.close(self.handle);
    }

    pub fn connect(self: Socket, addr: Address) Error!void {
        return check(api().connect(self.handle, &addr));
    }

    pub fn bind(self: Socket, addr: Address) Error!void {
        return check(api().bind(self.handle, &addr));
    }

    pub fn listen(self: Socket, backlog: u32) Error!void {
        return check(api().listen(self.handle, backlog));
    }

    pub fn accept(self: Socket, peer: ?*Address) Error!Socket {
        const h = api().accept(self.handle, peer);
        if (h < 0) return zdos.lastError();
        return .{ .handle = h };
    }

    pub fn send(self: Socket, data: []const u8) Error!usize {
        const n = api().send(self.handle, data.ptr, data.len, 0);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    pub fn sendAll(self: Socket, data: []const u8) Error!void {
        var done: usize = 0;
        while (done < data.len) done += try self.send(data[done..]);
    }

    // 0: the peer closed.
    pub fn recv(self: Socket, buf: []u8) Error!usize {
        const n = api().recv(self.handle, buf.ptr, buf.len, 0);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    pub fn sendTo(self: Socket, data: []const u8, to: Address) Error!usize {
        const n = api().send_to(self.handle, data.ptr, data.len, 0, &to);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    pub fn recvFrom(self: Socket, buf: []u8, from: ?*Address) Error!usize {
        const n = api().recv_from(self.handle, buf.ptr, buf.len, 0, from);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    // With the interface and local address (abi.NetVia).
    pub fn sendVia(self: Socket, data: []const u8, to: Address, via: Via) Error!usize {
        const n = api().send_via(self.handle, data.ptr, data.len, 0, &to, &via);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    pub fn recvVia(self: Socket, buf: []u8, flags: u32, from: ?*Address, via: ?*Via) Error!usize {
        const n = api().recv_via(self.handle, buf.ptr, buf.len, flags, from, via);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    pub fn setOption(self: Socket, option: u32, value: u32) Error!void {
        return check(api().set_option(self.handle, option, value));
    }

    pub fn address(self: Socket, peer: bool) Error!Address {
        var a: Address = .{};
        try check(api().address(self.handle, peer, &a));
        return a;
    }
};
