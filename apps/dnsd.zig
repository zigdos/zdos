// DNSD [-reload | -stop]: the DNS server, a service (DNSD.CFG) Answers
// HOSTS.CFG's names itself, passes the others on and caches their answers.
// UDP, port 53.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");
const users = @import("zdos/users.zig");
const service = @import("zdos/service.zig");

comptime {
    _ = zdos;
}

const cards_max = 8;
const servers_max = 8;
const pending_max = 64;
const wait_ms = 2000; // for one server, before the next one is asked
const query_max = 512;
const cache_default = 128;
const cache_max = 16384;
const cache_ttl_max = 86400; // seconds: a day
const negative_ttl = 60; // NXDOMAIN / no data without an SOA
const negative_ttl_max = 10800;
const check_ms = 2000; // how often the files and the interfaces are looked at

const Config = struct {
    all_cards: bool = true, // all but NAT='s outside cards
    cards: [cards_max]u8 = undefined,
    card_count: usize = 0,
    servers: [servers_max][4]u8 = undefined,
    server_count: usize = 0, // 0: ZDOS's own
    cache: usize = cache_default,
    ttl: u32 = 60, // of HOSTS.CFG's answers
};

var cfg: Config = .{};
var log: service.Log = .{};
var paths_buf: [2][32]u8 = undefined;
var cfg_path: []const u8 = "";
var hosts_path: []const u8 = "";
var cfg_watch: service.Watch = .{};
var hosts_watch: service.Watch = .{};
var hosts: []const u8 = &.{};

// As of the last look:
var ifaces: [cards_max]net.Info = undefined;
var iface_count: usize = 0;
var servers: [servers_max][4]u8 = undefined;
var server_count: usize = 0;

pub fn main(args: []const u8) u8 {
    if (service.command("DNSD", args)) |code| return code;
    if (std.mem.trim(u8, args, " \t").len > 0) {
        zdos.print("DNSD [-reload | -stop]   (a service: DNSD=true in \\CONF\\SERVICES.CFG; docs/NETWORK.md)\n");
        return 1;
    }
    if (!users.isRoot()) {
        zdos.printError("DNSD: starts as root\n");
        return 1;
    }
    service.catchSignals();
    const d = service.drive();
    cfg_path = std.fmt.bufPrint(&paths_buf[0], "{c}:\\CONF\\DNSD.CFG", .{d}) catch unreachable;
    hosts_path = std.fmt.bufPrint(&paths_buf[1], "{c}:\\CONF\\HOSTS.CFG", .{d}) catch unreachable;
    load();

    const sock = net.Socket.open(net.SocketType.datagram) catch |err| return fatal("socket", err);
    defer sock.close();
    sock.bind(.{ .port = 53 }) catch |err| return fatal("port 53", err);
    const up = net.Socket.open(net.SocketType.datagram) catch |err| return fatal("socket", err);
    defer up.close();
    up.bind(.{}) catch |err| return fatal("socket", err);
    zdos.printf("DNSD: {d} server(s) to ask, a cache of {d}\n", .{ server_count, cache.len });

    var checked = zdos.millis();
    while (!service.shouldStop()) {
        var fds = [_]zdos.PollFd{ .{ .handle = sock.handle, .events = zdos.Poll.in }, .{ .handle = up.handle, .events = zdos.Poll.in } };
        _ = zdos.table().files.poll(&fds, 2, 250);
        while (true) {
            var from: net.Address = .{};
            var via: net.Via = .{};
            const n = sock.recvVia(&buf, net.SocketFlags.dont_wait, &from, &via) catch break;
            fromClient(sock, up, n, from, via);
        }
        while (true) {
            var from: net.Address = .{};
            const n = up.recvVia(&from_server, net.SocketFlags.dont_wait, &from, null) catch break;
            fromServer(sock, from_server[0..n], from);
        }
        const now = zdos.millis();
        timers(sock, up, now);
        var again = service.takeReload();
        if (now - checked >= check_ms) {
            checked = now;
            if (cfg_watch.changed(cfg_path)) again = true;
            if (hosts_watch.changed(hosts_path)) again = true;
            look();
        }
        if (again) load();
    }
    log.line("stopped", .{});
    return 0;
}

fn fatal(what: []const u8, err: zdos.Error) u8 {
    log.line("{s}: {s}", .{ what, zdos.message(err) });
    zdos.eprintf("DNSD: {s}: {s}\n", .{ what, zdos.message(err) });
    return 1;
}

