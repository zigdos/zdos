// NETTEST [HOST]: tests the network against tests/net/net-tests.py.
// Results to NETTEST.LOG on the drive labelled NETLOG. Exit code:
// failures. Ports: TCP echo 5555, UDP echo 5556, 5557 closed, HTTP
// 8000, HTTPS 8443 (TLS 1.3), 8444 (TLS 1.2), 8445 (TLS 1.2, RSA);
// it listens on 8080; to itself on 5600 (5609 closed).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

var log: ?zdos.File = null;
var passed: u32 = 0;
var failed: u32 = 0;
var line_buf: [512]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&line_buf, fmt, args) catch return;
    zdos.print(text);
    if (log) |f| f.writeAll(text) catch {};
}

fn check(ok: bool, comptime what: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (ok) passed += 1 else failed += 1;
    var detail: [256]u8 = undefined;
    const d = std.fmt.bufPrint(&detail, fmt, args) catch "";
    if (ok) {
        say("ok - " ++ what ++ "\n", .{});
    } else {
        say("not ok - " ++ what ++ " ({s})\n", .{d});
    }
}

fn errText(err: anyerror) []const u8 {
    return @errorName(err);
}

fn findLogDrive() ?u8 {
    var i: u32 = 0;
    while (system.driveAt(i)) |d| : (i += 1) {
        if (std.ascii.eqlIgnoreCase(d.label(), "NETLOG")) return d.letter;
    }
    return null;
}

const echo_port = 5555;
const udp_port = 5556;
const closed_port = 5557;
const http_port = 8000;
const listen_port = 8080;

pub fn main(args: []const u8) u8 {
    const host_text = std.mem.trim(u8, args, " \t");
    const host = net.parseAddress(if (host_text.len > 0) host_text else "10.0.2.2") orelse {
        zdos.print("NETTEST [HOST ADDRESS]\n");
        return 1;
    };
    var letter: u8 = 0;
    if (findLogDrive()) |l| {
        letter = l;
        var path = "X:\\NETTEST.LOG".*;
        path[0] = l;
        log = zdos.open(&path, .write) catch null;
        const v = [2]u8{ l, ':' };
        zdos.setVar("NETLOG", &v) catch {};
    }
    defer if (log) |f| f.close();
    say("# NETTEST\n", .{});

    interface();
    names();
    pingHost(host);
    tcpEcho(host);
    tcpBulk(host);
    tcpRefused(host);
    udpEcho(host);
    nonblockingConnect(host);
    httpGet(host);
    loopback(.{ 127, 0, 0, 1 }, "loopback");
    loopback(net.info().address, "own address");
    listening();
    arpTable(host);
    if (letter != 0) tools(letter);

    say("# NETTEST: {d} passed, {d} failed\n", .{ passed, failed });
    return @intCast(@min(failed, 255));
}

fn interface() void {
    var i = net.info();
    check(i.flags & net.Flags.started != 0, "network started", "flags {d}", .{i.flags});
    // DHCP may still be asking:
    const began = zdos.millis();
    while (i.flags & net.Flags.dhcp_bound == 0 and zdos.millis() - began < 15_000) {
        zdos.sleep(250);
        i = net.info();
    }
    check(i.flags & net.Flags.dhcp_bound != 0, "DHCP address", "flags {d}", .{i.flags});
    check(i.flags & net.Flags.link != 0, "link up", "flags {d}", .{i.flags});
    check(std.mem.eql(u8, &i.address, &[4]u8{ 10, 0, 2, 15 }), "address 10.0.2.15", "{any}", .{i.address});
    check(std.mem.eql(u8, &i.gateway, &[4]u8{ 10, 0, 2, 2 }), "router 10.0.2.2", "{any}", .{i.gateway});
    check(std.mem.eql(u8, &i.dns[0], &[4]u8{ 10, 0, 2, 3 }), "DNS server 10.0.2.3", "{any}", .{i.dns[0]});
    check(i.card_len > 0, "card name", "{s}", .{i.card()});
}

fn names() void {
    if (net.resolve("10.1.2.3")) |a| {
        check(std.mem.eql(u8, &a, &[4]u8{ 10, 1, 2, 3 }), "resolve a written address", "{any}", .{a});
    } else |err| check(false, "resolve a written address", "{s}", .{errText(err)});
    if (net.resolve("localhost")) |a| {
        check(std.mem.eql(u8, &a, &[4]u8{ 127, 0, 0, 1 }), "resolve localhost", "{any}", .{a});
    } else |err| check(false, "resolve localhost", "{s}", .{errText(err)});
    if (net.resolve("no-such-host.invalid")) |a| {
        check(false, "unknown name fails", "got {any}", .{a});
    } else |err| check(err == error.HostNotFound, "unknown name fails", "{s}", .{errText(err)});
}

