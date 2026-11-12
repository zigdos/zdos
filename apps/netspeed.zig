// NETSPEED: network speed against tests/net/netspeed.py.
//   NETSPEED [HOST] [SECONDS] [send] [recv] [rr] [udp] [pause]
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

const usage =
    \\Usage: NETSPEED [HOST] [SECONDS] [send] [recv] [rr] [udp] [pause]
    \\  Against netspeed.py on HOST (10.0.2.2), each test SECONDS long (10):
    \\  send and recv TCP's speed, rr 1-byte round trips, udp datagrams lost.
    \\  Default: all four; pause: a second between them. Results also to
    \\  NETSPEED.LOG on a drive NETLOG.
    \\
;

const tcp_port = 5700;
const udp_port = 5701;
const rr_count = 2000;
const udp_rate = 4000; // datagrams a second
const udp_size = 1200;

var log: ?zdos.File = null;
var line_buf: [512]u8 = undefined;

fn say(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&line_buf, fmt, args) catch return;
    zdos.print(text);
    if (log) |f| f.writeAll(text) catch {};
}

fn findLogDrive() ?u8 {
    var i: u32 = 0;
    while (system.driveAt(i)) |d| : (i += 1) {
        if (std.ascii.eqlIgnoreCase(d.label(), "NETLOG")) return d.letter;
    }
    return null;
}

const Test = enum { send, recv, rr, udp, pause };

pub fn main(args: []const u8) u8 {
    var host: [4]u8 = .{ 10, 0, 2, 2 };
    var seconds: u32 = 10;
    var wanted: [5]bool = @splat(false);
    var any = false;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |word| {
        if (net.parseAddress(word)) |a| {
            host = a;
        } else if (std.fmt.parseInt(u32, word, 10)) |n| {
            seconds = @max(1, @min(n, 3600));
        } else |_| {
            const t = std.meta.stringToEnum(Test, word) orelse {
                zdos.print(usage);
                return 1;
            };
            wanted[@intFromEnum(t)] = true;
            if (t != .pause) any = true;
        }
    }
    if (!any) {
        const pause = wanted[4];
        wanted = @splat(true);
        wanted[4] = pause;
    }
    if (findLogDrive()) |l| {
        var path = "X:\\NETSPEED.LOG".*;
        path[0] = l;
        log = zdos.open(&path, .write) catch null;
    }
    defer if (log) |f| f.close();

    var buf: [16]u8 = undefined;
    say("# NETSPEED {s}, {d} s a test\n", .{ net.addressText(host, &buf), seconds });
    describe();
    var failed: u8 = 0;
    const pause_ms: u32 = if (wanted[4]) 1000 else 0;
    if (wanted[0] and !tcpSend(host, seconds)) failed += 1;
    if (wanted[1]) {
        zdos.sleep(pause_ms);
        if (!tcpRecv(host, seconds)) failed += 1;
    }
    if (wanted[2]) {
        zdos.sleep(pause_ms);
        if (!roundTrips(host)) failed += 1;
    }
    if (wanted[3]) {
        zdos.sleep(pause_ms);
        if (!udpLoss(host, seconds)) failed += 1;
    }
    say("# NETSPEED: done, {d} failed\n", .{failed});
    return failed;
}

// The card and how the network runs:
fn describe() void {
    var i = net.info();
    const began = zdos.millis();
    // DHCP may still be asking:
    while (i.flags & net.Flags.dhcp != 0 and i.flags & net.Flags.dhcp_bound == 0 and zdos.millis() - began < 15_000) {
        zdos.sleep(250);
        i = net.info();
    }
    const irq = if (i.flags & net.Flags.interrupts != 0) "yes" else "no (polled)";
    const core = if (i.flags & net.Flags.own_core != 0) "yes" else "no";
    say("card: {s}; interrupts: {s}; own core: {s}\n", .{ i.card(), irq, core });
}

// A test's request: its kind, then two numbers
fn request(host: [4]u8, kind: u8, a: u32, b: u32) !net.Socket {
    const s = try net.Socket.open(net.SocketType.stream);
    errdefer s.close();
    try s.connect(.{ .addr = host, .port = tcp_port });
    var head: [9]u8 = undefined;
    head[0] = kind;
    std.mem.writeInt(u32, head[1..5], a, .little);
    std.mem.writeInt(u32, head[5..9], b, .little);
    try s.sendAll(&head);
    return s;
}

fn mbit(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) * 8.0 * 1000.0 / @as(f64, @floatFromInt(ns));
}

fn fail(comptime what: []const u8, err: anyerror) bool {
    say(what ++ ": failed ({s})\n", .{@errorName(err)});
    return false;
}

var data: [64 * 1024]u8 = undefined;

// ZDOS to the host for `seconds`:
fn tcpSend(host: [4]u8, seconds: u32) bool {
    const s = request(host, 'S', seconds, 0) catch |err| return fail("send", err);
    defer s.close();
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    const began = zdos.nanos();
    const until = began + @as(u64, seconds) * std.time.ns_per_s;
    var bytes: u64 = 0;
    while (zdos.nanos() < until) {
        bytes += s.send(&data) catch |err| return fail("send", err);
    }
    const ns = zdos.nanos() - began;
    say("send: {d:.1} Mbit/s ({d} bytes in {d} ms)\n", .{ mbit(bytes, ns), bytes, ns / std.time.ns_per_ms });
    return true;
}