// CARDS=true | false | N,..., SERVERS=, CACHE=N, TTL=SECONDS, LOG=FILE
fn load() void {
    _ = cfg_watch.changed(cfg_path);
    _ = hosts_watch.changed(hosts_path);
    log.set("");
    var c: Config = .{};
    if (service.readAll(cfg_path, 64 * 1024)) |data| {
        defer zdos.allocator.free(data);
        // LOG= first, for what the rest has to say:
        var pre = service.lines(data);
        while (pre.next()) |line| switch (line) {
            .setting => |s| if (std.ascii.eqlIgnoreCase(s.name, "LOG")) log.set(s.value),
            .words => {},
        };
        var it = service.lines(data);
        while (it.next()) |line| {
            const s = switch (line) {
                .setting => |s| s,
                .words => |w| {
                    log.line("DNSD.CFG: \"{s}\" isn't a setting", .{w});
                    continue;
                },
            };
            if (std.ascii.eqlIgnoreCase(s.name, "CARDS")) {
                c.all_cards = std.ascii.eqlIgnoreCase(s.value, "true");
                c.card_count = 0;
                if (c.all_cards or std.ascii.eqlIgnoreCase(s.value, "false")) continue;
                var words = std.mem.tokenizeAny(u8, s.value, " \t,;");
                while (words.next()) |w| {
                    const n = std.fmt.parseInt(u8, w, 10) catch {
                        log.line("DNSD.CFG: CARDS= doesn't know \"{s}\" (true, false or card numbers)", .{w});
                        continue;
                    };
                    if (c.card_count < cards_max) c.cards[c.card_count] = n;
                    c.card_count = @min(c.card_count + 1, cards_max);
                }
            } else if (std.ascii.eqlIgnoreCase(s.name, "SERVERS")) {
                var words = std.mem.tokenizeAny(u8, s.value, " \t,;");
                while (words.next()) |w| {
                    const a = net.parseAddress(w) orelse {
                        log.line("DNSD.CFG: SERVERS= doesn't know \"{s}\"", .{w});
                        continue;
                    };
                    if (c.server_count < servers_max) c.servers[c.server_count] = a;
                    c.server_count = @min(c.server_count + 1, servers_max);
                }
            } else if (std.ascii.eqlIgnoreCase(s.name, "CACHE")) {
                c.cache = @min(std.fmt.parseInt(usize, s.value, 10) catch cache_default, cache_max);
            } else if (std.ascii.eqlIgnoreCase(s.name, "TTL")) {
                c.ttl = std.fmt.parseInt(u32, s.value, 10) catch c.ttl;
            } else if (std.ascii.eqlIgnoreCase(s.name, "LOG")) {
                // read above
            } else log.line("DNSD.CFG: unknown setting {s}=", .{s.name});
        }
    }
    cfg = c;
    if (hosts.len > 0) zdos.allocator.free(hosts);
    hosts = service.readAll(hosts_path, 16 * 1024 * 1024) orelse &.{};
    resize(c.cache);
    look();
    log.line("{s}: {d} server(s) to ask, a cache of {d}; {s}: {d} bytes", .{ cfg_path, server_count, cache.len, hosts_path, hosts.len });
}

// Any case; ADDRESS NAME [ALIASES] lines.
fn hostsFind(name: []const u8) ?[4]u8 {
    var it = std.mem.splitScalar(u8, hosts, '\n');
    while (it.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const a = net.parseAddress(words.next() orelse continue) orelse continue;
        while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, name)) return a;
        }
    }
    return null;
}

fn hostsName(addr: [4]u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, hosts, '\n');
    while (it.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const a = net.parseAddress(words.next() orelse continue) orelse continue;
        if (std.mem.eql(u8, &a, &addr)) return words.next() orelse continue;
    }
    return null;
}

// Addresses may come by DHCP; servers: not ourselves, not the loopback.
fn look() void {
    iface_count = 0;
    var i: u32 = 0;
    while (net.interface(i)) |info| : (i += 1) {
        if (iface_count == cards_max) break;
        ifaces[iface_count] = info;
        iface_count += 1;
    }
    const list: []const [4]u8 = if (cfg.server_count > 0) cfg.servers[0..cfg.server_count] else if (iface_count > 0) &ifaces[0].dns else &.{};
    server_count = 0;
    for (list) |a| {
        if (std.mem.eql(u8, &a, &.{ 0, 0, 0, 0 }) or a[0] == 127 or own(a)) continue;
        servers[server_count] = a;
        server_count += 1;
    }
}

fn own(a: [4]u8) bool {
    for (ifaces[0..iface_count]) |f| {
        if (std.mem.eql(u8, &f.address, &a)) return true;
    }
    return false;
}

