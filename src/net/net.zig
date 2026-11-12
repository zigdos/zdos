// The network: lwIP (glue.c) on the cards, an interface
// each or bridges of them, and the loopback; started at
// boot with NETWORK=true. With two or more cores metal and BIOS
// run it on a core of its own (NETCORE=); else a kernel task
// does, woken by the cards' interrupt or every 2 ms. lwIP is
// entered under `lock` only: the kernel lock, plus a spin lock
// while the network core runs. Addresses are lwIP's: network
// byte order in a u32.
const std = @import("std");
const platform = @import("../platform.zig");
const arch = @import("../arch.zig");
const abi = @import("../kernel/abi.zig");
const tasks = @import("../kernel/tasks.zig");
const queues = @import("../kernel/events.zig");
const con = @import("../kernel/console.zig");
const fs = @import("../kernel/fs.zig");
const card_io = @import("card.zig"); // the drivers' cards, the platform's
const lan = @import("lan.zig"); // NAT=, FORWARD=

// Without a card interface lwIP isn't linked: functions that
// reach it start with `if (!available)`,
// so the compiler leaves the rest out
pub const available = platform.has_net;

// GLUE.H

const ZSocket = opaque {};

const Setup = extern struct {
    mac: [6]u8,
    dhcp: u8,
    link_up: u8,
    ip: u32 = 0,
    mask: u32 = 0,
    gateway: u32 = 0,
    ports: [card_io.max]u8 = @splat(0),
    port_count: u8 = 0,
    pad: [3]u8 = @splat(0),
};

const Config = extern struct {
    ip: u32,
    mask: u32,
    gateway: u32,
    dns: [8]u32,
    lease_s: u32,
    dhcp_server: u32,
    mac: [6]u8,
    link_up: u8,
    dhcp: u8,
    dhcp_bound: u8,
    is_default: u8,
    pad: [2]u8,
};

const PingResult = extern struct {
    rtt: u32,
    from: u32,
    bytes: u16,
    ttl: u8,
    pad: u8,
};

const Conn = extern struct {
    local: u32,
    remote: u32,
    local_port: u16,
    remote_port: u16,
    rx_queued: u32,
    tx_queued: u32,
    proto: u8,
    state: u8,
    pad: [2]u8,
};

const ZN = struct {
    const tcp = 1;
    const udp = 2;
    const ok = 0;
    const would_block = -1;
    const in_progress = -2;
    const already = -3;
    const no_memory = -4;
    const in_use = -5;
    const unreachable_ = -6;
    const is_connected = -7;
    const not_connected = -8;
    const reset = -9;
    const aborted = -10;
    const timed_out = -11;
    const invalid = -12;
    const shut_down = -13;
    const too_big = -14;
    const refused = -16;
    // zn_socket_state bits
    const readable = 1;
    const writable = 2;
    const hangup = 4;
    const failed = 8;
    const connecting = 16;
    const connected = 32;
    // zn_ping_result
    const ping_waiting = 1;
    const ping_reply = 2;
    const ping_unreachable = 3;
    const ping_ttl_expired = 4;
};

const glue = struct {
    extern fn zn_start(dns: *const [8]u32, forwarding: c_int) void;
    extern fn zn_add(s: *const Setup) c_int;
    extern fn zn_link(card: c_int, up: c_int) void;
    extern fn zn_input(card: c_int, frame: [*]const u8, len: usize) void;
    extern fn zn_timers() void;
    extern fn zn_sleeptime() c_uint;
    extern fn zn_config(iface: c_int, c: *Config) c_int;
    extern fn zn_interface(iface: c_int) *const anyopaque;
    extern fn zn_dhcp_renew(iface: c_int) void;
    extern fn zn_dhcp_release(iface: c_int) void;
    extern fn zn_route_add(dest: u32, mask: u32, gateway: u32) c_int;
    extern fn zn_route_entry(i: c_int, dest: *u32, mask: *u32, gateway: *u32, iface: *c_int) c_int;
    extern fn zn_dns_start(name: [*:0]const u8) c_int;
    extern fn zn_dns_object(q: c_int) *const anyopaque;
    extern fn zn_dns_result(q: c_int, addr: *u32) c_int;
    extern fn zn_dns_end(q: c_int) void;
    extern fn zn_ping_send(dst: u32, id: u16, seq: u16, size: u16, ttl: u8) c_int;
    extern fn zn_ping_object(n: c_int) *const anyopaque;
    extern fn zn_ping_result(n: c_int, out: *PingResult) c_int;
    extern fn zn_ping_end(n: c_int) void;
    extern fn zn_arp_entry(i: c_int, ip: *u32, mac: *[6]u8, is_static: *c_int) c_int;
    extern fn zn_arp_size() c_int;
    extern fn zn_arp_add(ip: u32, mac: *const [6]u8) c_int;
    extern fn zn_arp_remove(ip: u32) c_int;
    extern fn zn_arp_clear() void;
    extern fn zn_socket_new(kind: c_int) ?*ZSocket;
    extern fn zn_socket_error(s: *ZSocket) c_int;
    extern fn zn_socket_bind(s: *ZSocket, ip: u32, port: u16) c_int;
    extern fn zn_socket_listen(s: *ZSocket, backlog: c_int) c_int;
    extern fn zn_socket_accept(s: *ZSocket) ?*ZSocket;
    extern fn zn_socket_connect(s: *ZSocket, ip: u32, port: u16) c_int;
    extern fn zn_socket_send(s: *ZSocket, buf: [*]const u8, len: c_int) c_int;
    extern fn zn_socket_send_to(s: *ZSocket, buf: [*]const u8, len: c_int, ip: u32, port: u16) c_int;
    extern fn zn_socket_recv(s: *ZSocket, buf: [*]u8, len: c_int, peek: c_int) c_int;
    extern fn zn_socket_send_via(s: *ZSocket, buf: [*]const u8, len: c_int, ip: u32, port: u16, iface: c_int, src: u32) c_int;
    extern fn zn_socket_recv_via(s: *ZSocket, buf: [*]u8, len: c_int, peek: c_int, ip: ?*u32, port: ?*u16, iface: ?*c_int, local: ?*u32) c_int;
    extern fn zn_socket_shutdown(s: *ZSocket, rd: c_int, wr: c_int) c_int;
    extern fn zn_socket_close(s: *ZSocket) void;
    extern fn zn_socket_state(s: *ZSocket) c_int;
    extern fn zn_socket_address(s: *ZSocket, peer: c_int, ip: *u32, port: *u16) c_int;
    extern fn zn_socket_option(s: *ZSocket, option: c_int, value: c_int) c_int;
    extern fn zn_connection(index: c_int, out: *Conn) c_int;
    extern fn zn_flush() void;
    extern fn zn_loop_waiting() c_int;
    extern fn zn_loop() c_int;
    extern fn zn_is_object(p: *const anyopaque) c_int;
    extern var zn_defer: c_int;
};

