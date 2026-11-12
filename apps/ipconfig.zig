// IPCONFIG [-RENEW | -RELEASE]: the network interfaces and settings
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    const arg = std.mem.trim(u8, args, " \t");
    if (std.ascii.eqlIgnoreCase(arg, "-renew") or std.ascii.eqlIgnoreCase(arg, "-renew")) {
        net.renew(10_000) catch |err| {
            zdos.eprintf("IPCONFIG: {s}\n", .{zdos.message(err)});
            return 1;
        };
    } else if (std.ascii.eqlIgnoreCase(arg, "-release") or std.ascii.eqlIgnoreCase(arg, "-release")) {
        net.release() catch |err| {
            zdos.eprintf("IPCONFIG: {s}\n", .{zdos.message(err)});
            return 1;
        };
    } else if (arg.len > 0) {
        zdos.print("IPCONFIG [-RENEW | -RELEASE]\n");
        return 1;
    }
    const first = net.info();
    if (first.flags & net.Flags.started == 0) {
        zdos.print("No network: set NETWORK=true in \\CONF\\SYSTEM.CFG (and have a network card)\n");
        return 1;
    }
    // An older ZDOS has only info:
    const several = net.interface(1) != null;
    var index: u32 = 0;
    while (true) : (index += 1) {
        const i = if (index == 0) first else net.interface(index) orelse break;
        if (several) zdos.printf("{s}NET{d}\n", .{ if (index > 0) "\n" else "", i.number });
        show(i, several);
        if (!several) break;
    }
    var a: [16]u8 = undefined;
    zdos.printf("{s}Own CPU core . . . . : {s}\n", .{ if (several) "\n" else "", if (first.flags & net.Flags.own_core != 0) "yes" else "no" });
    zdos.printf("DNS servers  . . . . : {s}", .{net.addressText(first.dns[0], &a)});
    for (first.dns[1..]) |d| {
        if (!std.mem.eql(u8, &d, &[4]u8{ 0, 0, 0, 0 })) zdos.printf(", {s}", .{net.addressText(d, &a)});
    }
    zdos.print("\n");
    if (several or first.flags & net.Flags.routing != 0) {
        zdos.printf("Routing  . . . . . . : {s}\n", .{if (first.flags & net.Flags.routing != 0) "on (ROUTING=true; NETSTAT -r: the routes)" else "off"});
    }
    return 0;
}

fn show(i: net.Info, several: bool) void {
    var b: [18]u8 = undefined;
    var a: [16]u8 = undefined;
    const bridge = i.flags & net.Flags.bridge != 0;
    zdos.printf("{s}{s}\n", .{ if (bridge) "Bridge . . . . . . . : " else "Network card . . . . : ", i.card() });
    zdos.printf("Physical address . . : {s}\n", .{net.macText(i.mac, &b)});
    zdos.printf("Link . . . . . . . . : {s}\n", .{if (i.flags & net.Flags.link != 0) "up" else "down (no cable?)"});
    zdos.printf("Interrupts . . . . . : {s}\n", .{if (i.flags & net.Flags.interrupts != 0) "yes" else "no (polled)"});
    if (i.flags & net.Flags.dhcp != 0) {
        if (i.flags & net.Flags.dhcp_bound != 0) {
            zdos.printf("DHCP . . . . . . . . : yes, from {s}, lease {d} s\n", .{ net.addressText(i.dhcp_server, &a), i.lease_s });
        } else {
            zdos.print("DHCP . . . . . . . . : yes, no address yet\n");
        }
    } else {
        zdos.print("DHCP . . . . . . . . : no (a fixed address in SYSTEM.CFG)\n");
    }
    zdos.printf("IPv4 address . . . . : {s}\n", .{net.addressText(i.address, &a)});
    zdos.printf("Subnet mask  . . . . : {s}\n", .{net.addressText(i.netmask, &a)});
    const default = several and i.flags & net.Flags.default_route != 0;
    zdos.printf("Default gateway  . . : {s}{s}\n", .{ net.addressText(i.gateway, &a), if (default) " (the default route)" else "" });
    zdos.printf("Frames . . . . . . . : {d} received, {d} sent\n", .{ i.rx_frames, i.tx_frames });
}
