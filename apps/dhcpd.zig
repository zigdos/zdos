// DHCPD [-reload | -stop]: the DHCP server, a service (DHCPD.CFG)
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");
const users = @import("zdos/users.zig");
const service = @import("zdos/service.zig");

comptime {
    _ = zdos;
}

const ranges_max = 32;
const hosts_max = 256;
const leases_max = 1024;
const dns_max = 4;
const offer_s = 60; // an offer is held this long for the REQUEST
const check_ms = 2000; // how often DHCPD.CFG is looked at

const Range = struct { card: u8, first: u32, last: u32, lease_s: u32 };
const Host = struct { mac: [6]u8, ip: u32 };

// Addresses in host order (192.168.0.1 is 0xC0A80001):
const Config = struct {
    ranges: [ranges_max]Range = undefined,
    range_count: usize = 0,
    hosts: [hosts_max]Host = undefined,
    host_count: usize = 0,
    dns: [dns_max]u32 = undefined,
    dns_count: usize = 0,
    dns_router: bool = false,
};

const State = enum(u8) { free, offered, bound, declined };
const Lease = struct { state: State = .free, card: u8 = 0, mac: [6]u8 = @splat(0), ip: u32 = 0, until: u64 = 0 };

var cfg: Config = .{};
var leases: [leases_max]Lease = @splat(.{});
var log: service.Log = .{};
var watch: service.Watch = .{};
var cfg_path_buf: [32]u8 = undefined;
var cfg_path: []const u8 = "";

pub fn main(args: []const u8) u8 {
    if (service.command("DHCPD", args)) |code| return code;
    if (std.mem.trim(u8, args, " \t").len > 0) {
        zdos.print("DHCPD [-reload | -stop]   (a service: DHCPD=true in \\CONF\\SERVICES.CFG; docs/NETWORK.md)\n");
        return 1;
    }
    if (!users.isRoot()) {
        zdos.printError("DHCPD: starts as root\n");
        return 1;
    }
    service.catchSignals();
    const d = service.drive();
    cfg_path = std.fmt.bufPrint(&cfg_path_buf, "{c}:\\CONF\\DHCPD.CFG", .{d}) catch unreachable;
    load();

    const sock = net.Socket.open(net.SocketType.datagram) catch |err| return fatal("socket", err);
    defer sock.close();
    sock.setOption(net.SocketOption.broadcast, 1) catch {};
    sock.bind(.{ .port = 67 }) catch |err| return fatal("port 67", err);
    zdos.printf("DHCPD: {d} range(s), {d} fixed host(s)\n", .{ cfg.range_count, cfg.host_count });

    var checked = zdos.millis();
    while (!service.shouldStop()) {
        var fds = [_]zdos.PollFd{.{ .handle = sock.handle, .events = zdos.Poll.in }};
        _ = zdos.table().files.poll(&fds, 1, 250);
        while (true) {
            var via: net.Via = .{};
            const n = sock.recvVia(&msg, net.SocketFlags.dont_wait, null, &via) catch break;
            received(sock, n, via.card);
        }
        const now = zdos.millis();
        var again = service.takeReload();
        if (now - checked >= check_ms) {
            checked = now;
            if (watch.changed(cfg_path)) again = true;
        }
        if (again) load();
    }
    log.line("stopped", .{});
    return 0;
}

fn fatal(what: []const u8, err: zdos.Error) u8 {
    log.line("{s}: {s}", .{ what, zdos.message(err) });
    zdos.eprintf("DHCPD: {s}: {s}\n", .{ what, zdos.message(err) });
    return 1;
}

fn be(a: [4]u8) u32 {
    return std.mem.readInt(u32, &a, .big);
}

fn bytes(v: u32) [4]u8 {
    var a: [4]u8 = undefined;
    std.mem.writeInt(u32, &a, v, .big);
    return a;
}

fn text(v: u32, buf: *[16]u8) []const u8 {
    return net.addressText(bytes(v), buf);
}