// The calls from core 0, under the lock
const zn_start = Locked(glue.zn_start).call;
const zn_add = Locked(glue.zn_add).call;
const zn_route_add = Locked(glue.zn_route_add).call;
const zn_route_entry = Locked(glue.zn_route_entry).call;
const zn_link = Locked(glue.zn_link).call;
const zn_input = Locked(glue.zn_input).call;
const zn_timers = Locked(glue.zn_timers).call;
const zn_sleeptime = Locked(glue.zn_sleeptime).call;
const zn_config = Locked(glue.zn_config).call;
const zn_interface = Locked(glue.zn_interface).call;
const zn_dhcp_renew = Locked(glue.zn_dhcp_renew).call;
const zn_dhcp_release = Locked(glue.zn_dhcp_release).call;
const zn_dns_start = Locked(glue.zn_dns_start).call;
const zn_dns_object = Locked(glue.zn_dns_object).call;
const zn_dns_result = Locked(glue.zn_dns_result).call;
const zn_dns_end = Locked(glue.zn_dns_end).call;
const zn_ping_send = Locked(glue.zn_ping_send).call;
const zn_ping_object = Locked(glue.zn_ping_object).call;
const zn_ping_result = Locked(glue.zn_ping_result).call;
const zn_ping_end = Locked(glue.zn_ping_end).call;
const zn_arp_entry = Locked(glue.zn_arp_entry).call;
const zn_arp_size = Locked(glue.zn_arp_size).call;
const zn_arp_add = Locked(glue.zn_arp_add).call;
const zn_arp_remove = Locked(glue.zn_arp_remove).call;
const zn_arp_clear = Locked(glue.zn_arp_clear).call;
const zn_socket_new = Locked(glue.zn_socket_new).call;
const zn_socket_error = Locked(glue.zn_socket_error).call;
const zn_socket_bind = Locked(glue.zn_socket_bind).call;
const zn_socket_listen = Locked(glue.zn_socket_listen).call;
const zn_socket_accept = Locked(glue.zn_socket_accept).call;
const zn_socket_connect = Locked(glue.zn_socket_connect).call;
const zn_socket_send = Locked(glue.zn_socket_send).call;
const zn_socket_send_via = Locked(glue.zn_socket_send_via).call;
const zn_socket_recv = Locked(glue.zn_socket_recv).call;
const zn_socket_recv_via = Locked(glue.zn_socket_recv_via).call;
const zn_socket_shutdown = Locked(glue.zn_socket_shutdown).call;
const zn_socket_close = Locked(glue.zn_socket_close).call;
const zn_socket_state = Locked(glue.zn_socket_state).call;
const zn_socket_address = Locked(glue.zn_socket_address).call;
const zn_socket_option = Locked(glue.zn_socket_option).call;
const zn_connection = Locked(glue.zn_connection).call;

// f with the lock held
fn Locked(comptime f: anytype) type {
    const fn_info = @typeInfo(@TypeOf(f)).@"fn";
    const R = fn_info.return_type.?;
    const p = fn_info.params;
    return struct {
        pub const call = switch (p.len) {
            0 => struct {
                fn w() R {
                    lock();
                    defer unlockAfter();
                    return f();
                }
            }.w,
            1 => struct {
                fn w(a: p[0].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a);
                }
            }.w,
            2 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b);
                }
            }.w,
            3 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d);
                }
            }.w,
            4 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d, e);
                }
            }.w,
            5 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d, e, g);
                }
            }.w,
            6 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?, h: p[5].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d, e, g, h);
                }
            }.w,
            7 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?, h: p[5].type.?, i: p[6].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d, e, g, h, i);
                }
            }.w,
            8 => struct {
                fn w(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?, h: p[5].type.?, i: p[6].type.?, j: p[7].type.?) R {
                    lock();
                    defer unlockAfter();
                    return f(a, b, d, e, g, h, i, j);
                }
            }.w,
            else => @compileError("add a case"),
        };
    };
}

// THE NETWORK CORE: THE LOCK, NEWS FOR CORE 0

// Spin lock while the network core runs (`shared`); else the
// kernel lock alone keeps lwIP to one caller
var shared = false;
var lock_word = std.atomic.Value(u32).init(0);
var core_holds = false; // the network core has the lock: its wakes are its own
var direct = false; // it wakes tasks itself (tasks.allowOutsideWakes), else news to core 0

// Interrupts off while held: a task holding it may
// not be switched away from (ZDOS's code is
// preemptible) while the network core spins for it.
// Waiting for it, interrupts stay on: the network
// core may hold it for a batch of frames.
var lock_flags: usize = 0;