// The host to ZDOS for `seconds`, until it closes:
fn tcpRecv(host: [4]u8, seconds: u32) bool {
    const s = request(host, 'R', seconds, 0) catch |err| return fail("recv", err);
    defer s.close();
    s.setOption(net.SocketOption.recv_timeout, (seconds + 10) * 1000) catch {};
    var bytes: u64 = 0;
    var began: u64 = 0;
    while (true) {
        const n = s.recv(&data) catch |err| return fail("recv", err);
        if (n == 0) break;
        if (bytes == 0) began = zdos.nanos();
        bytes += n;
    }
    const ns = zdos.nanos() - began;
    say("recv: {d:.1} Mbit/s ({d} bytes in {d} ms)\n", .{ mbit(bytes, ns), bytes, ns / std.time.ns_per_ms });
    return bytes > 0;
}

var rtt: [rr_count]u32 = undefined; // microseconds

fn us(ns: u64) u32 {
    return @intCast(@min(ns / 1000, std.math.maxInt(u32)));
}

// One byte there and back, rr_count times, after one to warm up:
fn roundTrips(host: [4]u8) bool {
    const s = request(host, 'P', rr_count + 1, 0) catch |err| return fail("rr", err);
    defer s.close();
    s.setOption(net.SocketOption.no_delay, 1) catch {};
    s.setOption(net.SocketOption.recv_timeout, 5000) catch {};
    var b = [1]u8{'x'};
    var i: usize = 0;
    const began = zdos.nanos();
    while (i <= rr_count) : (i += 1) {
        const t0 = zdos.nanos();
        s.sendAll(&b) catch |err| return fail("rr", err);
        const n = s.recv(&b) catch |err| return fail("rr", err);
        if (n == 0) return fail("rr", error.ConnectionAborted);
        if (i > 0) rtt[i - 1] = us(zdos.nanos() - t0);
    }
    const total = zdos.nanos() - began;
    std.mem.sort(u32, &rtt, {}, std.sort.asc(u32));
    const per_s = @as(f64, @floatFromInt(rr_count + 1)) * 1e9 / @as(f64, @floatFromInt(@max(total, 1)));
    say("rr: {d} round trips, {d:.0}/s; min {d} us, median {d} us, 99% {d} us, max {d} us\n", .{
        rr_count, per_s, rtt[0], rtt[rr_count / 2], rtt[rr_count * 99 / 100], rtt[rr_count - 1],
    });
    return true;
}

var dgram: [2048]u8 = undefined;

// The host sends udp_rate datagrams a second, numbered, then
// "END <sent>"; asked for by a datagram to it:
fn udpLoss(host: [4]u8, seconds: u32) bool {
    const s = net.Socket.open(net.SocketType.datagram) catch |err| return fail("udp", err);
    defer s.close();
    s.setOption(net.SocketOption.recv_timeout, 500) catch {};
    var ask: [13]u8 = undefined;
    ask[0] = 'U';
    std.mem.writeInt(u32, ask[1..5], seconds, .little);
    std.mem.writeInt(u32, ask[5..9], udp_rate, .little);
    std.mem.writeInt(u32, ask[9..13], udp_size, .little);
    const to: net.Address = .{ .addr = host, .port = udp_port };
    // QEMU's user network opens its host socket for a new
    // UDP peer but reads it only at its next wake-up (up to
    // 500 ms): a datagram the host ignores opens it first:
    _ = s.sendTo("open", to) catch {};
    zdos.sleep(600);
    const asked_at = zdos.millis();
    _ = s.sendTo(&ask, to) catch |err| return fail("udp", err);
    const until = zdos.millis() + @as(u64, seconds) * 1000 + 10_000;
    var asked: u32 = 1;
    var got: u64 = 0;
    var sent: ?u64 = null;
    var out_of_order: u64 = 0;
    var last: u32 = 0;
    var gaps: u64 = 0; // runs of missing numbers, and the longest
    var longest: u64 = 0;
    var longest_at: u64 = 0;
    var first: u32 = 0;
    var first_ms: u64 = 0; // after the request
    while (zdos.millis() < until) {
        const n = s.recvFrom(&dgram, null) catch |err| {
            if (err != error.WouldBlock) return fail("udp", err);
            if (got > 0) break; // quiet for 500 ms after data: over
            // The request lost (ARP still asking): again:
            if (asked < 6) {
                _ = s.sendTo(&ask, to) catch {};
                asked += 1;
            }
            continue;
        };
        if (n >= 4 and std.mem.eql(u8, dgram[0..4], "END ")) {
            sent = std.fmt.parseInt(u64, std.mem.trim(u8, dgram[4..n], " \r\n"), 10) catch null;
            break;
        }
        if (n < 4) continue;
        const seq = std.mem.readInt(u32, dgram[0..4], .little);
        if (got > 0 and seq < last) out_of_order += 1;
        const expect: u32 = if (got > 0) last + 1 else 0;
        if (got == 0) {
            first = seq;
            first_ms = zdos.millis() - asked_at;
        }
        if (seq > expect) {
            gaps += 1;
            if (seq - expect > longest) longest_at = expect;
            longest = @max(longest, seq - expect);
        }
        last = seq;
        got += 1;
    }
    const total = sent orelse return fail("udp", error.NoEndMark);
    const lost = total -| got;
    const pct = if (total == 0) 0 else @as(f64, @floatFromInt(lost)) * 100.0 / @as(f64, @floatFromInt(total));
    say("udp: {d} sent at {d}/s of {d} bytes, {d} received, {d:.2}% lost, {d} out of order\n", .{
        total, udp_rate, udp_size, got, pct, out_of_order,
    });
    if (gaps > 0) say("udp: {d} gaps, the longest {d} datagrams from number {d}; the first {d}, {d} ms after asking\n", .{ gaps, longest, longest_at, first, first_ms });
    return true;
}