fn pingHost(host: [4]u8) void {
    if (net.ping(host, 1, 32, 64, 3000)) |r| {
        check(r.result == net.PingResult.reply, "ping the host", "result {d}", .{r.result});
    } else |err| check(false, "ping the host", "{s}", .{errText(err)});
}

fn connectTo(host: [4]u8, port: u16) !net.Socket {
    const s = try net.Socket.open(net.SocketType.stream);
    errdefer s.close();
    try s.connect(.{ .addr = host, .port = port });
    return s;
}

fn recvExactly(s: net.Socket, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try s.recv(buf[got..]);
        if (n == 0) return error.ConnectionAborted;
        got += n;
    }
}

fn tcpEcho(host: [4]u8) void {
    const s = connectTo(host, echo_port) catch |err| return check(false, "TCP connect", "{s}", .{errText(err)});
    defer s.close();
    check(true, "TCP connect", "", .{});
    s.sendAll("hello, echo") catch |err| return check(false, "TCP echo", "send: {s}", .{errText(err)});
    var buf: [11]u8 = undefined;
    recvExactly(s, &buf) catch |err| return check(false, "TCP echo", "recv: {s}", .{errText(err)});
    check(std.mem.eql(u8, &buf, "hello, echo"), "TCP echo", "{s}", .{&buf});
    // The same through files.read / write:
    const f: zdos.File = .{ .handle = s.handle };
    f.writeAll("by file") catch |err| return check(false, "socket as a file", "write: {s}", .{errText(err)});
    var fb: [7]u8 = undefined;
    var got: usize = 0;
    while (got < fb.len) {
        const n = f.read(fb[got..]) catch |err| return check(false, "socket as a file", "read: {s}", .{errText(err)});
        if (n == 0) break;
        got += n;
    }
    check(got == 7 and std.mem.eql(u8, &fb, "by file"), "socket as a file", "{d} bytes", .{got});
    const local = s.address(false) catch net.Address{};
    check(std.mem.eql(u8, &local.addr, &[4]u8{ 10, 0, 2, 15 }) and local.port != 0, "local address", "{any}:{d}", .{ local.addr, local.port });
}

// 1 MiB in 16 KiB pieces, each read back before the next:
var bulk_out: [16 * 1024]u8 = undefined;
var bulk_in: [16 * 1024]u8 = undefined;

fn tcpBulk(host: [4]u8) void {
    const s = connectTo(host, echo_port) catch |err| return check(false, "TCP 1 MiB", "connect: {s}", .{errText(err)});
    defer s.close();
    const began = zdos.millis();
    var piece: u32 = 0;
    while (piece < 64) : (piece += 1) {
        for (&bulk_out, 0..) |*b, i| b.* = @truncate(i * 7 + piece * 13);
        s.sendAll(&bulk_out) catch |err| return check(false, "TCP 1 MiB", "send {d}: {s}", .{ piece, errText(err) });
        recvExactly(s, &bulk_in) catch |err| return check(false, "TCP 1 MiB", "recv {d}: {s}", .{ piece, errText(err) });
        if (!std.mem.eql(u8, &bulk_in, &bulk_out)) return check(false, "TCP 1 MiB", "piece {d} differs", .{piece});
    }
    const ms = zdos.millis() - began;
    check(true, "TCP 1 MiB", "", .{});
    say("# 1 MiB there and back in {d} ms\n", .{ms});
}

fn tcpRefused(host: [4]u8) void {
    if (connectTo(host, closed_port)) |s| {
        s.close();
        check(false, "closed port refused", "connected", .{});
    } else |err| check(err == error.ConnectionRefused or err == error.ConnectionReset, "closed port refused", "{s}", .{errText(err)});
}

fn udpEcho(host: [4]u8) void {
    const s = net.Socket.open(net.SocketType.datagram) catch |err| return check(false, "UDP echo", "socket: {s}", .{errText(err)});
    defer s.close();
    s.setOption(net.SocketOption.recv_timeout, 3000) catch {};
    const to: net.Address = .{ .addr = host, .port = udp_port };
    const api = zdos.table().net;
    if (api.send_to(s.handle, "udp hello", 9, 0, &to) != 9) return check(false, "UDP echo", "send: {s}", .{errText(zdos.lastError())});
    var buf: [64]u8 = undefined;
    var from: net.Address = .{};
    const n = api.recv_from(s.handle, &buf, buf.len, 0, &from);
    if (n < 0) return check(false, "UDP echo", "recv: {s}", .{errText(zdos.lastError())});
    const len: usize = @intCast(n);
    check(std.mem.eql(u8, buf[0..len], "udp hello") and from.port == udp_port, "UDP echo", "{s} from port {d}", .{ buf[0..len], from.port });
}

