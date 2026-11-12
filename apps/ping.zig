// PING [-n COUNT] [-t] [-l SIZE] [-w TIMEOUT] HOST
// Exit code 0 if any answer came.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

fn usage() u8 {
    zdos.print("PING [-n COUNT] [-t] [-l SIZE] [-w TIMEOUT] HOST\n");
    return 1;
}

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var count: u32 = 4;
    var forever = false;
    var size: u16 = 32;
    var timeout: u32 = 1000;
    var host: ?[]const u8 = null;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "-t")) {
            forever = true;
        } else if (std.mem.eql(u8, w, "-n") or std.mem.eql(u8, w, "-l") or std.mem.eql(u8, w, "-w")) {
            const v = std.fmt.parseInt(u32, words.next() orelse return usage(), 10) catch return usage();
            switch (w[1]) {
                'n' => count = v,
                'l' => size = @intCast(@min(v, 1472)),
                else => timeout = v,
            }
        } else if (w[0] == '-' or w[0] == '/') {
            return usage();
        } else {
            host = w;
        }
    }
    const name = host orelse return usage();
    const addr = net.resolve(name) catch |err| {
        zdos.eprintf("PING: {s}: {s}\n", .{ name, zdos.message(err) });
        return 1;
    };
    var b: [16]u8 = undefined;
    const text = net.addressText(addr, &b);
    if (std.mem.eql(u8, text, name)) {
        zdos.printf("Pinging {s} with {d} bytes of data:\n", .{ text, size });
    } else {
        zdos.printf("Pinging {s} [{s}] with {d} bytes of data:\n", .{ name, text, size });
    }
    var sent: u32 = 0;
    var received: u32 = 0;
    var min: u32 = std.math.maxInt(u32);
    var max: u32 = 0;
    var total: u64 = 0;
    var seq: u16 = 1;
    while (forever or sent < count) : (seq +%= 1) {
        const began = zdos.millis();
        sent += 1;
        if (net.ping(addr, seq, size, 64, timeout)) |r| {
            var fb: [16]u8 = undefined;
            const from = net.addressText(r.from, &fb);
            switch (r.result) {
                net.PingResult.reply => {
                    received += 1;
                    min = @min(min, r.rtt_ms);
                    max = @max(max, r.rtt_ms);
                    total += r.rtt_ms;
                    if (r.rtt_ms == 0) {
                        zdos.printf("Reply from {s}: bytes={d} time<1ms TTL={d}\n", .{ from, r.bytes, r.ttl });
                    } else {
                        zdos.printf("Reply from {s}: bytes={d} time={d}ms TTL={d}\n", .{ from, r.bytes, r.rtt_ms, r.ttl });
                    }
                },
                net.PingResult.unreachable_ => zdos.printf("Reply from {s}: Destination unreachable.\n", .{from}),
                else => zdos.printf("Reply from {s}: TTL expired in transit.\n", .{from}),
            }
        } else |err| switch (err) {
            error.TimedOut => zdos.print("Request timed out.\n"),
            else => {
                zdos.eprintf("PING: {s}\n", .{zdos.message(err)});
                if (err != error.HostUnreachable) break;
            },
        }
        if (!forever and sent == count) break;
        const spent = zdos.millis() - began;
        if (spent < 1000) zdos.sleep(@intCast(1000 - spent));
    }
    const lost = sent - received;
    zdos.printf("\nPing statistics for {s}:\n    Packets: Sent = {d}, Received = {d}, Lost = {d} ({d}% loss),\n", .{ text, sent, received, lost, if (sent == 0) 0 else lost * 100 / sent });
    if (received > 0) {
        zdos.printf("Approximate round trip times in milli-seconds:\n    Minimum = {d}ms, Maximum = {d}ms, Average = {d}ms\n", .{ min, max, total / received });
    }
    return if (received > 0) 0 else 1;
}