// RANGE=, DNS=, LOG= AND "MAC ADDRESS" lines.
fn load() void {
    _ = watch.changed(cfg_path);
    log.set("");
    var c: Config = .{};
    const data = service.readAll(cfg_path, 1024 * 1024) orelse {
        cfg = c;
        return;
    };
    defer zdos.allocator.free(data);
    // LOG= first, for what the rest has to say:
    var pre = service.lines(data);
    while (pre.next()) |line| switch (line) {
        .setting => |s| if (std.ascii.eqlIgnoreCase(s.name, "LOG")) log.set(s.value),
        .words => {},
    };
    var it = service.lines(data);
    while (it.next()) |line| switch (line) {
        .setting => |s| {
            if (std.ascii.eqlIgnoreCase(s.name, "RANGE")) {
                range(&c, s.value);
            } else if (std.ascii.eqlIgnoreCase(s.name, "DNS")) {
                var words = std.mem.tokenizeAny(u8, s.value, " \t,;");
                while (words.next()) |w| {
                    if (std.ascii.eqlIgnoreCase(w, "router")) {
                        c.dns_router = true;
                    } else if (net.parseAddress(w)) |a| {
                        if (c.dns_count < dns_max) c.dns[c.dns_count] = be(a);
                        c.dns_count = @min(c.dns_count + 1, dns_max);
                    } else log.line("DHCPD.CFG: DNS= doesn't know \"{s}\" (ROUTER or addresses)", .{w});
                }
            } else if (std.ascii.eqlIgnoreCase(s.name, "LOG")) {
                // read above
            } else log.line("DHCPD.CFG: unknown setting {s}=", .{s.name});
        },
        .words => |w| host(&c, w),
    };
    cfg = c;
    log.line("{s}: {d} range(s), {d} fixed host(s)", .{ cfg_path, c.range_count, c.host_count });
}

fn range(c: *Config, value: []const u8) void {
    var words = std.mem.tokenizeAny(u8, value, " \t");
    const card = std.fmt.parseInt(u8, words.next() orelse "", 10) catch 255;
    const span = words.next() orelse "";
    const dash = std.mem.indexOfScalar(u8, span, '-') orelse span.len;
    const first = net.parseAddress(span[0..dash]);
    const last = if (dash < span.len) net.parseAddress(span[dash + 1 ..]) else null;
    const minutes = if (words.next()) |m| std.fmt.parseInt(u32, m, 10) catch 0 else 24 * 60;
    if (card == 255 or first == null or last == null or minutes == 0 or minutes > 365 * 24 * 60 or words.next() != null) {
        return log.line("DHCPD.CFG: RANGE= doesn't know \"{s}\" (CARD FIRST-LAST [MINUTES])", .{value});
    }
    const i = cardInfo(card) orelse return log.line("DHCPD.CFG: RANGE=: card {d} has no interface", .{card});
    if (i.flags & net.Flags.dhcp != 0) return log.line("DHCPD.CFG: RANGE=: card {d} takes its address by DHCP; a DHCP server needs a fixed one", .{card});
    const lo = be(first.?);
    const hi = be(last.?);
    const own = be(i.address);
    const mask = be(i.netmask);
    if (lo > hi or lo & mask != own & mask or hi & mask != own & mask) {
        return log.line("DHCPD.CFG: RANGE=: \"{s}\" isn't a range on card {d}'s network", .{ value, card });
    }
    if (c.range_count == ranges_max) return log.line("DHCPD.CFG: more than {d} ranges", .{ranges_max});
    c.ranges[c.range_count] = .{ .card = card, .first = lo, .last = hi, .lease_s = minutes * 60 };
    c.range_count += 1;
}

fn host(c: *Config, line: []const u8) void {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const mac = net.parseMac(words.next() orelse return);
    const ip = if (words.next()) |a| net.parseAddress(a) else null;
    if (mac == null or ip == null or words.next() != null) return log.line("DHCPD.CFG: \"{s}\" isn't MAC ADDRESS", .{line});
    if (c.host_count == hosts_max) return log.line("DHCPD.CFG: more than {d} fixed hosts", .{hosts_max});
    c.hosts[c.host_count] = .{ .mac = mac.?, .ip = be(ip.?) };
    c.host_count += 1;
}

fn cardInfo(n: u8) ?net.Info {
    var i: u32 = 0;
    while (net.interface(i)) |info| : (i += 1) {
        if (info.number == n) return info;
    }
    return null;
}

// LEASES

