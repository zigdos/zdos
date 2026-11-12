// NETSTAT [-i | -r]: connections and sockets, interfaces, routes
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

const state_names = [_][]const u8{
    "CLOSED",     "LISTENING",  "SYN_SENT",   "SYN_RECEIVED", "ESTABLISHED", "FIN_WAIT_1",
    "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING",    "LAST_ACK",     "TIME_WAIT",
};

fn endpoint(a: net.Address, any_port: bool, buf: *[24]u8) []const u8 {
    var b: [16]u8 = undefined;
    const text = net.addressText(a.addr, &b);
    if (any_port and a.port == 0) return std.fmt.bufPrint(buf, "{s}:*", .{text}) catch unreachable;
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ text, a.port }) catch unreachable;
}

pub fn main(args: []const u8) u8 {
    const arg = std.mem.trim(u8, args, " \t");
    const what: enum { connections, interfaces, routes } = if (arg.len == 0)
        .connections
    else if (std.ascii.eqlIgnoreCase(arg, "-i") or std.ascii.eqlIgnoreCase(arg, "/i"))
        .interfaces
    else if (std.ascii.eqlIgnoreCase(arg, "-r") or std.ascii.eqlIgnoreCase(arg, "/r"))
        .routes
    else {
        zdos.print("NETSTAT [-i | -r]   the connections; -i the interfaces, -r the routes\n");
        return 1;
    };
    if (net.info().flags & net.Flags.started == 0) {
        zdos.print("No network\n");
        return 1;
    }
    switch (what) {
        .connections => connections(),
        .interfaces => interfaces(),
        .routes => routes(),
    }
    return 0;
}

fn connections() void {
    zdos.print("  Proto  Local address          Remote address         State\n");
    var index: u32 = 0;
    while (net.connection(index)) |c| : (index += 1) {
        var l: [24]u8 = undefined;
        var r: [24]u8 = undefined;
        const tcp = c.proto == 6;
        const state = if (!tcp) "" else if (c.state < state_names.len) state_names[c.state] else "?";
        zdos.printf("  {s: <5}  {s: <21}  {s: <21}  {s}\n", .{
            if (tcp) "TCP" else "UDP",
            endpoint(c.local, false, &l),
            endpoint(c.remote, true, &r),
            state,
        });
    }
}

fn interfaces() void {
    zdos.print("  NET  Address             Received    Sent        Card\n");
    var index: u32 = 0;
    while (if (index == 0) net.info() else net.interface(index)) |i| : (index += 1) {
        if (i.flags & net.Flags.started == 0) break;
        var a: [16]u8 = undefined;
        var s: [20]u8 = undefined;
        const addr = std.fmt.bufPrint(&s, "{s}/{d}", .{ net.addressText(i.address, &a), @popCount(@as(u32, @bitCast(i.netmask))) }) catch unreachable;
        zdos.printf("  {d: <3}  {s: <18}  {d: <10}  {d: <10}  {s}{s}\n", .{
            i.number, addr, i.rx_frames, i.tx_frames, i.card(), if (i.flags & net.Flags.link == 0) " (no link)" else "",
        });
    }
}

fn routes() void {
    zdos.print("  Destination         Gateway          NET  Kind\n");
    var index: u32 = 0;
    while (net.route(index)) |r| : (index += 1) {
        var a: [16]u8 = undefined;
        var g: [16]u8 = undefined;
        var d: [20]u8 = undefined;
        const dest = std.fmt.bufPrint(&d, "{s}/{d}", .{ net.addressText(r.destination, &a), @popCount(@as(u32, @bitCast(r.netmask))) }) catch unreachable;
        const gw = if (r.flags & net.RouteFlags.link != 0) "on the link" else net.addressText(r.gateway, &g);
        const kind = if (r.flags & net.RouteFlags.default != 0) "default" else if (r.flags & net.RouteFlags.static_ != 0) "ROUTE=" else "the interface's";
        if (r.interface == net.Route.none) {
            zdos.printf("  {s: <18}  {s: <15}  -    {s} (no way there now)\n", .{ dest, gw, kind });
        } else {
            zdos.printf("  {s: <18}  {s: <15}  {d: <3}  {s}\n", .{ dest, gw, r.interface, kind });
        }
    }
    if (index == 0) zdos.print("  (none)\n");
}
