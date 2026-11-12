// The router's NAT= and FORWARD= (nat.c),
// set up before the network runs.
const std = @import("std");
const net = @import("net.zig");
const con = @import("../kernel/console.zig");

const c = struct {
    extern fn zn_nat_enable(iface: c_int) c_int;
    extern fn zn_nat_forward(proto: c_int, port: c_ushort, to: c_uint, to_port: c_ushort) c_int;
};

const max = 8;
var nat_cards: [max]u8 = undefined;
var nat_count: usize = 0;
var forward_count: usize = 0;

const Get = *const fn (name: []const u8) ?[]const u8;

pub fn start(get: Get) void {
    if (!net.available) return;
    if (get("NAT")) |text| nat(text);
    if (get("FORWARD")) |text| forwards(text);
    for ([_][]const u8{ "DHCPD", "DHCPD_HOST", "DNSD" }) |old| {
        if (get(old) != null) con.printf("SYSTEM.CFG: {s}= is gone: the DHCP and DNS servers are services (DHCPD.CFG, DNSD.CFG; docs/NETWORK.md)\n", .{old});
    }
}

pub fn report() void {
    if (!net.available) return;
    for (nat_cards[0..nat_count]) |n| con.printf("Network: NAT out of card {d}\n", .{n});
    if (forward_count > 0) con.printf("Network: {d} port forward(s) (FORWARD=)\n", .{forward_count});
}

// Whether NAT= masquerades behind card number n (NetFlags.nat)
pub fn isNat(n: u8) bool {
    return std.mem.indexOfScalar(u8, nat_cards[0..nat_count], n) != null;
}

// A card number with an interface of its own
fn card(setting: []const u8, word: []const u8) ?struct { number: u8, lan: net.Lan } {
    const n = std.fmt.parseInt(u8, word, 10) catch 255;
    const l = net.interfaceNumbered(n);
    if (l == null) {
        con.printf("SYSTEM.CFG: {s}=: card \"{s}\" has no interface (unused, OFF, or a bridge's second card)\n", .{ setting, word });
        return null;
    }
    return .{ .number = n, .lan = l.? };
}

// NAT=0[,2]: the outside cards (numbered from 0, as NETn=)
fn nat(text: []const u8) void {
    var it = std.mem.tokenizeAny(u8, text, " \t,;");
    while (it.next()) |w| {
        const k = card("NAT", w) orelse continue;
        if (nat_count == max or c.zn_nat_enable(@intCast(k.lan.index)) == 0) continue;
        nat_cards[nat_count] = k.number;
        nat_count += 1;
    }
}

// FORWARD=tcp 8080 192.168.10.5:80,
// udp 5000 192.168.10.6 (the same port)
fn forwards(text: []const u8) void {
    var it = std.mem.tokenizeAny(u8, text, ",;");
    while (it.next()) |one| {
        var words = std.mem.tokenizeAny(u8, one, " \t");
        const kind = words.next() orelse continue;
        const proto: c_int = if (std.ascii.eqlIgnoreCase(kind, "tcp")) 6 else if (std.ascii.eqlIgnoreCase(kind, "udp")) 17 else 0;
        const port = if (words.next()) |p| std.fmt.parseInt(u16, p, 10) catch 0 else 0;
        const target = words.next() orelse "";
        const colon = std.mem.indexOfScalar(u8, target, ':');
        const to = net.parseAddress(target[0 .. colon orelse target.len]);
        const to_port = if (colon) |i| std.fmt.parseInt(u16, target[i + 1 ..], 10) catch 0 else port;
        if (proto == 0 or port == 0 or to == null or to_port == 0 or words.next() != null) {
            con.printf("SYSTEM.CFG: FORWARD= doesn't know \"{s}\" (TCP|UDP PORT ADDRESS[:PORT])\n", .{std.mem.trim(u8, one, " \t")});
            continue;
        }
        if (c.zn_nat_forward(proto, port, to.?, to_port) == 0) {
            con.print("SYSTEM.CFG: FORWARD= has more than 16 ports\n");
            return;
        }
        forward_count += 1;
    }
    if (forward_count > 0 and nat_count == 0) con.print("SYSTEM.CFG: FORWARD= works with NAT= only\n");
}