fn nonblockingConnect(host: [4]u8) void {
    const s = net.Socket.open(net.SocketType.stream) catch |err| return check(false, "nonblocking connect", "socket: {s}", .{errText(err)});
    defer s.close();
    s.setOption(net.SocketOption.nonblocking, 1) catch {};
    if (s.connect(.{ .addr = host, .port = echo_port })) {
        check(true, "nonblocking connect", "", .{}); // done at once: fine too
        return;
    } else |err| {
        if (err != error.InProgress) return check(false, "nonblocking connect", "{s}", .{errText(err)});
    }
    var fds = [1]zdos.PollFd{.{ .handle = s.handle, .events = zdos.Poll.out }};
    const ready = zdos.table().files.poll(&fds, 1, 5000);
    var pending: u32 = 99;
    _ = zdos.table().net.get_option(s.handle, net.SocketOption.pending_error, &pending);
    check(ready == 1 and fds[0].revents & zdos.Poll.out != 0 and pending == 0, "nonblocking connect", "ready {d}, revents {d}, error {d}", .{ ready, fds[0].revents, pending });
    // Nothing to read yet: would block:
    var b: [4]u8 = undefined;
    if (s.recv(&b)) |n| {
        check(false, "nonblocking recv", "got {d}", .{n});
    } else |err| check(err == error.WouldBlock, "nonblocking recv", "{s}", .{errText(err)});
}

var http_buf: [4096]u8 = undefined;

fn httpGet(host: [4]u8) void {
    const s = connectTo(host, http_port) catch |err| return check(false, "HTTP GET", "connect: {s}", .{errText(err)});
    defer s.close();
    s.sendAll("GET /hello.txt HTTP/1.0\r\nHost: test\r\n\r\n") catch |err| return check(false, "HTTP GET", "send: {s}", .{errText(err)});
    var len: usize = 0;
    while (len < http_buf.len) {
        const n = s.recv(http_buf[len..]) catch |err| return check(false, "HTTP GET", "recv: {s}", .{errText(err)});
        if (n == 0) break;
        len += n;
    }
    const text = http_buf[0..len];
    check(std.mem.startsWith(u8, text, "HTTP/1.") and std.mem.indexOf(u8, text, "Hello from the host") != null, "HTTP GET", "{d} bytes", .{len});
}

// ZDOS to itself, one task: small pieces, each read before the next.
var loop_out: [4096]u8 = undefined;
var loop_in: [4096]u8 = undefined;

fn loopback(to: [4]u8, comptime what: []const u8) void {
    const l = net.Socket.open(net.SocketType.stream) catch |err| return check(false, what ++ " TCP", "socket: {s}", .{errText(err)});
    defer l.close();
    l.setOption(net.SocketOption.reuse_address, 1) catch {};
    l.bind(.{ .port = 5600 }) catch |err| return check(false, what ++ " TCP", "bind: {s}", .{errText(err)});
    l.listen(2) catch |err| return check(false, what ++ " TCP", "listen: {s}", .{errText(err)});
    const c = connectTo(to, 5600) catch |err| return check(false, what ++ " TCP", "connect: {s}", .{errText(err)});
    defer c.close();
    l.setOption(net.SocketOption.recv_timeout, 3000) catch {};
    const a = l.accept(null) catch |err| return check(false, what ++ " TCP", "accept: {s}", .{errText(err)});
    defer a.close();
    a.setOption(net.SocketOption.recv_timeout, 3000) catch {};
    c.setOption(net.SocketOption.recv_timeout, 3000) catch {};
    var piece: u32 = 0;
    while (piece < 64) : (piece += 1) { // 256 KiB each way
        for (&loop_out, 0..) |*b, i| b.* = @truncate(i * 3 + piece * 11);
        c.sendAll(&loop_out) catch |err| return check(false, what ++ " TCP", "send {d}: {s}", .{ piece, errText(err) });
        recvExactly(a, &loop_in) catch |err| return check(false, what ++ " TCP", "recv {d}: {s}", .{ piece, errText(err) });
        a.sendAll(&loop_in) catch |err| return check(false, what ++ " TCP", "back {d}: {s}", .{ piece, errText(err) });
        recvExactly(c, &loop_in) catch |err| return check(false, what ++ " TCP", "back recv {d}: {s}", .{ piece, errText(err) });
        if (!std.mem.eql(u8, &loop_in, &loop_out)) return check(false, what ++ " TCP", "piece {d} differs", .{piece});
    }
    check(true, what ++ " TCP", "", .{});

    if (connectTo(to, 5609)) |s| {
        s.close();
        check(false, what ++ " closed port refused", "connected", .{});
    } else |err| check(err == error.ConnectionRefused or err == error.ConnectionReset, what ++ " closed port refused", "{s}", .{errText(err)});

    const u = net.Socket.open(net.SocketType.datagram) catch |err| return check(false, what ++ " UDP", "socket: {s}", .{errText(err)});
    defer u.close();
    u.bind(.{ .port = 5600 }) catch |err| return check(false, what ++ " UDP", "bind: {s}", .{errText(err)});
    u.setOption(net.SocketOption.recv_timeout, 3000) catch {};
    _ = u.sendTo("to myself", .{ .addr = to, .port = 5600 }) catch |err| return check(false, what ++ " UDP", "send: {s}", .{errText(err)});
    var buf: [32]u8 = undefined;
    const n = u.recvFrom(&buf, null) catch |err| return check(false, what ++ " UDP", "recv: {s}", .{errText(err)});
    check(std.mem.eql(u8, buf[0..n], "to myself"), what ++ " UDP", "{s}", .{buf[0..n]});
}