// Null: not one of the cards served.
fn served(card: u8) ?*const net.Info {
    for (ifaces[0..iface_count]) |*f| {
        if (f.number != card) continue;
        if (cfg.all_cards) return if (f.flags & net.Flags.nat == 0) f else null;
        return if (std.mem.indexOfScalar(u8, cfg.cards[0..cfg.card_count], card) != null) f else null;
    }
    return null;
}

// MESSAGES

var buf: [query_max + 1]u8 = undefined; // the client's query (longer: dropped)
var from_server: [4096]u8 = undefined; // an answer (EDNS: may pass 512 bytes)

fn rd16(p: []const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .big);
}

fn wr16(p: []u8, v: u16) void {
    std.mem.writeInt(u16, p[0..2], v, .big);
}

fn rd32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

// "www.example.org", lower case, into name; where
// the question ends, 0 if it isn't one we read.
fn question(q: []const u8, name: *[256]u8, name_len: *usize) usize {
    var at: usize = 12;
    var n: usize = 0;
    while (at < q.len and q[at] != 0) {
        const l = q[at];
        if (l > 63 or at + 1 + l >= q.len or n + l + 1 > 255) return 0;
        if (n > 0) {
            name[n] = '.';
            n += 1;
        }
        for (q[at + 1 .. at + 1 + l]) |ch| {
            name[n] = std.ascii.toLower(ch);
            n += 1;
        }
        at += 1 + @as(usize, l);
    }
    if (at + 5 > q.len) return 0;
    name_len.* = n;
    return at + 5;
}

// "4.3.2.1.in-addr.arpa": the address 1.2.3.4
fn reverse(name: []const u8) ?[4]u8 {
    const tail = ".in-addr.arpa";
    if (!std.mem.endsWith(u8, name, tail)) return null;
    var it = std.mem.splitScalar(u8, name[0 .. name.len - tail.len], '.');
    var a: [4]u8 = undefined;
    var k: usize = 0;
    while (it.next()) |part| : (k += 1) {
        if (k == 4 or part.len == 0 or part.len > 3) return null;
        a[3 - k] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (k == 4) a else null;
}

// As labels.
fn encode(name: []const u8, out: []u8) usize {
    var o: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63 or o + label.len + 2 > out.len) return 0;
        out[o] = @intCast(label.len);
        @memcpy(out[o + 1 .. o + 1 + label.len], label);
        o += 1 + label.len;
    }
    out[o] = 0;
    return o + 1;
}

const Client = struct { addr: net.Address, via: net.Via };

fn sendTo(sock: net.Socket, data: []const u8, c: Client) void {
    _ = sock.sendVia(data, c.addr, c.via) catch {};
}

// The question, then `count` records of type
// `kind` with `data`; rcode 0 or 2 (SERVFAIL).
fn answer(sock: net.Socket, qend: usize, kind: u16, data: []const u8, count: usize, rcode: u8, c: Client) void {
    var out: [query_max + 300]u8 = undefined;
    @memcpy(out[0..qend], buf[0..qend]);
    out[2] = 0x80 | (buf[2] & 0x79) | @as(u8, if (rcode == 0) 0x04 else 0); // QR, opcode, AA, RD
    out[3] = 0x80 | rcode; // RA
    wr16(out[4..], 1);
    wr16(out[6..], @intCast(count));
    wr16(out[8..], 0);
    wr16(out[10..], 0);
    var o = qend;
    for (0..count) |_| {
        if (o + 12 + data.len > out.len) break;
        wr16(out[o..], 0xC00C); // the question's name
        wr16(out[o + 2 ..], kind);
        wr16(out[o + 4 ..], 1);
        std.mem.writeInt(u32, out[o + 6 ..][0..4], cfg.ttl, .big);
        wr16(out[o + 10 ..], @intCast(data.len));
        @memcpy(out[o + 12 .. o + 12 + data.len], data);
        o += 12 + data.len;
    }
    sendTo(sock, out[0..o], c);
}