fn lock() void {
    if (!shared) return;
    while (true) {
        const was = if (platform.has_switching) platform.switching.disable() else 0;
        if (lock_word.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) {
            lock_flags = was;
            return;
        }
        if (platform.has_switching) platform.switching.restore(was);
        while (lock_word.load(.monotonic) != 0) std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    if (!shared) return;
    const was = lock_flags;
    lock_word.store(0, .release);
    if (platform.has_switching) platform.switching.restore(was);
}

// After a call from core 0: what lwIP sent itself (127.0.0.1,
// an own address) is delivered now, not
// at a timer, and its waiters woken here
fn unlockAfter() void {
    _ = glue.zn_loop();
    unlock();
}

// News: objects to wake on core 0, from the network core.
// A ring of them (one writer, one reader), a counter of all
// events (waitOn compares it), and
// whether core 0 was told already.
const ring_size = 256;
var ring: [ring_size]*const anyopaque = undefined;
var ring_in = std.atomic.Value(u32).init(0);
var ring_out = std.atomic.Value(u32).init(0);
var overflow = std.atomic.Value(bool).init(false);
var told = std.atomic.Value(bool).init(false);
var news_count = std.atomic.Value(u32).init(0);

fn news() u32 {
    return news_count.load(.acquire);
}

// On the network core: obj's waiters to
// wake (once, if it's waiting already)
fn post(obj: *const anyopaque) void {
    _ = news_count.fetchAdd(1, .acq_rel);
    const out = ring_out.load(.acquire);
    const in = ring_in.load(.monotonic);
    var i = out;
    while (i != in) : (i +%= 1) {
        if (ring[i % ring_size] == obj) return tell();
    }
    if (in -% out >= ring_size) {
        overflow.store(true, .release);
    } else {
        ring[in % ring_size] = obj;
        ring_in.store(in +% 1, .release);
    }
    tell();
}

fn tell() void {
    if (!platform.has_net_core) return;
    if (!told.swap(true, .acq_rel)) platform.net_core.tellMain();
}

// Core 0, interrupts off (its timer tick, or the network core's IPI)
fn takeNews() void {
    if (!told.load(.acquire)) return;
    told.store(false, .release);
    var out = ring_out.load(.monotonic);
    const in = ring_in.load(.acquire);
    while (out != in) : (out +%= 1) {
        tasks.wake(ring[out % ring_size]);
        queues.notify(ring[out % ring_size]);
    }
    ring_out.store(out, .release);
    if (overflow.swap(false, .acq_rel)) {
        tasks.wakeWhere(&isNetObject);
        queues.notifyWhere(&isNetObject);
    }
}

fn isNetObject(obj: *const anyopaque) bool {
    return glue.zn_is_object(obj) != 0;
}

// Core 0 has queued output or opened a window:
// the network core sends it
var kicked = std.atomic.Value(bool).init(false);

fn kick() void {
    if (!platform.has_net_core) return;
    if (shared and !kicked.swap(true, .acq_rel)) platform.net_core.wake();
}

// WHAT GLUE.C CALLS

comptime {
    if (available) {
        @export(&wake, .{ .name = "zdos_net_wake" });
        @export(&linkSend, .{ .name = "zdos_net_link_send" });
        @export(&millis32, .{ .name = "zdos_net_millis" });
        @export(&random, .{ .name = "zdos_net_random" });
        @export(&assertFailed, .{ .name = "zdos_net_assert" });
    }
}

fn wake(obj: *const anyopaque) callconv(.c) void {
    if (!core_holds) {
        tasks.wake(obj);
        return queues.notify(obj);
    }
    if (!direct) return post(obj);
    // The network core wakes them itself; the count first (waitOn compares)
    _ = news_count.fetchAdd(1, .acq_rel);
    tasks.wakeFromOutside(obj);
    queues.notifyFromOutside(obj);
}

// Per card
var tx_frames: [card_io.max]u64 = @splat(0);
var rx_frames: [card_io.max]u64 = @splat(0);

fn linkSend(c: c_int, frame: [*]const u8, len: usize) callconv(.c) c_int {
    const i: usize = @intCast(c);
    if (!card_io.send(i, frame[0..len])) return 0;
    tx_frames[i] += 1;
    return 1;
}

fn millis32() callconv(.c) c_uint {
    return @truncate(platform.clock.millis());
}

var seed: u64 = 0;

// xorshift64*, seeded from the CPU's counter
// (TCP sequence numbers, DNS ids, ports)
fn random() callconv(.c) c_uint {
    if (seed == 0) seed = arch.timestamp() | 1;
    seed ^= seed >> 12;
    seed ^= seed << 25;
    seed ^= seed >> 27;
    return @truncate((seed *% 0x2545F4914F6CDD1D) >> 32);
}

fn assertFailed(what: [*:0]const u8, line: c_int, file: [*:0]const u8) callconv(.c) void {
    con.printf("lwIP: {s} ({s}:{d})\n", .{ what, file, line });
}

// ERRORS

pub const Error = error{
    NoNetwork,
    WouldBlock,
    InProgress,
    Already,
    OutOfMemory,
    TooManyOpen,
    AddressInUse,
    HostUnreachable,
    IsConnected,
    NotConnected,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    BrokenPipe,
    TimedOut,
    InvalidArgument,
    MessageTooLong,
    HostNotFound,
    Interrupted,
    Failed,
};

pub fn errorCode(err: Error) abi.ErrorCode {
    return switch (err) {
        error.NoNetwork => .network_down,
        error.WouldBlock => .would_block,
        error.InProgress => .in_progress,
        error.Already => .already,
        error.OutOfMemory => .out_of_memory,
        error.TooManyOpen => .too_many_open,
        error.AddressInUse => .address_in_use,
        error.HostUnreachable => .host_unreachable,
        error.IsConnected => .is_connected,
        error.NotConnected => .not_connected,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionReset => .connection_reset,
        error.ConnectionAborted => .connection_aborted,
        error.BrokenPipe => .broken_pipe,
        error.TimedOut => .timed_out,
        error.InvalidArgument => .invalid_argument,
        error.MessageTooLong => .message_too_long,
        error.HostNotFound => .host_not_found,
        error.Interrupted => .interrupted,
        error.Failed => .device_error,
    };
}

fn fromZn(r: c_int) Error {
    return switch (r) {
        ZN.would_block => error.WouldBlock,
        ZN.in_progress => error.InProgress,
        ZN.already => error.Already,
        ZN.no_memory => error.OutOfMemory,
        ZN.in_use => error.AddressInUse,
        ZN.unreachable_ => error.HostUnreachable,
        ZN.is_connected => error.IsConnected,
        ZN.not_connected => error.NotConnected,
        ZN.reset => error.ConnectionReset,
        ZN.aborted => error.ConnectionAborted,
        ZN.timed_out => error.TimedOut,
        ZN.invalid => error.InvalidArgument,
        ZN.shut_down => error.BrokenPipe,
        ZN.too_big => error.MessageTooLong,
        ZN.refused => error.ConnectionRefused,
        else => error.Failed,
    };
}

// STARTING

var running = false;
var on_core = false; // lwIP runs on the network core
var own_core = false; // claimed for it at start
// Asked while waiting: whether the program wants to stop (Ctrl+C)
var stop_wanted: *const fn () bool = &never;

// The interfaces, numbered as glue.c's:
// a card each, or a bridge of cards
const Iface = struct {
    number: u8, // NETn's n (a bridge: its first card's)
    ports: [card_io.max]u8, // cards
    port_count: u8,
    static_ip: bool,
};
var ifaces: [card_io.max]Iface = undefined;
var iface_count: usize = 0;
var used: [card_io.max]bool = @splat(false); // the cards the interfaces have
var card_order: [card_io.max]u8 = undefined; // [k]: the card that is number k (NETk=)
var link_was: [card_io.max]bool = @splat(true);
var forwarding = false; // ROUTING=true
var all_interrupts = true; // every used card's interrupt arrives
var event: ?*platform.IoEvent = null; // the built-in cards' interrupt (core 0)
var all_events = true; // and every used card signals it

fn never() bool {
    return false;
}

pub fn active() bool {
    return available and running;
}

// NETCORE=: true or none (a core of its own: NETCPU='s,
// else the last), false (none)
fn claimCore(setting: ?[]const u8, cpu: ?u6) bool {
    if (!platform.has_net_core) return false;
    const v = std.mem.trim(u8, setting orelse "true", " \t");
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (!std.ascii.eqlIgnoreCase(v, "true")) {
        con.printf("SYSTEM.CFG: NETCORE={s}: true or false (NETCPU= picks the core); true taken\n", .{v});
    }
    var want: ?usize = if (cpu) |c| c else null;
    const n = platform.cores.count();
    // One core: none to claim; the task NET takes NETCPU=:
    if (want) |w| if (n >= 2 and (w == 0 or w >= n)) {
        con.printf("SYSTEM.CFG: NETCPU={d}: the network's own core is 1 up to {d}; the last taken\n", .{ w, n -| 1 });
        want = null;
    };
    return platform.net_core.claim(&takeNews, want);
}

// NETCPU=: the network's core, its own or the task NET's
fn cpuNumber(setting: ?[]const u8) ?u6 {
    const v = std.mem.trim(u8, setting orelse return null, " \t");
    return std.fmt.parseInt(u6, v, 10) catch {
        con.printf("SYSTEM.CFG: NETCPU={s}: a core's number (0 and up); ignored\n", .{v});
        return null;
    };
}

fn isTrue(v: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "true");
}

// At startup, after SYSTEM.CFG: NETWORK=true starts
// the cards and the loopback (without a card:
// the loopback alone). Cards are numbered from 0:
// card 0 takes NET0=, else IPV4= (DHCP or none:
// DHCP) with NETMASK= and ROUTER=; card n NETn= (none:
// unused). BRIDGE= joins cards, ROUTING=true forwards
// between the interfaces, ROUTE= adds routes, DNS=
// names up to 8 DNS servers. stop: whether a waiting
// program wants to stop (Ctrl+C).
pub fn start(get: *const fn (name: []const u8) ?[]const u8, stop: *const fn () bool) void {
    if (!available) return;
    const on = get("NETWORK") orelse return;
    if (!isTrue(on)) return;
    stop_wanted = stop;
    // The network core first: the cards' interrupts are sent there
    const cpu = cpuNumber(get("NETCPU"));
    own_core = platform.has_net_core and card_io.present() and claimCore(get("NETCORE"), cpu);
    // NETPOLLED=true: the cards polled, interrupts unused
    const polled = platform.net_polled or (if (get("NETPOLLED")) |v| isTrue(v) else false);
    const how: platform.NetInterrupt = if (polled)
        .none
    else if (platform.has_net_core and own_core)
        (if (platform.net_core.msiMessage()) |m| .{ .message = m } else if (platform.net_core.relays) .relay else .none)
    else
        .core0;
    card_io.start(how);
    if (card_io.count == 0) con.print("Network: no network card found (loopback only)\n");
    var dns: [8]u32 = @splat(0);
    if (get("DNS")) |text| {
        var it = std.mem.tokenizeAny(u8, text, " ,;");
        var n: usize = 0;
        while (it.next()) |a| {
            if (n == dns.len) break;
            dns[n] = parseAddress(a) orelse continue;
            n += 1;
        }
    }
    forwarding = if (get("ROUTING")) |v| isTrue(v) else get("NAT") != null;
    zn_start(&dns, @intFromBool(forwarding));
    if (card_io.count > 0) {
        configure(get);
        if (iface_count == 0) con.print("Network: no card is used (NETn=OFF); loopback only\n");
        addRoutes(get);
        lan.start(get);
    }
    for (0..card_io.count) |c| {
        if (!used[c]) continue;
        const k = &card_io.cards[c];
        if (!k.interrupts) all_interrupts = false;
        // One event is waited on: cards with different ones are polled
        if (k.event) |ev| {
            if (event != null and event.? != ev) all_events = false;
            event = ev;
        } else all_events = false;
    }
    running = true;
    loadHosts();
    if (platform.has_net_core and own_core) {
        glue.zn_defer = 1;
        shared = true;
        direct = tasks.allowOutsideWakes();
        if (!direct) tasks.tick_hook = &takeNews;
        platform.net_core.run(&coreLoop);
        on_core = true;
    } else if (platform.has_switching and tasks.active()) {
        // NETPRIO= (0-31, default 20) and NETCPU= (a core): the
        // network task's place among the real-time ones
        const prio: u8 = if (get("NETPRIO")) |v| std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10) catch 20 else 20;
        if (tasks.kernelTask(&taskMain, 0, "NET", @min(prio, tasks.priorities - 1))) |id| {
            net_task = id;
            net_core_wanted = cpu;
        } else {
            con.print("Network: no task for it; polled instead\n");
            platform.idle.hook = &idlePoll;
        }
    } else {
        platform.idle.hook = &idlePoll;
    }
    report();
    lan.report();
}