const Card = struct {
    number: u8,
    info: net.Info,

    fn own(k: Card) u32 {
        return be(k.info.address);
    }

    fn mask(k: Card) u32 {
        return be(k.info.netmask);
    }

    fn onNet(k: Card, ip: u32) bool {
        const m = k.mask();
        return ip & m == k.own() & m and ip & ~m != 0 and ip & ~m != ~m and ip != k.own();
    }

    fn rangeOf(k: Card, ip: u32) ?*const Range {
        for (cfg.ranges[0..cfg.range_count]) |*r| {
            if (r.card == k.number and ip >= r.first and ip <= r.last and k.onNet(ip)) return r;
        }
        return null;
    }

    // Its range's, else the card's first range's.
    fn leaseOf(k: Card, ip: u32) u32 {
        if (k.rangeOf(ip)) |r| return r.lease_s;
        for (cfg.ranges[0..cfg.range_count]) |r| {
            if (r.card == k.number) return r.lease_s;
        }
        return 24 * 3600;
    }

    // DHCPD.CFG's address for this MAC; 0 none.
    fn fixed(k: Card, mac: []const u8) u32 {
        for (cfg.hosts[0..cfg.host_count]) |h| {
            if (std.mem.eql(u8, &h.mac, mac) and k.onNet(h.ip)) return h.ip;
        }
        return 0;
    }

    // A lease, an offer, a fixed host, or declined.
    fn taken(k: Card, ip: u32, mac: []const u8, now: u64) bool {
        if (ip == k.own()) return true;
        for (cfg.hosts[0..cfg.host_count]) |h| {
            if (h.ip == ip and !std.mem.eql(u8, &h.mac, mac)) return true;
        }
        for (&leases) |*l| {
            if (l.card == k.number and l.ip == ip and live(l, now) and (l.state == .declined or !std.mem.eql(u8, &l.mac, mac))) return true;
        }
        return false;
    }

    // Live or not.
    fn leaseFor(k: Card, mac: []const u8) ?*Lease {
        for (&leases) |*l| {
            if (l.card == k.number and l.state != .declined and l.ip != 0 and std.mem.eql(u8, &l.mac, mac)) return l;
        }
        return null;
    }

    // Its own, or a free one.
    fn slot(k: Card, mac: []const u8, now: u64) ?*Lease {
        if (k.leaseFor(mac)) |l| return l;
        for (&leases) |*l| {
            if (!live(l, now)) return l;
        }
        return null;
    }

    // The fixed one, the one it had, the one it asks for, else the
    // first free one; 0 none.
    fn choose(k: Card, mac: []const u8, wanted: u32, now: u64) u32 {
        const f = k.fixed(mac);
        if (f != 0) return f;
        if (k.leaseFor(mac)) |l| {
            if (k.rangeOf(l.ip) != null and !k.taken(l.ip, mac, now)) return l.ip;
        }
        if (wanted != 0 and k.rangeOf(wanted) != null and !k.taken(wanted, mac, now)) return wanted;
        for (cfg.ranges[0..cfg.range_count]) |r| {
            if (r.card != k.number) continue;
            var a = r.first;
            while (true) : (a += 1) {
                if (k.onNet(a) and !k.taken(a, mac, now)) return a;
                if (a == r.last) break;
            }
        }
        return 0;
    }
};

fn live(l: *Lease, now: u64) bool {
    if (l.state != .free and l.until <= now) l.state = .free;
    return l.state != .free;
}

fn set(l: *Lease, card: u8, mac: []const u8, ip: u32, state: State, until: u64) void {
    l.* = .{ .state = state, .card = card, .ip = ip, .until = until };
    @memcpy(&l.mac, mac[0..6]);
}

// MESSAGES

const discover = 1;
const offer = 2;
const request = 3;
const decline = 4;
const ack = 5;
const nak = 6;
const release = 7;
const inform = 8;

const magic = [4]u8{ 99, 130, 83, 99 };
var msg: [1024]u8 = undefined;
var reply: [548]u8 = undefined;

fn get32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

fn option(len: usize, code: u8) ?[]const u8 {
    var at: usize = 240;
    while (at < len) {
        const c = msg[at];
        if (c == 255) break;
        if (c == 0) {
            at += 1;
            continue;
        }
        if (at + 2 > len or at + 2 + msg[at + 1] > len) break;
        if (c == code) return msg[at + 2 .. at + 2 + msg[at + 1]];
        at += 2 + @as(usize, msg[at + 1]);
    }
    return null;
}

fn option32(len: usize, code: u8) u32 {
    const v = option(len, code) orelse return 0;
    return if (v.len == 4) get32(v) else 0;
}

const Out = struct {
    at: usize = 240,

    fn byte(o: *Out, b: u8) void {
        reply[o.at] = b;
        o.at += 1;
    }

    fn word(o: *Out, v: u32) void {
        std.mem.writeInt(u32, reply[o.at..][0..4], v, .big);
        o.at += 4;
    }

    fn opt32(o: *Out, code: u8, v: u32) void {
        o.byte(code);
        o.byte(4);
        o.word(v);
    }
};

// DNSD on this machine for k's network: a UDP socket on port 53.
fn localDns(k: Card) bool {
    var i: u32 = 0;
    while (net.connection(i)) |c| : (i += 1) {
        if (c.proto == 17 and c.local.port == 53 and (be(c.local.addr) == 0 or be(c.local.addr) == k.own())) return true;
    }
    return false;
}