// The name in any case (length bytes are below 'A').
fn sameQuestion(a: []const u8, b: []const u8, qend: usize) bool {
    if (a.len < qend or b.len < qend) return false;
    for (a[12..qend], b[12..qend]) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

// Labels, maybe ending in a pointer; 0 if it runs out.
fn skipName(m: []const u8, start: usize) usize {
    var p = start;
    while (p < m.len) {
        const l = m[p];
        if (l == 0) return p + 1;
        if (l & 0xC0 == 0xC0) return if (p + 2 <= m.len) p + 2 else 0;
        if (l > 63) return 0;
        p += 1 + @as(usize, l);
    }
    return 0;
}

// Seconds (0: not at all); with elapsed,
// the TTLs (but OPT's) lowered by that many.
fn records(m: []u8, qend: usize, elapsed: u32) u32 {
    const answers = rd16(m[6..]);
    const authority = rd16(m[8..]);
    const counts = @as(usize, answers) + authority + rd16(m[10..]);
    var p = qend;
    var keep: u32 = 0xFFFFFFFF;
    var negative: u32 = 0;
    var soa = false;
    for (0..counts) |i| {
        p = skipName(m, p);
        if (p == 0 or p + 10 > m.len) return 0;
        const kind = rd16(m[p..]);
        const rdlen = rd16(m[p + 8 ..]);
        var ttl = rd32(m[p + 4 ..]);
        if (ttl > 0x7FFFFFFF) ttl = 0; // RFC 2181
        if (p + 10 + rdlen > m.len) return 0;
        if (kind != 41) { // OPT's "TTL" is flags
            if (elapsed != 0) std.mem.writeInt(u32, m[p + 4 ..][0..4], ttl -| elapsed, .big);
            if (i < @as(usize, answers) + authority and ttl < keep) keep = ttl;
            // RFC 2308: a negative answer lasts the SOA's TTL or
            // minimum, the smaller:
            if (kind == 6 and i >= answers and i < @as(usize, answers) + authority and rdlen >= 22) {
                negative = @min(ttl, rd32(m[p + 10 + rdlen - 4 ..]));
                soa = true;
            }
        }
        p += 10 + @as(usize, rdlen);
    }
    if (m[3] & 0x0F == 3 or answers == 0) return @min(if (soa) negative else negative_ttl, negative_ttl_max);
    return @min(keep, cache_ttl_max);
}

// THE CACHE

// Whole packets of up to 512 bytes by question (name in any case, type, class);
// kept for their smallest TTL, least recently used out first.
const Entry = struct {
    len: u16 = 0, // 0: free
    qend: u16 = 0,
    stored: u64 = 0,
    life_ms: u64 = 0,
    used: u64 = 0,
    data: [query_max]u8 = undefined,
};

var cache: []Entry = &.{};
var cache_clock: u64 = 0;

// Kept as it is unless its size changes.
fn resize(n: usize) void {
    if (n == cache.len) return;
    if (cache.len > 0) zdos.allocator.free(cache);
    cache = zdos.allocator.alloc(Entry, n) catch &.{};
    if (cache.len < n) log.line("DNSD.CFG: CACHE={d}: not enough memory; no cache", .{n});
    for (cache) |*e| e.len = 0;
}

fn cachePut(query: []const u8, m: []const u8) void {
    var name: [256]u8 = undefined;
    var nlen: usize = 0;
    const qend = question(query, &name, &nlen);
    const rcode = m[3] & 0x0F;
    // Answers to the question asked, whole, NOERROR or NXDOMAIN:
    if (cache.len == 0 or qend == 0 or m.len > query_max or m.len < qend or m[2] & 0xFA != 0x80 or (rcode != 0 and rcode != 3) or
        rd16(m[4..]) != 1 or !sameQuestion(query, m, qend)) return;
    var copy: [query_max]u8 = undefined;
    @memcpy(copy[0..m.len], m);
    const keep = records(copy[0..m.len], qend, 0);
    if (keep == 0) return;
    const now = zdos.millis();
    var slot: ?*Entry = null;
    var oldest = &cache[0];
    for (cache) |*e| {
        if (e.len != 0 and e.qend == qend and sameQuestion(e.data[0..e.len], m, qend)) {
            slot = e;
            break;
        }
        if (slot == null and (e.len == 0 or now - e.stored >= e.life_ms)) slot = e;
        if (e.used < oldest.used) oldest = e;
    }
    const e = slot orelse oldest;
    cache_clock += 1;
    e.* = .{ .len = @intCast(m.len), .qend = @intCast(qend), .stored = now, .life_ms = @as(u64, keep) * 1000, .used = cache_clock };
    @memcpy(e.data[0..m.len], m);
}

// False if none.
fn cacheAnswer(sock: net.Socket, q: []const u8, qend: usize, c: Client) bool {
    const now = zdos.millis();
    for (cache) |*e| {
        if (e.len == 0 or e.qend != qend or !sameQuestion(e.data[0..e.len], q, qend)) continue;
        if (now - e.stored >= e.life_ms) {
            e.len = 0;
            return false;
        }
        var out: [query_max]u8 = undefined;
        const m = out[0..e.len];
        @memcpy(m, e.data[0..e.len]);
        _ = records(m, qend, @intCast((now - e.stored) / 1000));
        // The client's id, RD bit and question as it wrote it:
        @memcpy(m[0..2], q[0..2]);
        m[2] = (m[2] & 0xFE) | (q[2] & 1);
        @memcpy(m[12..qend], q[12..qend]);
        cache_clock += 1;
        e.used = cache_clock;
        sendTo(sock, m, c);
        return true;
    }
    return false;
}

// PASSING QUERIES ON

// Matched by our id and the server asked.
const Pending = struct {
    used: bool = false,
    server: usize = 0, // index into servers
    to: [4]u8 = undefined,
    id: u16 = 0,
    client_id: u16 = 0,
    client: Client = undefined,
    sent: u64 = 0,
    len: usize = 0,
    query: [query_max]u8 = undefined,
};

var pending: [pending_max]Pending = @splat(.{});

fn ask(up: net.Socket, p: *Pending, now: u64) void {
    p.to = servers[p.server];
    p.sent = now;
    _ = up.sendTo(p.query[0..p.len], .{ .addr = p.to, .port = 53 }) catch {};
}

fn fromClient(sock: net.Socket, up: net.Socket, len: usize, from: net.Address, via: net.Via) void {
    const f = served(via.card) orelse return;
    const bcast = [4]u8{ f.address[0] | ~f.netmask[0], f.address[1] | ~f.netmask[1], f.address[2] | ~f.netmask[2], f.address[3] | ~f.netmask[3] };
    if (std.mem.eql(u8, &via.local, &.{ 255, 255, 255, 255 }) or std.mem.eql(u8, &via.local, &bcast) or len < 12 or len > query_max) return;
    const q = buf[0..len];
    if (q[2] & 0xF8 != 0 or rd16(q[4..]) != 1) return; // a standard query, one question
    var name: [256]u8 = undefined;
    var nlen: usize = 0;
    const qend = question(q, &name, &nlen);
    if (qend == 0) return;
    const c: Client = .{ .addr = from, .via = via };
    const qtype = rd16(q[qend - 4 ..]);
    const qclass = rd16(q[qend - 2 ..]);
    if (qclass == 1) {
        if (hostsFind(name[0..nlen])) |a| {
            // HOSTS.CFG's: its address; other types: none:
            return answer(sock, qend, 1, &a, @intFromBool(qtype == 1 or qtype == 255), 0, c);
        }
        if (qtype == 12) {
            if (reverse(name[0..nlen])) |a| {
                if (hostsName(a)) |h| {
                    var enc: [258]u8 = undefined;
                    const el = encode(h, &enc);
                    if (el > 0) return answer(sock, qend, 12, enc[0..el], 1, 0, c);
                }
            }
        }
    }
    if (cacheAnswer(sock, q, qend, c)) return;
    if (server_count == 0) return answer(sock, qend, 0, &.{}, 0, 2, c);
    // Passed on under an id of ours; a full table drops the oldest:
    const now = zdos.millis();
    var slot = &pending[0];
    for (&pending) |*p| {
        if (!p.used) {
            slot = p;
            break;
        }
        if (p.sent < slot.sent) slot = p;
    }
    var id: u16 = undefined;
    while (true) {
        zdos.randomBytes(std.mem.asBytes(&id));
        for (&pending) |*p| {
            if (p.used and p.id == id) break;
        } else break;
    }
    slot.* = .{ .used = true, .id = id, .client_id = rd16(q), .client = c, .len = len };
    @memcpy(slot.query[0..len], q);
    wr16(&slot.query, id);
    ask(up, slot, now);
}

fn fromServer(sock: net.Socket, m: []u8, from: net.Address) void {
    if (from.port != 53 or m.len < 12) return;
    const id = rd16(m);
    for (&pending) |*p| {
        if (!p.used or p.id != id or !std.mem.eql(u8, &p.to, &from.addr)) continue;
        p.used = false;
        cachePut(p.query[0..p.len], m);
        wr16(m, p.client_id);
        sendTo(sock, m, p.client);
        return;
    }
}

// After the last server the client hears SERVFAIL.
fn timers(sock: net.Socket, up: net.Socket, now: u64) void {
    for (&pending) |*p| {
        if (!p.used or now - p.sent < wait_ms) continue;
        if (p.server + 1 < server_count) {
            p.server += 1;
            ask(up, p, now);
            continue;
        }
        p.used = false;
        @memcpy(buf[0..p.len], p.query[0..p.len]);
        wr16(&buf, p.client_id);
        var name: [256]u8 = undefined;
        var nlen: usize = 0;
        const qend = question(buf[0..p.len], &name, &nlen);
        if (qend != 0) answer(sock, qend, 0, &.{}, 0, 2, p.client);
    }
}