var net_task: u32 = 0;
var net_core_wanted: ?u6 = null;

// After the other cores joined (startup): NETCPU= pins the network task
pub fn placeTask() void {
    const core = net_core_wanted orelse return;
    if (net_task == 0 or !tasks.setAffinity(net_task, @as(u64, 1) << core)) con.printf("SYSTEM.CFG: NETCPU={d}: no such core\n", .{core});
}

// One card's NETn= (or, for card 0, IPV4= ...)
const CardSettings = struct {
    given: bool = true,
    off: bool = false,
    dhcp: bool = true,
    ip: u32 = 0,
    mask: u32 = 0,
    gateway: u32 = 0,
    mac: ?[6]u8 = null,
};

fn cardSettings(get: *const fn (name: []const u8) ?[]const u8, number: usize) CardSettings {
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "NET{d}", .{number}) catch unreachable;
    if (get(name)) |text| return parseCard(name, text);
    if (number != 0) return .{ .given = false };
    var s: CardSettings = .{};
    const ip_text: ?[]const u8 = if (get("IPV4")) |t| (if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), "dhcp")) null else t) else null;
    const text = ip_text orelse return s;
    s.ip = parseAddress(text) orelse {
        con.printf("SYSTEM.CFG: IPV4={s} is not an address; using DHCP\n", .{text});
        return s;
    };
    s.mask = if (get("NETMASK")) |m| parseAddress(m) orelse maskOf(24) else maskOf(24);
    s.gateway = if (get("ROUTER")) |g| parseAddress(g) orelse 0 else 0;
    s.dhcp = false;
    return s;
}

// "DHCP" | "OFF" | ADDRESS[/BITS | /MASK]
// [ROUTER], and the card's MAC, in any order
fn parseCard(name: []const u8, text: []const u8) CardSettings {
    var s: CardSettings = .{};
    var have_ip = false;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, "dhcp")) {
            s.dhcp = true;
        } else if (std.ascii.eqlIgnoreCase(w, "off")) {
            s.off = true;
        } else if (parseMac(w)) |m| {
            s.mac = m;
        } else if (!have_ip and parseSubnet(w, 24) != null) {
            const sub = parseSubnet(w, 24).?;
            s.ip = sub.addr;
            s.mask = sub.mask;
            s.dhcp = false;
            have_ip = true;
        } else if (have_ip and s.gateway == 0 and parseAddress(w) != null) {
            s.gateway = parseAddress(w).?;
        } else {
            con.printf("SYSTEM.CFG: {s}= doesn't know \"{s}\"\n", .{ name, w });
        }
    }
    return s;
}

// The interfaces: card numbers (as found,
// or by NETn='s MAC), BRIDGE=, NETn=
fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    const n = card_io.count;
    var settings: [card_io.max]CardSettings = undefined;
    for (0..n) |k| settings[k] = cardSettings(get, k);
    // Numbered from 0: a NETn= past the last card (an old
    // NET1-based setting?) says so
    for (n..card_io.max + 1) |k| {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "NET{d}", .{k}) catch unreachable;
        if (get(name) != null) con.printf("SYSTEM.CFG: {s}=: no card {d} (cards are numbered from 0; there are {d})\n", .{ name, k, n });
    }
    const order = &card_order;
    var claimed: [card_io.max]bool = @splat(false);
    var placed: [card_io.max]bool = @splat(false);
    for (0..n) |k| {
        const m = settings[k].mac orelse continue;
        for (card_io.cards[0..n], 0..) |c, ci| {
            if (claimed[ci] or !std.mem.eql(u8, &c.mac, &m)) continue;
            order[k] = @intCast(ci);
            claimed[ci] = true;
            placed[k] = true;
            break;
        } else {
            var b: [48]u8 = undefined;
            con.printf("SYSTEM.CFG: NET{d}=: no card has {s}\n", .{ k, macText(m, &b) });
        }
    }
    var next: usize = 0;
    for (0..n) |k| {
        if (placed[k]) continue;
        while (claimed[next]) next += 1;
        order[k] = @intCast(next);
        claimed[next] = true;
    }
    // BRIDGE=0,1: those cards, the first one's settings
    var bridge: [card_io.max]u8 = undefined;
    var bridge_len: usize = 0;
    if (get("BRIDGE")) |text| {
        var it = std.mem.tokenizeAny(u8, text, " \t,;");
        while (it.next()) |w| {
            const num = std.fmt.parseInt(u8, w, 10) catch 255;
            if (num >= n or std.mem.indexOfScalar(u8, bridge[0..bridge_len], num) != null) {
                con.printf("SYSTEM.CFG: BRIDGE=: no card {s}\n", .{w});
                continue;
            }
            bridge[bridge_len] = num;
            bridge_len += 1;
        }
        if (bridge_len < 2) {
            if (bridge_len == 1) con.print("SYSTEM.CFG: BRIDGE= needs two cards or more\n");
            bridge_len = 0;
        }
    }
    for (0..n) |k| {
        const in_bridge = std.mem.indexOfScalar(u8, bridge[0..bridge_len], @intCast(k)) != null;
        if (in_bridge and k != bridge[0]) continue; // joined to the first
        const s = settings[k];
        const c = &card_io.cards[order[k]];
        if (!s.given and !in_bridge) {
            var b: [48]u8 = undefined;
            con.printf("Network: card {d} ({s}, {s}) unused: no NET{d}= in SYSTEM.CFG\n", .{ k, c.name, macText(c.mac, &b), k });
            continue;
        }
        if (s.off) continue;
        var setup: Setup = .{ .mac = c.mac, .dhcp = @intFromBool(s.dhcp), .link_up = 0, .ip = s.ip, .mask = s.mask, .gateway = s.gateway };
        if (in_bridge) {
            for (bridge[0..bridge_len]) |num| addPort(&setup, order[num]);
        } else {
            addPort(&setup, order[k]);
        }
        const at = zn_add(&setup);
        if (at < 0) continue;
        const f = &ifaces[iface_count];
        f.* = .{ .number = @intCast(k), .ports = setup.ports, .port_count = setup.port_count, .static_ip = !s.dhcp };
        iface_count += 1;
        for (f.ports[0..f.port_count]) |p| used[p] = true;
        if (f.port_count > 1) {
            // A port hears the other machines' frames only if it takes every frame
            for (bridge[0..bridge_len]) |num| {
                if (card_io.promiscuous(order[num])) continue;
                con.printf("Network: card {d} ({s}) takes only its own frames: the bridge passes only broadcasts from its side\n", .{ num, card_io.cards[order[num]].name });
            }
        }
    }
}