fn listening() void {
    const l = net.Socket.open(net.SocketType.stream) catch |err| return check(false, "listen", "socket: {s}", .{errText(err)});
    defer l.close();
    l.setOption(net.SocketOption.reuse_address, 1) catch {};
    l.bind(.{ .port = listen_port }) catch |err| return check(false, "listen", "bind: {s}", .{errText(err)});
    l.listen(4) catch |err| return check(false, "listen", "listen: {s}", .{errText(err)});
    check(true, "listen", "", .{});
    // NETSTAT's view: the listener is there:
    var found = false;
    var i: u32 = 0;
    while (net.connection(i)) |c| : (i += 1) {
        if (c.proto == 6 and c.state == net.TcpState.listen and c.local.port == listen_port) found = true;
    }
    check(found, "listener in the connection list", "{d} entries", .{i});
    say("# LISTENING {d}\n", .{listen_port});
    l.setOption(net.SocketOption.recv_timeout, 30_000) catch {};
    var peer: net.Address = .{};
    const c = l.accept(&peer) catch |err| return check(false, "accept", "{s}", .{errText(err)});
    defer c.close();
    check(true, "accept", "", .{});
    var buf: [7]u8 = undefined;
    recvExactly(c, &buf) catch |err| return check(false, "incoming data", "{s}", .{errText(err)});
    check(std.mem.eql(u8, &buf, "ping-in"), "incoming data", "{s}", .{&buf});
    c.sendAll("pong-in") catch |err| check(false, "answer", "{s}", .{errText(err)});
}

fn arpTable(host: [4]u8) void {
    var i: u32 = 0;
    var found = false;
    while (net.arpEntry(i)) |e| : (i += 1) {
        if (std.mem.eql(u8, &e.address, &host)) found = true;
    }
    check(found, "the host in the ARP table", "{d} entries", .{i});
}

// Their output in files on the log drive, for net-tests.py.
fn tools(letter: u8) void {
    const lines = [_][]const u8{
        "IPCONFIG > {c}:\\TOOL-IPC.TXT",
        "PING -n 2 10.0.2.2 > {c}:\\TOOL-PNG.TXT",
        "NSLOOKUP localhost > {c}:\\TOOL-NSL.TXT",
        "NETSTAT > {c}:\\TOOL-NST.TXT",
        "ARP > {c}:\\TOOL-ARP.TXT",
        "FETCH http://10.0.2.2:8000/hello.txt > {c}:\\TOOL-F1.TXT",
        "FETCH -o {c}:\\TOOL-BIG.BIN http://10.0.2.2:8000/big.bin",
        "FETCH http://10.0.2.2:8000/redirect > {c}:\\TOOL-F2.TXT",
        // The host's self-signed servers (TLS 1.3, 1.2), then a real one:
        "FETCH -k https://10.0.2.2:8443/hello.txt > {c}:\\TOOL-T13.TXT",
        "FETCH -k https://10.0.2.2:8444/hello.txt > {c}:\\TOOL-T12.TXT",
        "FETCH -k https://10.0.2.2:8445/hello.txt > {c}:\\TOOL-TR2.TXT",
        "FETCH -k -o {c}:\\TOOL-TBG.BIN https://10.0.2.2:8443/big.bin",
        "FETCH https://10.0.2.2:8443/hello.txt > {c}:\\TOOL-TSS.TXT",
        "FETCH https://example.org/ > {c}:\\TOOL-TEX.TXT",
    };
    inline for (lines) |fmt| {
        var b: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&b, fmt, .{letter}) catch unreachable;
        const code = zdos.runCommand(cmd) catch 255;
        say("# ran {s}: exit code {d}\n", .{ cmd, code });
    }
}