// to 0: broadcast on the card.
fn send(sock: net.Socket, k: Card, kind: u8, yiaddr: u32, lease_s: u32, to: u32) void {
    @memset(&reply, 0);
    reply[0] = 2; // BOOTREPLY
    @memcpy(reply[1..3], msg[1..3]); // htype, hlen
    @memcpy(reply[4..8], msg[4..8]); // xid
    @memcpy(reply[10..12], msg[10..12]); // flags
    if (kind != nak) @memcpy(reply[12..16], msg[12..16]); // ciaddr
    std.mem.writeInt(u32, reply[16..20], yiaddr, .big);
    @memcpy(reply[24..28], msg[24..28]); // giaddr
    @memcpy(reply[28..44], msg[28..44]); // chaddr
    @memcpy(reply[236..240], &magic);
    var o: Out = .{};
    o.byte(53);
    o.byte(1);
    o.byte(kind);
    o.opt32(54, k.own());
    if (kind != nak) {
        if (lease_s != 0) {
            o.opt32(51, lease_s);
            o.opt32(58, lease_s / 2);
            o.opt32(59, lease_s / 8 * 7);
        }
        o.opt32(1, k.mask());
        o.opt32(3, k.own());
        const start = o.at;
        o.byte(6);
        o.byte(0);
        if (cfg.dns_router or (cfg.dns_count == 0 and localDns(k))) {
            o.word(k.own());
        } else if (cfg.dns_count > 0) {
            for (cfg.dns[0..cfg.dns_count]) |a| o.word(a);
        } else {
            for (k.info.dns) |a| {
                if (be(a) != 0 and o.at - start < 2 + 4 * dns_max) o.word(be(a));
            }
        }
        reply[start + 1] = @intCast(o.at - start - 2);
        if (reply[start + 1] == 0) o.at = start;
    }
    o.byte(255);
    const size = @max(o.at, 300); // BOOTP's least
    const dest: [4]u8 = if (to == 0) .{ 255, 255, 255, 255 } else bytes(to);
    _ = sock.sendVia(reply[0..size], .{ .addr = dest, .port = 68 }, .{ .card = k.number }) catch {};
}

fn received(sock: net.Socket, len: usize, card: u8) void {
    if (len < 240 or msg[0] != 1 or msg[1] != 1 or msg[2] != 6 or !std.mem.eql(u8, msg[236..240], &magic)) return;
    var served = false;
    for (cfg.ranges[0..cfg.range_count]) |r| served = served or r.card == card;
    if (!served) return;
    const k: Card = .{ .number = card, .info = cardInfo(card) orelse return };
    const t = option(len, 53) orelse return;
    if (t.len != 1) return;
    const mac = msg[28..34];
    const ciaddr = get32(msg[12..16]);
    const wanted = option32(len, 50);
    const server = option32(len, 54);
    const now = zdos.millis() / 1000;
    var b: [16]u8 = undefined;
    var mb: [18]u8 = undefined;
    switch (t[0]) {
        discover => {
            const ip = k.choose(mac, wanted, now);
            const l = k.slot(mac, now) orelse return;
            if (ip == 0) return; // nothing free
            if (!(l.state == .bound and l.ip == ip and live(l, now))) set(l, card, mac, ip, .offered, now + offer_s);
            send(sock, k, offer, ip, k.leaseOf(ip), 0);
        },
        request => {
            if (server != 0 and server != k.own()) {
                // It took another server's offer:
                if (k.leaseFor(mac)) |l| {
                    if (l.state == .offered) l.state = .free;
                }
                return;
            }
            const ip = if (wanted != 0) wanted else ciaddr;
            if (ip == 0) return;
            const f = k.fixed(mac);
            const ok = if (f != 0) ip == f else k.rangeOf(ip) != null and !k.taken(ip, mac, now);
            const l = (if (ok) k.slot(mac, now) else null) orelse return send(sock, k, nak, 0, 0, 0);
            const lease_s = k.leaseOf(ip);
            const fresh = !(l.state == .bound and l.ip == ip);
            set(l, card, mac, ip, .bound, now + lease_s);
            send(sock, k, ack, ip, lease_s, ciaddr);
            if (fresh) log.line("card {d}: {s} to {s}", .{ card, text(ip, &b), net.macText(mac[0..6].*, &mb) });
        },
        decline => {
            // Someone else has it: not given out for a lease's time:
            if (k.leaseFor(mac)) |l| {
                if (l.ip == wanted) set(l, card, mac, wanted, .declined, now + k.leaseOf(wanted));
            }
            log.line("card {d}: {s} declined by {s}", .{ card, text(wanted, &b), net.macText(mac[0..6].*, &mb) });
        },
        release => {
            if (k.leaseFor(mac)) |l| {
                if (l.ip == ciaddr) l.state = .free;
            }
        },
        inform => if (ciaddr != 0) send(sock, k, ack, 0, 0, ciaddr),
        else => {},
    }
}