fn addPort(setup: *Setup, card: u8) void {
    setup.ports[setup.port_count] = card;
    setup.port_count += 1;
    const up = card_io.linkUp(card);
    link_was[card] = up;
    if (up) setup.link_up = 1;
}

// ROUTE=10.1.0.0/16 192.168.50.2, ...:
// networks and the routers that reach them
fn addRoutes(get: *const fn (name: []const u8) ?[]const u8) void {
    const text = get("ROUTE") orelse return;
    var it = std.mem.tokenizeAny(u8, text, ",;");
    while (it.next()) |one| {
        var words = std.mem.tokenizeAny(u8, one, " \t");
        const sub = parseSubnet(words.next() orelse continue, 32);
        const gw = if (words.next()) |g| parseAddress(g) else null;
        if (sub == null or gw == null or words.next() != null) {
            con.printf("SYSTEM.CFG: ROUTE= doesn't know \"{s}\" (NETWORK/BITS ROUTER)\n", .{std.mem.trim(u8, one, " \t")});
            continue;
        }
        if (zn_route_add(sub.?.addr, sub.?.mask, gw.?) == 0) {
            con.print("SYSTEM.CFG: ROUTE= has more than 16 routes\n");
            return;
        }
    }
}

// The startup lines: one per interface
fn report() void {
    for (ifaces[0..iface_count], 0..) |*f, i| {
        var nb: [32]u8 = undefined;
        var mb: [48]u8 = undefined;
        if (card_io.count > 1) con.printf("Network {d}: ", .{f.number}) else con.print("Network: ");
        const c = &card_io.cards[f.ports[0]];
        con.printf("{s}, {s}, {s}", .{ ifaceName(f, &nb), macText(c.mac, &mb), if (on_core and i == 0) "own CPU core, " else "" });
        var cf: Config = undefined;
        _ = zn_config(@intCast(i), &cf);
        if (!f.static_ip) {
            con.print("address by DHCP\n");
        } else {
            var b2: [16]u8 = undefined;
            con.printf("address {s}/{d}\n", .{ addressText(cf.ip, &b2), @popCount(cf.mask) });
        }
    }
    if (forwarding) con.print("Network: routing between the interfaces\n");
}

// A card's name; a bridge: "Bridge of 1, 2"
fn ifaceName(f: *const Iface, buf: *[32]u8) []const u8 {
    if (f.port_count == 1) {
        const name = card_io.cards[f.ports[0]].name;
        return name[0..@min(name.len, buf.len)];
    }
    const head = "Bridge of ";
    @memcpy(buf[0..head.len], head);
    var len: usize = head.len;
    for (f.ports[0..f.port_count], 0..) |p, k| {
        const part = std.fmt.bufPrint(buf[len..], "{s}{d}", .{ if (k > 0) ", " else "", numberOf(p) }) catch break;
        len += part.len;
    }
    return buf[0..len];
}

// For lan.zig: the interface of card
// number n (a bridge: its first card's)
pub const Lan = struct { index: usize, static_ip: bool, ip: u32, mask: u32 };

pub fn interfaceNumbered(n: usize) ?Lan {
    for (ifaces[0..iface_count], 0..) |f, i| {
        if (f.number != n) continue;
        var cf: Config = undefined;
        _ = glue.zn_config(@intCast(i), &cf);
        return .{ .index = i, .static_ip = f.static_ip, .ip = cf.ip, .mask = cf.mask };
    }
    return null;
}

pub fn interfaceCount() usize {
    return iface_count;
}

// A card's number (NETn's n)
fn numberOf(card: u8) usize {
    return std.mem.indexOfScalar(u8, card_order[0..card_io.count], card) orelse 0;
}

// RUNNING

var rx_buf: [1600]u8 align(8) = undefined;
var busy = false;

// Received frames into lwIP, its timers;
// the kernel lock held (or no tasks)
fn pollNow() void {
    if (!available) return;
    if (busy) return;
    busy = true;
    defer busy = false;
    for (0..card_io.count) |c| {
        if (!used[c]) {
            drain(c);
            continue;
        }
        var n: usize = 0;
        while (n < 128) : (n += 1) {
            const len = card_io.receive(c, &rx_buf) orelse break;
            rx_frames[c] += 1;
            zn_input(@intCast(c), &rx_buf, len);
        }
        const up = card_io.linkUp(c);
        if (up != link_was[c]) {
            link_was[c] = up;
            zn_link(@intCast(c), @intFromBool(up));
        }
    }
    zn_timers();
}

// A started card no interface has: its frames dropped, so that
// its ring doesn't fill (and keep interrupting)
fn drain(c: usize) void {
    var n: usize = 0;
    while (n < 128 and card_io.receive(c, &rx_buf) != null) n += 1;
}

var last_poll: u64 = 0;

// UEFI: from the firmware waits and the key polling;
// at most once a millisecond
fn idlePoll() void {
    const now = platform.clock.millis();
    if (now == last_poll) return;
    last_poll = now;
    pollNow();
}

// Metal: woken by the cards' interrupt, or when lwIP's next
// timer is due; a card without
// interrupts is looked at every 2 ms
var no_interrupts: platform.IoEvent = .{};

fn taskMain(_: usize) callconv(.c) noreturn {
    const ev = event orelse &no_interrupts;
    const longest: u32 = if (all_events) 250 else 2;
    while (true) {
        const seen = ev.count;
        const took = tasks.enterKernel();
        pollNow();
        const due: u32 = @min(zn_sleeptime(), longest);
        if (took) tasks.leaveKernel();
        card_io.rearm();
        _ = platform.io.wait.?(ev, seen, @max(due, 1) * 1000);
    }
}

// The network core's life: frames in (a batch per card and
// lock), lwIP's timers, what core 0 queued out; then sleep
// until a card, core 0 or the next timer
// wakes it (polled cards: 2 ms at most)
const batch = 16;
var core_bufs: [batch][1600]u8 align(8) = undefined;
var core_lens: [batch]usize = undefined;

fn coreLoop() noreturn {
    const longest: u32 = if (all_interrupts) 250 else 2;
    while (true) {
        kicked.store(false, .release);
        card_io.acknowledge();
        var worked = false;
        var rounds: usize = 0;
        while (rounds < 16) : (rounds += 1) {
            var got = false;
            for (0..card_io.count) |c| {
                if (!used[c]) {
                    drain(c);
                    continue;
                }
                var n: usize = 0;
                while (n < batch) : (n += 1) core_lens[n] = card_io.receive(c, &core_bufs[n]) orelse break;
                if (n == 0) continue;
                got = true;
                holdLock();
                for (0..n) |i| glue.zn_input(@intCast(c), &core_bufs[i], core_lens[i]);
                releaseLock();
                rx_frames[c] += n;
            }
            if (!got) break;
            worked = true;
        }
        holdLock();
        for (0..card_io.count) |c| {
            if (!used[c]) continue;
            const up = card_io.linkUp(c);
            if (up != link_was[c]) {
                link_was[c] = up;
                glue.zn_link(@intCast(c), @intFromBool(up));
            }
        }
        glue.zn_timers();
        glue.zn_flush();
        if (glue.zn_loop() != 0) worked = true;
        const due: u32 = @min(glue.zn_sleeptime(), longest);
        releaseLock();
        if (worked or kicked.load(.acquire)) continue;
        card_io.rearm();
        platform.net_core.sleep(@max(due, 1) * 1000);
    }
}

fn holdLock() void {
    lock();
    core_holds = true;
}

fn releaseLock() void {
    core_holds = false;
    unlock();
}

// Waits about ms for obj to be woken (an event, a
// reply ...), unless news came since `seen`
// (news() before the caller looked);
// Interrupted by a signal or Ctrl+C. Without tasks
// the network moves only here.
fn waitOn(obj: *const anyopaque, ms: u32, seen: u32) Error!void {
    if (stop_wanted()) return error.Interrupted;
    if (on_core) {
        if (!tasks.waitObjectSince(obj, @max(ms, 1), &news_count, seen)) return error.Interrupted;
    } else if (tasks.active()) {
        if (!tasks.waitObject(obj, @max(ms, 1))) return error.Interrupted;
    } else {
        pollNow();
        if (ms > 0) platform.clock.sleep(1);
    }
    if (stop_wanted()) return error.Interrupted;
}

// A deadline in milliseconds since startup (null: none)
const Deadline = struct {
    end: ?u64,

    fn in(ms: u32) Deadline {
        return .{ .end = if (ms == 0) null else platform.clock.millis() + ms };
    }

    // The wait's next step (Ctrl+C is looked at between steps), or TimedOut
    fn step(self: Deadline) Error!u32 {
        const end = self.end orelse return 50;
        const now = platform.clock.millis();
        if (now >= end) return error.TimedOut;
        return @intCast(@min(end - now, 50));
    }
};

// ADDRESSES

pub fn parseAddress(text: []const u8) ?u32 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t"), '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (i != 4) return null;
    return @bitCast(out);
}

const Subnet = struct { addr: u32, mask: u32 };

// ADDRESS/BITS, ADDRESS/MASK, OR ADDRESS (default_bits)
pub fn parseSubnet(text: []const u8, default_bits: u6) ?Subnet {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse
        return .{ .addr = parseAddress(text) orelse return null, .mask = maskOf(default_bits) };
    const addr = parseAddress(text[0..slash]) orelse return null;
    const rest = text[slash + 1 ..];
    if (parseAddress(rest)) |m| return .{ .addr = addr, .mask = m };
    const bits = std.fmt.parseInt(u6, rest, 10) catch return null;
    if (bits > 32) return null;
    return .{ .addr = addr, .mask = maskOf(bits) };
}

// A mask of `bits` ones, as addresses are kept
fn maskOf(bits: u6) u32 {
    const host: u32 = if (bits == 0) 0 else ~@as(u32, 0) << @as(u5, @intCast(32 - @as(u32, bits)));
    return std.mem.nativeToBig(u32, host);
}

// 52-54-00-12-34-56 or 52:54:00:12:34:56
pub fn parseMac(text: []const u8) ?[6]u8 {
    if (text.len != 17) return null;
    var mac: [6]u8 = undefined;
    for (&mac, 0..) |*b, i| {
        if (i > 0 and text[i * 3 - 1] != '-' and text[i * 3 - 1] != ':') return null;
        b.* = std.fmt.parseInt(u8, text[i * 3 ..][0..2], 16) catch return null;
    }
    return mac;
}

pub fn addressText(addr: u32, buf: *[16]u8) []const u8 {
    const b: [4]u8 = @bitCast(addr);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch unreachable;
}

fn macText(mac: [6]u8, buf: *[48]u8) []const u8 {
    return std.fmt.bufPrint(buf, "MAC {X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}-{X:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch unreachable;
}

// HOSTS.CFG

// \CONF\HOSTS.CFG of the boot drive, read at startup:
// "address name [aliases]" per line, # comments
const hosts_path = "\\CONF\\HOSTS.CFG";
var hosts_text: [8 * 1024]u8 = undefined;
var hosts_len: usize = 0;

fn loadHosts() void {
    const d = fs.bootDrive() orelse return;
    const f = fs.openFile(d, hosts_path, .read) catch return;
    defer fs.close(f);
    while (hosts_len < hosts_text.len) {
        const n = platform.storage.read(f, hosts_text[hosts_len..]) catch break;
        if (n == 0) break;
        hosts_len += n;
    }
    var more: [1]u8 = undefined;
    if (hosts_len == hosts_text.len and (platform.storage.read(f, &more) catch 0) > 0) {
        // Up to the last whole line only
        hosts_len = if (std.mem.lastIndexOfScalar(u8, &hosts_text, '\n')) |i| i + 1 else 0;
        con.print("HOSTS.CFG: only the first 8 KiB read\n");
    }
}

pub fn hostsLookup(name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, hosts_text[0..hosts_len], '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const addr = parseAddress(words.next() orelse continue) orelse continue;
        while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, name)) return addr;
        }
    }
    return null;
}

// NAMES

// An address as text, "localhost", a HOSTS.CFG name, then DNS
pub fn resolve(name: []const u8) Error!u32 {
    if (parseAddress(name)) |a| return a;
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return @bitCast([4]u8{ 127, 0, 0, 1 });
    if (hostsLookup(name)) |a| return a;
    if (!available or !active()) return error.NoNetwork;
    if (name.len == 0 or name.len > 255) return error.HostNotFound;
    var z: [256]u8 = undefined;
    @memcpy(z[0..name.len], name);
    z[name.len] = 0;
    const q = zn_dns_start(@ptrCast(&z));
    if (q < 0) return error.OutOfMemory;
    defer zn_dns_end(q);
    // lwIP gives up by itself after its retries (about 10 s)
    while (true) {
        const seen = news();
        var addr: u32 = 0;
        switch (zn_dns_result(q, &addr)) {
            1 => return addr,
            -1 => return error.HostNotFound,
            else => try waitOn(zn_dns_object(q), 50, seen),
        }
    }
}

// PING

pub const PingAnswer = struct {
    kind: enum { reply, unreachable_, ttl_expired },
    from: u32,
    rtt: u32,
    ttl: u8,
    bytes: u16,
};

// One echo request; TimedOut without an answer
pub fn ping(dst: u32, seq: u16, size: u16, ttl: u8, timeout_ms: u32) Error!PingAnswer {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    const id: u16 = @truncate(tasks.currentId());
    const n = zn_ping_send(dst, id, seq, size, ttl);
    if (n == -2) return error.HostUnreachable;
    if (n < 0) return error.OutOfMemory;
    defer zn_ping_end(n);
    const deadline = Deadline.in(@max(timeout_ms, 1));
    while (true) {
        const seen = news();
        var r: PingResult = undefined;
        const state = zn_ping_result(n, &r);
        if (state != ZN.ping_waiting) return .{
            .kind = switch (state) {
                ZN.ping_reply => .reply,
                ZN.ping_unreachable => .unreachable_,
                else => .ttl_expired,
            },
            .from = r.from,
            .rtt = r.rtt,
            .ttl = r.ttl,
            .bytes = r.bytes,
        };
        try waitOn(zn_ping_object(n), try deadline.step(), seen);
    }
}

// THE INTERFACE, ARP, CONNECTIONS

// The first interface (NET0's, or the first one used)
pub fn info(out: *abi.NetInfo) void {
    _ = interfaceInfo(0, out);
}

// The index-th interface (0 ...); false past the last
pub fn interfaceInfo(index: u32, out: *abi.NetInfo) bool {
    out.* = .{ .flags = 0 };
    if (!available or !active() or index >= iface_count) return false;
    const f = &ifaces[index];
    var c: Config = undefined;
    if (zn_config(@intCast(index), &c) == 0) return false;
    const F = abi.NetFlags;
    out.flags = F.started;
    if (c.link_up != 0) out.flags |= F.link;
    if (c.dhcp != 0) out.flags |= F.dhcp;
    if (c.dhcp_bound != 0) out.flags |= F.dhcp_bound;
    if (on_core) out.flags |= F.own_core;
    if (f.port_count > 1) out.flags |= F.bridge;
    if (forwarding) out.flags |= F.routing;
    if (c.is_default != 0 and c.gateway != 0) out.flags |= F.default_route;
    if (lan.isNat(f.number)) out.flags |= F.nat;
    for (f.ports[0..f.port_count]) |p| {
        const k = &card_io.cards[p];
        if (k.event) |ev| {
            if (ev.seen_interrupt) out.flags |= F.interrupts;
        } else if (k.interrupts) out.flags |= F.interrupts;
        out.rx_frames += rx_frames[p];
        out.tx_frames += tx_frames[p];
    }
    out.number = f.number;
    out.mac = c.mac;
    out.address = @bitCast(c.ip);
    out.netmask = @bitCast(c.mask);
    out.gateway = @bitCast(c.gateway);
    for (&out.dns, c.dns) |*d, s| d.* = @bitCast(s);
    out.dhcp_server = @bitCast(c.dhcp_server);
    out.lease_s = c.lease_s;
    var nb: [32]u8 = undefined;
    const name = ifaceName(f, &nb);
    const n = @min(name.len, out.card_buf.len);
    @memcpy(out.card_buf[0..n], name[0..n]);
    out.card_len = @intCast(n);
    return true;
}

// The index-th route: the interfaces'
// own networks, ROUTE='s, the default
pub fn route(index: u32, out: *abi.NetRoute) bool {
    if (!available or !active()) return false;
    const R = abi.RouteFlags;
    var k: u32 = 0;
    for (0..iface_count) |i| {
        var c: Config = undefined;
        if (zn_config(@intCast(i), &c) == 0 or c.ip == 0) continue;
        if (k == index) {
            out.* = .{ .destination = @bitCast(c.ip & c.mask), .netmask = @bitCast(c.mask), .interface = ifaces[i].number, .flags = R.link };
            return true;
        }
        k += 1;
    }
    var r: c_int = 0;
    while (true) : (r += 1) {
        var dest: u32 = 0;
        var mask: u32 = 0;
        var gw: u32 = 0;
        var at: c_int = -1;
        if (zn_route_entry(r, &dest, &mask, &gw, &at) == 0) break;
        if (k == index) {
            out.* = .{
                .destination = @bitCast(dest),
                .netmask = @bitCast(mask),
                .gateway = @bitCast(gw),
                .interface = if (at < 0) abi.NetRoute.none else ifaces[@intCast(at)].number,
                .flags = R.static_,
            };
            return true;
        }
        k += 1;
    }
    for (0..iface_count) |i| {
        var c: Config = undefined;
        if (zn_config(@intCast(i), &c) == 0 or c.is_default == 0 or c.gateway == 0) continue;
        if (k != index) return false;
        out.* = .{ .gateway = @bitCast(c.gateway), .interface = ifaces[i].number, .flags = R.default };
        return true;
    }
    return false;
}

// DHCP again on every interface that uses it: until they have
// an address, or timeout_ms
pub fn renew(timeout_ms: u32) Error!void {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    var any = false;
    for (ifaces[0..iface_count], 0..) |f, i| {
        if (f.static_ip) continue;
        zn_dhcp_renew(@intCast(i));
        any = true;
    }
    if (!any) return error.InvalidArgument;
    const deadline = Deadline.in(timeout_ms);
    while (true) {
        const seen = news();
        const waiting = for (ifaces[0..iface_count], 0..) |f, i| {
            if (f.static_ip) continue;
            var cf: Config = undefined;
            _ = zn_config(@intCast(i), &cf);
            if (cf.dhcp_bound == 0) break i;
        } else return;
        try waitOn(zn_interface(@intCast(waiting)), try deadline.step(), seen);
    }
}

pub fn releaseAddress() Error!void {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    var any = false;
    for (ifaces[0..iface_count], 0..) |f, i| {
        if (f.static_ip) continue;
        zn_dhcp_release(@intCast(i));
        any = true;
    }
    if (!any) return error.InvalidArgument;
}

// The index-th entry ARP knows (empty slots skipped)
pub fn arpEntry(index: u32, out: *abi.ArpEntry) bool {
    if (!available) return false;
    if (!active()) return false;
    var seen: u32 = 0;
    var i: c_int = 0;
    while (i < zn_arp_size()) : (i += 1) {
        var ip: u32 = 0;
        var mac: [6]u8 = undefined;
        var is_static: c_int = 0;
        if (zn_arp_entry(i, &ip, &mac, &is_static) == 0) continue;
        if (seen == index) {
            out.* = .{ .address = @bitCast(ip), .mac = mac, .is_static = is_static != 0 };
            return true;
        }
        seen += 1;
    }
    return false;
}

pub fn arpAdd(addr: u32, mac: *const [6]u8) Error!void {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    if (zn_arp_add(addr, mac) == 0) return error.OutOfMemory;
}

// null: all entries
pub fn arpRemove(addr: ?u32) Error!void {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    const a = addr orelse return zn_arp_clear();
    if (zn_arp_remove(a) == 0) return error.HostNotFound;
}

pub fn connection(index: u32, out: *abi.Connection) bool {
    if (!available) return false;
    if (!active() or index > std.math.maxInt(c_int)) return false;
    var c: Conn = undefined;
    if (zn_connection(@intCast(index), &c) == 0) return false;
    out.* = .{
        .proto = c.proto,
        .state = c.state,
        .local = .{ .addr = @bitCast(c.local), .port = c.local_port },
        .remote = .{ .addr = @bitCast(c.remote), .port = c.remote_port },
        .rx_queued = c.rx_queued,
        .tx_queued = c.tx_queued,
    };
    return true;
}

// SOCKETS

// A socket of a program's handles (api.zig), counted (dup)
pub const Socket = struct {
    z: *ZSocket,
    refs: u32 = 1,
    stream: bool,
    nonblock: bool = false,
    recv_timeout: u32 = 0, // ms; 0: none
    send_timeout: u32 = 0,
};

pub fn socket(stream: bool) Error!*Socket {
    if (!available) return error.NoNetwork;
    if (!active()) return error.NoNetwork;
    const z = zn_socket_new(if (stream) ZN.tcp else ZN.udp) orelse return error.TooManyOpen;
    return wrap(z, stream);
}

fn wrap(z: *ZSocket, stream: bool) Error!*Socket {
    const mem = platform.memory.alloc(@sizeOf(Socket)) orelse {
        zn_socket_close(z);
        return error.OutOfMemory;
    };
    const s: *Socket = @ptrCast(@alignCast(mem));
    s.* = .{ .z = z, .stream = stream };
    return s;
}

pub fn release(s: *Socket) void {
    if (!available) return;
    s.refs -= 1;
    if (s.refs > 0) return;
    zn_socket_close(s.z);
    platform.memory.free(@ptrCast(@alignCast(s)));
}

fn check(r: c_int) Error!void {
    if (r < 0) return fromZn(r);
}

pub fn bind(s: *Socket, addr: u32, port: u16) Error!void {
    if (!available) return error.NoNetwork;
    return check(zn_socket_bind(s.z, addr, port));
}

pub fn listen(s: *Socket, backlog: u32) Error!void {
    if (!available) return error.NoNetwork;
    if (!s.stream) return error.InvalidArgument;
    return check(zn_socket_listen(s.z, @intCast(@min(backlog, 64))));
}

pub fn accept(s: *Socket) Error!*Socket {
    if (!available) return error.NoNetwork;
    if (!s.stream) return error.InvalidArgument;
    const deadline = Deadline.in(s.recv_timeout);
    while (true) {
        const seen = news();
        if (zn_socket_accept(s.z)) |z| return wrap(z, true);
        if (s.nonblock) return error.WouldBlock;
        try waitOn(s.z, deadline.step() catch return error.WouldBlock, seen);
    }
}

pub fn connect(s: *Socket, addr: u32, port: u16) Error!void {
    if (!available) return error.NoNetwork;
    const r = zn_socket_connect(s.z, addr, port);
    if (r == ZN.ok) return;
    if (r != ZN.in_progress and r != ZN.already) return fromZn(r);
    if (s.nonblock) return if (r == ZN.in_progress) error.InProgress else error.Already;
    kick();
    while (true) {
        const seen = news();
        if (zn_socket_state(s.z) & ZN.connecting == 0) break;
        try waitOn(s.z, 50, seen);
    }
    if (zn_socket_state(s.z) & ZN.connected != 0) return;
    const e = zn_socket_error(s.z);
    return if (e < 0) fromZn(e) else error.ConnectionAborted;
}

// The error a failed connection left (SO_ERROR), once
pub fn takeError(s: *Socket) ?Error {
    if (!available) return null;
    const e = zn_socket_error(s.z);
    return if (e < 0) fromZn(e) else null;
}

pub const Flags = struct {
    peek: bool = false,
    dont_wait: bool = false,
};

// card: the interface's number (NetInfo.number) a datagram came
// in by or goes out of (abi.NetVia.none: the loopback, any);
// local: the address it was sent to, or
// the one it goes from (0: the interface's)
pub const From = struct { addr: u32 = 0, port: u16 = 0, card: u8 = abi.NetVia.none, local: u32 = 0 };

// Stream: all of data unless it may not wait (then what fit);
// datagram: one datagram to the connected peer, or to `to`
pub fn send(s: *Socket, data: []const u8, flags: Flags, to: ?From) Error!usize {
    if (!available) return error.NoNetwork;
    if (!s.stream) {
        if (data.len > 65507) return error.MessageTooLong;
        const r = if (to) |t| blk: {
            var at: c_int = -1;
            if (t.card != abi.NetVia.none) {
                at = for (ifaces[0..iface_count], 0..) |f, i| {
                    if (f.number == t.card) break @intCast(i);
                } else return error.HostUnreachable;
            }
            break :blk zn_socket_send_via(s.z, data.ptr, @intCast(data.len), t.addr, t.port, at, t.local);
        } else zn_socket_send(s.z, data.ptr, @intCast(data.len));
        try check(r);
        return data.len;
    }
    if (to != null) return error.IsConnected;
    const may_wait = !s.nonblock and !flags.dont_wait;
    const deadline = Deadline.in(s.send_timeout);
    var done: usize = 0;
    defer kick();
    while (done < data.len) {
        const seen = news();
        const chunk: c_int = @intCast(@min(data.len - done, 0x7FFF_0000));
        const r = zn_socket_send(s.z, data[done..].ptr, chunk);
        if (r < 0) {
            if (done > 0) return done;
            const e = fromZn(r);
            return if (e == error.NotConnected and zn_socket_state(s.z) & ZN.hangup != 0) error.BrokenPipe else e;
        }
        done += @intCast(r);
        if (done == data.len) break;
        if (r == 0) {
            if (!may_wait) return if (done > 0) done else error.WouldBlock;
            const ms = deadline.step() catch return if (done > 0) done else error.WouldBlock;
            kick();
            waitOn(s.z, ms, seen) catch |err| return if (done > 0) done else err;
        }
    }
    return done;
}

// Stream: what has come (0: the peer closed), waiting for some
// unless it may not; datagram: the next one, cut to buf
pub fn recv(s: *Socket, buf: []u8, flags: Flags, from: ?*From) Error!usize {
    if (!available) return error.NoNetwork;
    const may_wait = !s.nonblock and !flags.dont_wait;
    const deadline = Deadline.in(s.recv_timeout);
    const len: c_int = @intCast(@min(buf.len, 0x7FFF_0000));
    while (true) {
        const seen = news();
        var ip: u32 = 0;
        var port: u16 = 0;
        var at: c_int = -1;
        var local: u32 = 0;
        const r = zn_socket_recv_via(s.z, buf.ptr, len, @intFromBool(flags.peek), &ip, &port, &at, &local);
        if (r >= 0) {
            const card: u8 = if (at >= 0 and at < iface_count) ifaces[@intCast(at)].number else abi.NetVia.none;
            if (from) |f| f.* = .{ .addr = ip, .port = port, .card = card, .local = local };
            if (r > 0 and !flags.peek) kick(); // the window opened
            return @intCast(r);
        }
        if (r != ZN.would_block) return fromZn(r);
        if (!may_wait) return error.WouldBlock;
        try waitOn(s.z, deadline.step() catch return error.WouldBlock, seen);
    }
}

pub fn shutdown(s: *Socket, read: bool, write: bool) Error!void {
    if (!available) return error.NoNetwork;
    return check(zn_socket_shutdown(s.z, @intFromBool(read), @intFromBool(write)));
}

// The local address, or the peer's; NotConnected if there is none
pub fn address(s: *Socket, peer: bool) Error!From {
    if (!available) return error.NoNetwork;
    var ip: u32 = 0;
    var port: u16 = 0;
    if (zn_socket_address(s.z, @intFromBool(peer), &ip, &port) == 0) return if (peer) error.NotConnected else From{};
    return .{ .addr = ip, .port = port };
}

pub fn setOption(s: *Socket, option: u32, value: u32) Error!void {
    if (!available) return error.NoNetwork;
    const O = abi.SocketOption;
    switch (option) {
        O.nonblocking => s.nonblock = value != 0,
        O.recv_timeout => s.recv_timeout = value,
        O.send_timeout => s.send_timeout = value,
        O.reuse_address, O.keepalive, O.broadcast, O.no_delay, O.ttl => {
            const zo: c_int = switch (option) {
                O.reuse_address => 1,
                O.keepalive => 2,
                O.broadcast => 3,
                O.no_delay => 4,
                else => 5,
            };
            try check(zn_socket_option(s.z, zo, @intCast(@min(value, 255))));
        },
        else => return error.InvalidArgument,
    }
}

pub fn getOption(s: *Socket, option: u32) Error!u32 {
    if (!available) return error.NoNetwork;
    const O = abi.SocketOption;
    return switch (option) {
        O.nonblocking => @intFromBool(s.nonblock),
        O.recv_timeout => s.recv_timeout,
        O.send_timeout => s.send_timeout,
        O.socket_type => if (s.stream) abi.SocketType.stream else abi.SocketType.datagram,
        O.pending_error => if (takeError(s)) |e| @intFromEnum(errorCode(e)) else 0,
        else => error.InvalidArgument,
    };
}

// For event queues: abi.QueueBits that hold now (hangup alone:
// the peer's end of sending; a reset or failure: err and hup)
pub fn queueReadiness(s: *Socket) u32 {
    if (!available) return 0;
    const B = abi.QueueBits;
    const st = zn_socket_state(s.z);
    var r: u32 = 0;
    if (st & ZN.readable != 0) r |= B.in;
    if (st & ZN.writable != 0) r |= B.out;
    if (st & ZN.hangup != 0) r |= B.read_hup;
    if (st & ZN.failed != 0) r |= B.err | B.hup;
    return r;
}

// For files.poll: abi.Poll bits of events that hold now
pub fn readiness(s: *Socket, events: u16) u16 {
    if (!available) return 0;
    const P = abi.Poll;
    const st = zn_socket_state(s.z);
    var r: u16 = 0;
    if (st & ZN.readable != 0) r |= events & P.in;
    if (st & ZN.writable != 0) r |= events & P.out;
    if (st & ZN.hangup != 0) r |= P.hup;
    if (st & ZN.failed != 0) r |= P.err;
    return r;
}
