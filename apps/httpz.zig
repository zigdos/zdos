// HTTPZ: the web server, a service (HTTPZ.CFG). Starts as root (the
// user, its folders, the key), then runs as USER.
//   HTTPZ -cgi INTERP<TAB>SCRIPT   (its own) a CGI script's task
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const net = @import("zdos/net.zig");
const users = @import("zdos/users.zig");
const TlsServer = @import("zdos/zcrypt.zig").TlsServer; // ZCRYPT.ZDL
const cert = @import("httpz/cert.zig");
const cgi = @import("httpz/cgi.zig");
const mime = @import("httpz/mime.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

const version = "HTTPZ/1.0 (ZDOS)";
const head_max = 8 * 1024; // a request's line and headers
const head_time_ms = 20_000; // to send them in (slow clients don't keep a slot)
const idle_ms = 15_000; // keep-alive wait for the next request
const send_ms = 30_000; // a client that stops reading doesn't keep a worker
const requests_max = 100; // per connection
const chunk = 64 * 1024; // file reads and writes
const workers_max = 16;
const worker_stack = 256 * 1024;

// HTTPZ.CFG:

const Config = struct {
    port: u16 = 80,
    https_port: u16 = 443,
    https_redirect: bool = false,
    user: Path = .{},
    home: Path = .{},
    cert: Path = .{},
    key: Path = .{},
    root: Path = .{},
    cgi_dir: Path = .{}, // under root; empty: no CGI
    index: Path = .{}, // names, separated by spaces
    log: Path = .{},
    max_file: u64 = 25 * 1024 * 1024,
    max_body: u64 = 1024 * 1024,
    max_clients: u32 = 32,
    workers: u32 = 0, // 0: one per core (2 at least)
    dirlist: bool = false,
    cgi_timeout_ms: u64 = 10_000,
    interpreters: [cgi.max_interpreters]cgi.Interpreter = undefined,
    interpreter_count: usize = 0,
};

const Path = struct {
    buf: [300]u8 = undefined,
    len: usize = 0,

    fn set(self: *Path, text: []const u8) void {
        self.len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..self.len], text[0..self.len]);
    }

    fn get(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }
};

var cfg: Config = .{};
var conf_drive: u8 = 'C';
var own_path_buf: [300]u8 = undefined;
var own_path: []const u8 = "";
var log_lock: ?sys.Mutex = null;
// Opened as root and kept: the user may not write there:
var log_file: ?zdos.File = null;
var log_committed: u64 = 0;
var active = std.atomic.Value(u32).init(0); // connections open
var stopping = std.atomic.Value(bool).init(false);
// Set before the workers start, then only read:
var chain: cert.Chain = .{};
var key: cert.Key = undefined;
var https_on = false;

pub fn main(args: []const u8) u8 {
    const a = std.mem.trimLeft(u8, args, " ");
    if (std.mem.startsWith(u8, a, "-cgi ")) return cgi.helper(a[5..]);
    if (std.mem.trim(u8, a, " \t").len > 0) {
        zdos.print("HTTPZ   (a service: HTTPZ=true in \\CONF\\SERVICES.CFG; see docs/HTTPZ.md)\n");
        return 1;
    }
    if (!users.isRoot()) {
        zdos.printError("HTTPZ: starts as root\n");
        return 1;
    }
    // A CGI script that ends without reading its input mustn't end us;
    // TERM, INT, HUP and Ctrl+C stop it in order:
    const one: u64 = 1;
    zdos.table().signals.set_handler(&onSignal, one << sys.Signal.term | one << sys.Signal.int | one << sys.Signal.hup, one << sys.Signal.pipe);
    sys.catchCtrlC(true);
    var vb: [300]u8 = undefined;
    if (zdos.getVar("COMSPEC", &vb)) |c| {
        if (c.len > 1 and c[1] == ':') conf_drive = c[0];
    }
    own_path = zdos.programPath(&own_path_buf);
    log_lock = sys.Mutex.create() catch null;
    readConfig();

    // As root: the user and its folders, the log, the certificate:
    const list = zdos.allocator.create(users.List) catch return fatal("memory", error.OutOfMemory);
    list.* = .{};
    const u = theUser(list) catch |err| return fatal("user", err);
    makeFolders(u);
    if (cfg.https_port != 0) {
        loadCertificate() catch |err| {
            log("HTTPS: {s} / {s}: {s}; HTTPS off", .{ cfg.cert.get(), cfg.key.get(), errText(err) });
            zdos.eprintf("HTTPZ: HTTPS off: {s}\n", .{errText(err)});
        };
    }
    const plain = listen(cfg.port) catch |err| return fatal("port", err);
    const secure: ?net.Socket = if (https_on) listen(cfg.https_port) catch |err| blk: {
        log("HTTPS port {d}: {s}", .{ cfg.https_port, errText(err) });
        https_on = false;
        break :blk null;
    } else null;
    users.become(u, u.uid) catch |err| return fatal("becoming the user", err);
    zdos.allocator.destroy(list);

    const workers = startWorkers() catch |err| return fatal("workers", err);
    log("listening on port {d}{s}; {d} workers; files from {s}", .{ cfg.port, if (https_on) " and HTTPS" else "", workers, cfg.root.get() });
    zdos.printf("HTTPZ: port {d}", .{cfg.port});
    if (https_on) zdos.printf(", HTTPS {d}", .{cfg.https_port});
    zdos.printf(", {d} workers, {s}\n", .{ workers, cfg.root.get() });
    pollLoop(plain, secure);
    return 0;
}

fn onSignal(_: i32) callconv(zdos.cc) void {
    stopping.store(true, .release);
}

fn fatal(what: []const u8, err: anyerror) u8 {
    log("{s}: {s}", .{ what, errText(err) });
    zdos.eprintf("HTTPZ: {s}: {s}\n", .{ what, errText(err) });
    return 1;
}

fn listen(port: u16) zdos.Error!net.Socket {
    const s = try net.Socket.open(net.SocketType.stream);
    errdefer s.close();
    s.setOption(net.SocketOption.reuse_address, 1) catch {};
    try s.bind(.{ .addr = .{ 0, 0, 0, 0 }, .port = port });
    try s.listen(16);
    return s;
}

fn readConfig() void {
    // Defaults: the user's home, its www and functions; no log:
    cfg.user.set("HTTPZ");
    var b: [300]u8 = undefined;
    cfg.home.set(users.homeOf("HTTPZ", &b));
    cfg.root.set(std.fmt.bufPrint(&b, "{s}\\www", .{cfg.home.get()}) catch "");
    cfg.cert.set(std.fmt.bufPrint(&b, "{s}\\httpz.crt", .{cfg.home.get()}) catch "");
    cfg.key.set(std.fmt.bufPrint(&b, "{s}\\httpz.key", .{cfg.home.get()}) catch "");
    cfg.cgi_dir.set("functions");
    cfg.index.set("index.html index.htm");

    var path = "C:\\CONF\\HTTPZ.CFG".*;
    path[0] = conf_drive;
    var buf: [4096]u8 = undefined;
    const text = readFile(&path, &buf) catch return;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (eqlAny(name, "PORT")) {
            cfg.port = std.fmt.parseInt(u16, value, 10) catch cfg.port;
        } else if (eqlAny(name, "HTTPS_PORT")) {
            cfg.https_port = std.fmt.parseInt(u16, value, 10) catch cfg.https_port;
        } else if (eqlAny(name, "HTTPS_REDIRECT")) {
            cfg.https_redirect = std.ascii.eqlIgnoreCase(value, "true");
        } else if (eqlAny(name, "CERT")) {
            cfg.cert.set(value);
        } else if (eqlAny(name, "KEY")) {
            cfg.key.set(value);
        } else if (eqlAny(name, "SERVER_ROOT")) {
            cfg.root.set(std.mem.trimRight(u8, value, "/\\"));
        } else if (eqlAny(name, "CGI_DIR")) {
            cfg.cgi_dir.set(std.mem.trim(u8, value, "/\\"));
        } else if (eqlAny(name, "INDEX")) {
            cfg.index.set(value);
        } else if (eqlAny(name, "LOG")) {
            cfg.log.set(value);
        } else if (eqlAny(name, "USER")) {
            cfg.user.set(value);
        } else if (eqlAny(name, "MAX_FILE_SIZE")) {
            cfg.max_file = parseSize(value) orelse cfg.max_file;
        } else if (eqlAny(name, "MAX_BODY")) {
            cfg.max_body = parseSize(value) orelse cfg.max_body;
        } else if (eqlAny(name, "MAX_CLIENTS")) {
            cfg.max_clients = std.fmt.parseInt(u32, value, 10) catch cfg.max_clients;
        } else if (eqlAny(name, "WORKERS")) {
            cfg.workers = std.fmt.parseInt(u32, value, 10) catch cfg.workers;
        } else if (eqlAny(name, "DIRLIST")) {
            cfg.dirlist = std.ascii.eqlIgnoreCase(value, "true");
        } else if (eqlAny(name, "CGI_TIMEOUT")) {
            cfg.cgi_timeout_ms = 1000 * (std.fmt.parseInt(u64, value, 10) catch cfg.cgi_timeout_ms / 1000);
        } else if (name.len > 4 and std.ascii.eqlIgnoreCase(name[0..4], "CGI ")) {
            // CGI py=C:/APPS/micropython.app:
            const ext = std.mem.trim(u8, name[4..], " \t.");
            if (ext.len == 0 or ext.len > 16 or cfg.interpreter_count == cgi.max_interpreters) continue;
            var it: cgi.Interpreter = .{};
            @memcpy(it.ext_buf[0..ext.len], ext);
            it.ext_len = ext.len;
            it.path_len = @min(value.len, it.path_buf.len);
            @memcpy(it.path_buf[0..it.path_len], value[0..it.path_len]);
            cfg.interpreters[cfg.interpreter_count] = it;
            cfg.interpreter_count += 1;
        }
    }
}

fn eqlAny(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// "25MB", "512KB", "1GB", "1000"
fn parseSize(text: []const u8) ?u64 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const n = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    const unit = std.mem.trim(u8, text[end..], " ");
    const mult: u64 = if (unit.len == 0 or eqlAny(unit, "B")) 1 else if (eqlAny(unit, "KB") or eqlAny(unit, "K")) 1024 else if (eqlAny(unit, "MB") or eqlAny(unit, "M")) 1024 * 1024 else if (eqlAny(unit, "GB") or eqlAny(unit, "G")) 1024 * 1024 * 1024 else return null;
    return n * mult;
}

fn readFile(path: []const u8, buf: []u8) zdos.Error![]const u8 {
    const f = try zdos.open(path, .read);
    defer f.close();
    var len: usize = 0;
    while (len < buf.len) {
        const n = try f.read(buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

// Made on the first start: no password (no login), its home its own.
fn theUser(list: *users.List) zdos.Error!*users.User {
    users.load(list) catch {};
    if (list.find(cfg.user.get())) |u| return u;
    if (!users.validName(cfg.user.get())) return error.InvalidName;
    const name = list.keep(cfg.user.get()) orelse return error.OutOfMemory;
    if (!list.add(.{ .name = name, .uid = list.nextUid(), .password = "!", .shell = "" })) return error.OutOfMemory;
    try users.save(list);
    log("made the user {s}", .{name});
    return list.find(name).?;
}

const sample_page =
    \\<!DOCTYPE html>
    \\<html><head><meta charset="utf-8"><title>HTTPZ</title></head>
    \\<body><h1>HTTPZ on ZDOS</h1>
    \\<p>Put your pages here, in this folder. A script in <code>functions</code>,
    \\such as <a href="functions/hello">functions/hello</a>, answers by its name.</p>
    \\</body></html>
    \\
;

const sample_script =
    \\-- A CGI script: its output is the reply, headers first (docs/HTTPZ.md)
    \\print("Content-Type: text/plain; charset=utf-8")
    \\print("")
    \\print("Hello from Lua on ZDOS")
    \\print("Query: " .. (os.getenv("QUERY_STRING") or ""))
    \\
;

fn makeFolders(u: *const users.User) void {
    var b: [300]u8 = undefined;
    _ = users.makeHome(u, &b);
    makeOwned(cfg.root.get(), u.uid);
    var p: [400]u8 = undefined;
    const index = std.fmt.bufPrint(&p, "{s}\\index.html", .{cfg.root.get()}) catch return;
    if (zdos.stat(index)) |_| {} else |_| writeSample(index, sample_page, u.uid);
    if (cfg.cgi_dir.len > 0) {
        const dir = std.fmt.bufPrint(&p, "{s}\\{s}", .{ cfg.root.get(), cfg.cgi_dir.get() }) catch return;
        makeOwned(dir, u.uid);
        var p2: [420]u8 = undefined;
        const hello = std.fmt.bufPrint(&p2, "{s}\\hello.lua", .{dir}) catch return;
        if (zdos.stat(hello)) |_| {} else |_| writeSample(hello, sample_script, u.uid);
    }
    // The log's folder, and the log the user's to write:
    if (cfg.log.len == 0) return;
    if (std.fs.path.dirnameWindows(cfg.log.get())) |dir| {
        if (std.fs.path.dirnameWindows(dir)) |parent| zdos.makeDir(parent) catch {};
        zdos.makeDir(dir) catch {};
    }
    log_file = zdos.open(cfg.log.get(), .update) catch null;
}

fn makeOwned(path: []const u8, uid: u32) void {
    if (zdos.makeDir(path)) {
        zdos.setOwner(path, uid, uid) catch {};
        zdos.setMode(path, 0o755) catch {};
    } else |_| {}
}

fn writeSample(path: []const u8, text: []const u8, uid: u32) void {
    const f = zdos.open(path, .write) catch return;
    f.writeAll(text) catch {};
    f.close();
    zdos.setOwner(path, uid, uid) catch {};
}

// A self-signed pair is made when either is missing.
fn loadCertificate() cert.Error!void {
    const have_cert = if (zdos.stat(cfg.cert.get())) |_| true else |_| false;
    const have_key = if (zdos.stat(cfg.key.get())) |_| true else |_| false;
    if (!have_cert or !have_key) {
        try cert.makeFiles(cfg.cert.get(), cfg.key.get(), &.{ "localhost", "zdos" });
        log("made a self-signed certificate: {s}", .{cfg.cert.get()});
    }
    try cert.loadChain(cfg.cert.get(), &chain);
    key = try cert.loadKey(cfg.key.get());
    if (!cert.matches(&chain, key)) return error.KeyMismatch;
    https_on = true;
}

// One line per request.

fn log(comptime fmt: []const u8, args: anytype) void {
    if (cfg.log.len == 0) return; // LOG= left out or empty
    if (log_lock) |m| m.lock() catch {};
    defer if (log_lock) |m| m.unlock() catch {};
    var line: [600]u8 = undefined;
    const t = zdos.getTime();
    const head = std.fmt.bufPrint(&line, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ t.year, t.month, t.day, t.hour, t.minute, t.second }) catch return;
    const body = std.fmt.bufPrint(line[head.len .. line.len - 1], fmt, args) catch line[head.len .. line.len - 1];
    line[head.len + body.len] = '\n';
    const text = line[0 .. head.len + body.len + 1];
    if (log_file) |f| {
        f.seek(f.size() catch 0) catch {};
        f.writeAll(text) catch {};
        // On disk every 2 s at most, not once per request:
        const now = zdos.millis();
        if (now - log_committed >= 2000) {
            f.commit() catch {};
            log_committed = now;
        }
        return;
    }
    const f = zdos.open(cfg.log.get(), .update) catch zdos.open(cfg.log.get(), .write) catch return;
    defer f.close();
    f.seek(f.size() catch 0) catch {};
    f.writeAll(text) catch {};
}

fn errText(err: anyerror) []const u8 {
    inline for (@typeInfo(zdos.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return zdos.message(@field(zdos.Error, e.name));
    }
    return @errorName(err);
}

// CONNECTIONS: a thread per port accepts (the network's queue holds 16).
// The main thread polls idle connections; one with a request goes to a
// worker, which hands it back once nothing more is to be read, so idle or
// slow clients hold no worker.

var q_lock: sys.Mutex = undefined; // ready and handed_back
var q_cond: sys.Cond = undefined; // something in ready, or stopping
var ready: ?*Conn = null; // for the workers, oldest first
var ready_last: ?*Conn = null;
var handed_back: ?*Conn = null; // for the poller
var wake_in: zdos.File = undefined; // a byte when handed_back was empty
var wake_out: zdos.File = undefined;

const Conn = struct {
    sock: net.Socket,
    peer: net.Address,
    secure: bool,
    t: ?TlsServer = null,
    next: ?*Conn = null, // in ready or handed_back
    deadline: u64 = 0, // while parked: closed then
    head_since: u64 = 0, // a request's first bytes came then (0: none yet)
    served: u32 = 0,
    // Received, not yet used:
    in: [head_max]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    sent: u64 = 0, // body bytes of the current reply

    fn recvSome(c: *Conn, buf: []u8) anyerror!usize {
        if (c.t) |t| return t.read(buf);
        return c.sock.recv(buf) catch |err| if (err == error.WouldBlock) error.TimedOut else err;
    }

    fn send(c: *Conn, data: []const u8) anyerror!void {
        if (c.t) |t| return t.writeAll(data);
        return c.sock.sendAll(data);
    }

    fn buffered(c: *const Conn) []const u8 {
        return c.in[c.in_start..c.in_end];
    }

    // Or the end, which recv then tells.
    fn readable(c: *const Conn) bool {
        if (c.t) |t| {
            if (t.pending()) return true;
        }
        return readyNow(c.sock.handle);
    }
};

fn readyNow(handle: i32) bool {
    var fds = [1]zdos.PollFd{.{ .handle = handle, .events = zdos.Poll.in }};
    return zdos.table().files.poll(&fds, 1, 0) > 0;
}

// Each with its own file buffer; how many started.
fn startWorkers() anyerror!u32 {
    q_lock = try sys.Mutex.create();
    q_cond = try sys.Cond.create();
    const p = try sys.pipe();
    wake_in = .{ .handle = p.read };
    wake_out = .{ .handle = p.write };
    const want = if (cfg.workers > 0) @min(cfg.workers, workers_max) else std.math.clamp(sys.coreCount(), 2, workers_max);
    var n: u32 = 0;
    while (n < want) : (n += 1) {
        const buf = zdos.allocator.alloc(u8, chunk) catch break;
        const id = sys.threadCreate(&worker, buf.ptr, worker_stack, null) catch {
            zdos.allocator.free(buf);
            break;
        };
        sys.threadDetach(id) catch {};
    }
    if (n == 0) return error.OutOfMemory;
    return n;
}

fn worker(arg: ?*anyopaque) callconv(zdos.cc) usize {
    _ = zdos.tlsStart();
    const buf = @as([*]u8, @ptrCast(arg.?))[0..chunk];
    while (take()) |c| serveConn(c, buf);
    return 0;
}

fn take() ?*Conn {
    q_lock.lock() catch return null;
    defer q_lock.unlock() catch {};
    while (true) {
        if (ready) |c| {
            ready = c.next;
            if (ready == null) ready_last = null;
            c.next = null;
            return c;
        }
        if (stopping.load(.acquire)) return null;
        q_cond.wait(q_lock, 1000) catch {};
    }
}

fn give(c: *Conn) void {
    q_lock.lock() catch {};
    if (ready_last) |l| l.next = c else ready = c;
    ready_last = c;
    q_lock.unlock() catch {};
    q_cond.signal();
}

// Back to the poller until the client sends more.
fn park(c: *Conn) void {
    c.deadline = if (c.head_since != 0) c.head_since + head_time_ms else zdos.millis() + idle_ms;
    q_lock.lock() catch {};
    const first = handed_back == null;
    c.next = handed_back;
    handed_back = c;
    q_lock.unlock() catch {};
    if (first) _ = wake_out.write("x") catch {};
}

fn endConn(c: *Conn) void {
    if (c.t) |t| t.deinit();
    c.sock.close();
    zdos.allocator.destroy(c);
    _ = active.fetchSub(1, .monotonic);
}

// The poller's: close_notify must not make it wait.
fn endParked(c: *Conn) void {
    c.sock.setOption(net.SocketOption.nonblocking, 1) catch {};
    endConn(c);
}

fn endAll(list: ?*Conn) void {
    var at = list;
    while (at) |c| {
        at = c.next;
        endParked(c);
    }
}

fn drainWake() void {
    var b: [64]u8 = undefined;
    if (readyNow(wake_in.handle)) _ = wake_in.read(&b) catch {};
}

// The main thread's loop, then the stop.
fn pollLoop(plain: net.Socket, secure: ?net.Socket) void {
    const max: usize = cfg.max_clients;
    const parked = zdos.allocator.alloc(*Conn, max) catch return;
    const fds = zdos.allocator.alloc(zdos.PollFd, max + 1) catch return;
    var n: usize = 0;
    startAcceptor(plain, false) catch |err| return log("accepting: {s}", .{errText(err)});
    if (secure) |s| startAcceptor(s, true) catch |err| log("accepting HTTPS: {s}", .{errText(err)});
    while (!stopping.load(.acquire)) {
        fds[0] = .{ .handle = wake_in.handle, .events = zdos.Poll.in };
        var k: usize = 1;
        const base = k;
        for (parked[0..n]) |c| {
            fds[k] = .{ .handle = c.sock.handle, .events = zdos.Poll.in };
            k += 1;
        }
        _ = zdos.table().files.poll(fds.ptr, @intCast(k), 250);
        if (sys.ctrlCPressed(true)) stopping.store(true, .release);

        // Those with something to read go to a worker; those idle too long end:
        const now = zdos.millis();
        var kept: usize = 0;
        for (parked[0..n], fds[base..k]) |c, f| {
            if (f.revents != 0) {
                give(c);
            } else if (now >= c.deadline) {
                endParked(c);
            } else {
                parked[kept] = c;
                kept += 1;
            }
        }
        n = kept;
        if (fds[0].revents != 0) drainWake();
        q_lock.lock() catch {};
        var back = handed_back;
        handed_back = null;
        q_lock.unlock() catch {};
        while (back) |c| {
            back = c.next;
            c.next = null;
            if (n == max) {
                endParked(c);
                continue;
            }
            parked[n] = c;
            n += 1;
        }
    }

    // The listeners stay open (an acceptor may be waiting on one); new
    // connections get 503 meanwhile:
    log("stopping", .{});
    for (parked[0..n]) |c| endParked(c);
    q_cond.broadcast();
    // The workers finish the replies they are sending (5 s at most):
    const until = zdos.millis() + 5000;
    while (true) {
        q_lock.lock() catch {};
        const back = handed_back;
        const queued = ready;
        handed_back = null;
        ready = null;
        ready_last = null;
        q_lock.unlock() catch {};
        endAll(back);
        endAll(queued);
        if (active.load(.acquire) == 0 or zdos.millis() >= until) break;
        drainWake();
        zdos.sleep(20);
    }
    log("stopped", .{});
    if (log_file) |f| f.commit() catch {};
}

const Acceptor = struct { listener: net.Socket, secure: bool };
var acceptors: [2]Acceptor = undefined;
var acceptor_count: usize = 0;

fn startAcceptor(listener: net.Socket, secure: bool) anyerror!void {
    const a = &acceptors[acceptor_count];
    a.* = .{ .listener = listener, .secure = secure };
    const id = try sys.threadCreate(&acceptLoop, a, 64 * 1024, null);
    sys.threadDetach(id) catch {};
    acceptor_count += 1;
}

// New connections go to the poller until they send something.
fn acceptLoop(arg: ?*anyopaque) callconv(zdos.cc) usize {
    _ = zdos.tlsStart();
    const a: *const Acceptor = @ptrCast(@alignCast(arg.?));
    while (!stopping.load(.acquire)) {
        var peer: net.Address = .{};
        const s = a.listener.accept(&peer) catch {
            zdos.sleep(200);
            continue;
        };
        if (stopping.load(.acquire) or active.load(.monotonic) >= cfg.max_clients) {
            s.sendAll("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
            s.close();
            continue;
        }
        const c = zdos.allocator.create(Conn) catch {
            s.close();
            continue;
        };
        c.* = .{ .sock = s, .peer = peer, .secure = a.secure };
        s.setOption(net.SocketOption.recv_timeout, idle_ms) catch {};
        s.setOption(net.SocketOption.send_timeout, send_ms) catch {};
        s.setOption(net.SocketOption.no_delay, 1) catch {};
        _ = active.fetchAdd(1, .monotonic);
        park(c);
    }
    return 0;
}

// A worker's: requests until there is nothing to read for now.
fn serveConn(c: *Conn, buf: []u8) void {
    if (c.secure and c.t == null) {
        c.t = TlsServer.accept(c.sock, chain.certs[0..chain.count], &key) catch |err| {
            var ab: [16]u8 = undefined;
            if (err != error.Closed and err != error.TimedOut) log("{s} TLS: {s}", .{ net.addressText(c.peer.addr, &ab), errText(err) });
            return endConn(c);
        };
    }
    while (!stopping.load(.monotonic)) {
        const keep = serveOne(c, buf, c.served + 1 == requests_max) catch |err| {
            if (err == error.Park) return park(c);
            break;
        };
        c.served += 1;
        if (!keep) break;
    }
    endConn(c);
}

// REQUESTS

const Request = struct {
    method: []const u8 = "",
    target: []const u8 = "", // as sent
    path: []const u8 = "", // decoded, without the query
    query: []const u8 = "",
    http11: bool = true,
    host: []const u8 = "",
    close: bool = false,
    content_length: ?u64 = null,
    chunked: bool = false,
    range: ?[]const u8 = null,
    if_modified_since: ?[]const u8 = null,
    content_type: []const u8 = "",
    headers: []const u8 = "", // all of them, for CGI's HTTP_ variables
    path_buf: [head_max]u8 = undefined,
};

const Status = struct { code: u16, text: []const u8 };
const ok: Status = .{ .code = 200, .text = "OK" };

// Whether the connection stays open.
fn serveOne(c: *Conn, buf: []u8, last: bool) anyerror!bool {
    var r: Request = .{};
    const head_len = readHead(c) catch |err| {
        if (err == error.Park) return err;
        if (err == error.TooLarge) try respond(c, &r, .{ .code = 431, .text = "Request Header Fields Too Large" }, "", false);
        return false;
    };
    const head = c.in[c.in_start..][0..head_len];
    c.in_start += head_len;
    parseHead(&r, head) catch {
        try respond(c, &r, .{ .code = 400, .text = "Bad Request" }, "", false);
        return false;
    };
    var keep = !r.close and !last and !stopping.load(.monotonic);
    const status = try route(c, &r, buf, &keep);
    var ab: [16]u8 = undefined;
    log("{s} \"{s} {s}\" {d} {d}", .{ net.addressText(c.peer.addr, &ab), r.method, r.target, status, c.sent });
    return keep;
}

// In c.in from in_start; Park when the rest hasn't come yet.
fn readHead(c: *Conn) anyerror!usize {
    // What a previous request left starts the buffer:
    if (c.in_start > 0) {
        std.mem.copyForwards(u8, c.in[0 .. c.in_end - c.in_start], c.in[c.in_start..c.in_end]);
        c.in_end -= c.in_start;
        c.in_start = 0;
    }
    while (true) {
        if (std.mem.indexOf(u8, c.in[0..c.in_end], "\r\n\r\n")) |i| {
            c.head_since = 0;
            return i + 4;
        }
        if (c.in_end == c.in.len) return error.TooLarge;
        if (c.in_end > 0 and c.head_since == 0) c.head_since = zdos.millis();
        if (c.head_since != 0 and zdos.millis() > c.head_since + head_time_ms) return error.TimedOut;
        if (!c.readable()) return error.Park;
        const n = try c.recvSome(c.in[c.in_end..]);
        if (n == 0) return error.Closed;
        c.in_end += n;
    }
}

fn parseHead(r: *Request, head: []const u8) !void {
    var lines = std.mem.splitSequence(u8, head[0 .. head.len - 4], "\r\n");
    const first = lines.next() orelse return error.Bad;
    var parts = std.mem.tokenizeScalar(u8, first, ' ');
    r.method = parts.next() orelse return error.Bad;
    r.target = parts.next() orelse return error.Bad;
    const ver = parts.next() orelse return error.Bad;
    if (std.mem.eql(u8, ver, "HTTP/1.0")) r.http11 = false else if (!std.mem.eql(u8, ver, "HTTP/1.1")) return error.Bad;
    if (!r.http11) r.close = true;
    r.headers = head[first.len + 2 .. head.len - 2];
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Bad;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (eqlAny(name, "Host")) {
            r.host = value;
        } else if (eqlAny(name, "Connection")) {
            if (std.ascii.indexOfIgnoreCase(value, "close") != null) r.close = true;
            if (std.ascii.indexOfIgnoreCase(value, "keep-alive") != null) r.close = false;
        } else if (eqlAny(name, "Content-Length")) {
            r.content_length = std.fmt.parseInt(u64, value, 10) catch return error.Bad;
        } else if (eqlAny(name, "Transfer-Encoding")) {
            r.chunked = true;
        } else if (eqlAny(name, "Range")) {
            r.range = value;
        } else if (eqlAny(name, "If-Modified-Since")) {
            r.if_modified_since = value;
        } else if (eqlAny(name, "Content-Type")) {
            r.content_type = value;
        }
    }
    if (r.target.len == 0 or r.target[0] != '/') return error.Bad;
    const q = std.mem.indexOfScalar(u8, r.target, '?');
    const raw = r.target[0 .. q orelse r.target.len];
    if (q) |i| r.query = r.target[i + 1 ..];
    r.path = try decodePath(raw, &r.path_buf);
}

// %XX decoded; refused: NUL and control bytes, backslashes, drive
// colons, "..", and names starting with a dot.
fn decodePath(raw: []const u8, out: []u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var ch = raw[i];
        if (ch == '%') {
            if (i + 2 >= raw.len) return error.Bad;
            ch = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return error.Bad;
            i += 2;
        }
        if (ch < 0x20 or ch == 0x7F or ch == '\\' or ch == ':') return error.Bad;
        out[n] = ch;
        n += 1;
    }
    var it = std.mem.splitScalar(u8, out[0..n], '/');
    while (it.next()) |seg| {
        if (seg.len > 0 and seg[0] == '.') return error.Bad;
    }
    return out[0..n];
}

// Its status code.
fn route(c: *Conn, r: *Request, buf: []u8, keep: *bool) anyerror!u16 {
    const get = std.mem.eql(u8, r.method, "GET");
    const head_only = std.mem.eql(u8, r.method, "HEAD");
    const post = std.mem.eql(u8, r.method, "POST");

    // HTTP TO HTTPS:
    if (!c.secure and cfg.https_redirect and https_on) {
        var lb: [600]u8 = undefined;
        const location = httpsLocation(c, r, &lb) catch "";
        return redirect(c, r, 301, location, keep);
    }

    // A body not for a script: not read, so the connection ends:
    const has_body = r.chunked or (r.content_length orelse 0) > 0;

    if (try findScript(r)) |script| {
        if (!get and !head_only and !post) return simple(c, r, .{ .code = 405, .text = "Method Not Allowed" }, "Allow: GET, HEAD, POST\r\n", false, keep);
        if (r.chunked) return simple(c, r, .{ .code = 411, .text = "Length Required" }, "", false, keep);
        if ((r.content_length orelse 0) > cfg.max_body) return simple(c, r, .{ .code = 413, .text = "Content Too Large" }, "", false, keep);
        return runScript(c, r, script, head_only, keep);
    }
    if (has_body) keep.* = false;
    if (!get and !head_only) return simple(c, r, .{ .code = 405, .text = "Method Not Allowed" }, "Allow: GET, HEAD\r\n", false, keep);

    var pb: [1400]u8 = undefined;
    const fs_path = std.fmt.bufPrint(&pb, "{s}{s}", .{ cfg.root.get(), r.path }) catch
        return simple(c, r, .{ .code = 414, .text = "URI Too Long" }, "", head_only, keep);
    const e = zdos.stat(std.mem.trimRight(u8, fs_path, "/")) catch |err| {
        if (err == error.AccessDenied) return simple(c, r, .{ .code = 403, .text = "Forbidden" }, "", head_only, keep);
        return simple(c, r, .{ .code = 404, .text = "Not Found" }, "", head_only, keep);
    };
    if (inCgiDir(r.path) and isCgiName(r.path)) return simple(c, r, .{ .code = 404, .text = "Not Found" }, "", head_only, keep);
    if (!e.is_dir) return sendFile(c, r, fs_path, e, buf, head_only, keep);

    // A folder: its address with "/" at the end, then index or listing:
    if (r.path[r.path.len - 1] != '/') {
        var lb: [1400]u8 = undefined;
        const location = std.fmt.bufPrint(&lb, "{s}/{s}{s}", .{ r.target[0 .. std.mem.indexOfScalar(u8, r.target, '?') orelse r.target.len], if (r.query.len > 0) "?" else "", r.query }) catch r.target;
        return redirect(c, r, 301, location, keep);
    }
    var names = std.mem.tokenizeAny(u8, cfg.index.get(), " ,");
    while (names.next()) |name| {
        var ib: [1500]u8 = undefined;
        const index = std.fmt.bufPrint(&ib, "{s}{s}", .{ fs_path, name }) catch continue;
        const ie = zdos.stat(index) catch continue;
        if (!ie.is_dir) return sendFile(c, r, index, ie, buf, head_only, keep);
    }
    if (cfg.dirlist) return listFolder(c, r, fs_path, buf, head_only, keep);
    return simple(c, r, .{ .code = 403, .text = "Forbidden" }, "", head_only, keep);
}

fn httpsLocation(c: *Conn, r: *const Request, buf: []u8) ![]const u8 {
    var host = r.host;
    var ab: [16]u8 = undefined;
    if (host.len == 0) {
        const a = try c.sock.address(false);
        host = net.addressText(a.addr, &ab);
    }
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |i| {
        if (std.mem.indexOfScalar(u8, host, ']') == null or i > std.mem.indexOfScalar(u8, host, ']').?) host = host[0..i];
    }
    if (cfg.https_port == 443) return std.fmt.bufPrint(buf, "https://{s}{s}", .{ host, r.target });
    return std.fmt.bufPrint(buf, "https://{s}:{d}{s}", .{ host, cfg.https_port, r.target });
}

// REPLIES

fn reasonOf(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        416 => "Range Not Satisfiable",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        504 => "Gateway Timeout",
        else => "",
    };
}

// Then extra and the empty line.
fn writeHead(c: *Conn, r: *const Request, status: Status, extra: []const u8, keep: bool) anyerror!void {
    var b: [2048]u8 = undefined;
    var db: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&b, "HTTP/1.1 {d} {s}\r\nServer: {s}\r\nDate: {s}\r\n{s}Connection: {s}\r\n\r\n", .{
        status.code, status.text, version, httpDate(zdos.getTime(), &db), extra, if (keep) "keep-alive" else "close",
    });
    _ = r;
    c.sent = 0;
    try c.send(text);
}

// For errors and redirects.
fn simple(c: *Conn, r: *const Request, status: Status, extra: []const u8, head_only: bool, keep: *bool) anyerror!u16 {
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "<!DOCTYPE html><html><head><title>{d} {s}</title></head><body><h1>{d} {s}</h1></body></html>\n", .{ status.code, status.text, status.code, status.text }) catch "";
    var hb: [600]u8 = undefined;
    const headers = std.fmt.bufPrint(&hb, "Content-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n{s}", .{ body.len, extra }) catch "";
    try writeHead(c, r, status, headers, keep.*);
    if (!head_only) {
        try c.send(body);
        c.sent = body.len;
    }
    return status.code;
}

fn respond(c: *Conn, r: *const Request, status: Status, extra: []const u8, keep_in: bool) anyerror!void {
    var keep = keep_in;
    _ = try simple(c, r, status, extra, false, &keep);
}

fn redirect(c: *Conn, r: *const Request, code: u16, location: []const u8, keep: *bool) anyerror!u16 {
    var hb: [1600]u8 = undefined;
    const extra = std.fmt.bufPrint(&hb, "Location: {s}\r\n", .{location}) catch "";
    return simple(c, r, .{ .code = code, .text = reasonOf(code) }, extra, std.mem.eql(u8, r.method, "HEAD"), keep);
}

// "Wed, 21 Oct 2015 07:28:00 GMT": ZDOS's clock has no time zone.
fn httpDate(t: zdos.Time, buf: *[32]u8) []const u8 {
    const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const wd = days[@intCast(@mod(daysFromCivil(t.year, t.month, t.day), 7))];
    const m = months[@min(@max(t.month, 1), 12) - 1];
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ wd, t.day, m, t.year, t.hour, t.minute, t.second }) catch "";
}

// 1970-01-01 was a Thursday.
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// FILES

fn sendFile(c: *Conn, r: *const Request, path: []const u8, e: zdos.DirEntry, buf: []u8, head_only: bool, keep: *bool) anyerror!u16 {
    if (e.size > cfg.max_file) return simple(c, r, .{ .code = 403, .text = "Forbidden" }, "", head_only, keep);
    var mb: [32]u8 = undefined;
    const modified = httpDate(e.modified, &mb);
    if (r.if_modified_since) |since| {
        if (std.mem.eql(u8, since, modified)) {
            var hb: [128]u8 = undefined;
            try writeHead(c, r, .{ .code = 304, .text = "Not Modified" }, std.fmt.bufPrint(&hb, "Last-Modified: {s}\r\n", .{modified}) catch "", keep.*);
            return 304;
        }
    }
    const f = zdos.open(path, .read) catch |err| {
        if (err == error.AccessDenied) return simple(c, r, .{ .code = 403, .text = "Forbidden" }, "", head_only, keep);
        return simple(c, r, .{ .code = 404, .text = "Not Found" }, "", head_only, keep);
    };
    defer f.close();

    // Range: one span ("bytes=a-b", "a-", "-n"); others give the whole file:
    var start: u64 = 0;
    var end: u64 = e.size; // exclusive
    var status = ok;
    if (r.range) |range| {
        if (parseRange(range, e.size)) |span| {
            if (span.start >= e.size or span.start >= span.end) {
                var hb: [96]u8 = undefined;
                return simple(c, r, .{ .code = 416, .text = "Range Not Satisfiable" }, std.fmt.bufPrint(&hb, "Content-Range: bytes */{d}\r\n", .{e.size}) catch "", head_only, keep);
            }
            start = span.start;
            end = span.end;
            status = .{ .code = 206, .text = "Partial Content" };
        }
    }
    var hb: [600]u8 = undefined;
    var range_buf: [96]u8 = undefined;
    const content_range = if (status.code == 206) std.fmt.bufPrint(&range_buf, "Content-Range: bytes {d}-{d}/{d}\r\n", .{ start, end - 1, e.size }) catch "" else "";
    const extra = std.fmt.bufPrint(&hb, "Content-Type: {s}\r\nContent-Length: {d}\r\nLast-Modified: {s}\r\nAccept-Ranges: bytes\r\n{s}", .{
        mime.of(path), end - start, modified, content_range,
    }) catch "";
    try writeHead(c, r, status, extra, keep.*);
    if (head_only) return status.code;
    if (start > 0) try f.seek(start);
    var left = end - start;
    while (left > 0) {
        const n = try f.read(buf[0..@intCast(@min(left, buf.len))]);
        if (n == 0) return error.Closed; // the file shrank
        try c.send(buf[0..n]);
        c.sent += n;
        left -= n;
    }
    return status.code;
}

fn parseRange(text: []const u8, size: u64) ?struct { start: u64, end: u64 } {
    if (!std.mem.startsWith(u8, text, "bytes=")) return null;
    const spec = text[6..];
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return null;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const a = std.mem.trim(u8, spec[0..dash], " ");
    const b = std.mem.trim(u8, spec[dash + 1 ..], " ");
    if (a.len == 0) { // the last b bytes
        const n = std.fmt.parseInt(u64, b, 10) catch return null;
        if (n == 0) return .{ .start = size, .end = size };
        return .{ .start = size - @min(n, size), .end = size };
    }
    const s = std.fmt.parseInt(u64, a, 10) catch return null;
    const e = if (b.len == 0) size else (std.fmt.parseInt(u64, b, 10) catch return null) + 1;
    return .{ .start = s, .end = @min(e, size) };
}

// DIRLIST=true
fn listFolder(c: *Conn, r: *const Request, path: []const u8, buf: []u8, head_only: bool, keep: *bool) anyerror!u16 {
    const d = zdos.openDir(path) catch return simple(c, r, .{ .code = 403, .text = "Forbidden" }, "", head_only, keep);
    defer d.close();
    var w: usize = 0;
    const top = std.fmt.bufPrint(buf, "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>{s}</title></head><body><h1>{s}</h1><ul>\n", .{ r.path, r.path }) catch return error.TooLarge;
    w = top.len;
    var e: zdos.DirEntry = undefined;
    while (d.next(&e) catch false) {
        const name = e.name();
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.indexOfAny(u8, name, "<>\"&") != null) continue;
        if (inCgiDir(r.path) and isCgiName(name)) continue;
        var nb: [1600]u8 = undefined;
        const line = std.fmt.bufPrint(&nb, "<li><a href=\"{s}{s}\">{s}{s}</a></li>\n", .{ name, if (e.is_dir) "/" else "", name, if (e.is_dir) "/" else "" }) catch continue;
        if (w + line.len + 32 > buf.len) break;
        @memcpy(buf[w..][0..line.len], line);
        w += line.len;
    }
    const end = "</ul></body></html>\n";
    @memcpy(buf[w..][0..end.len], end);
    w += end.len;
    var hb: [128]u8 = undefined;
    try writeHead(c, r, ok, std.fmt.bufPrint(&hb, "Content-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\n", .{w}) catch "", keep.*);
    if (!head_only) {
        try c.send(buf[0..w]);
        c.sent = w;
    }
    return 200;
}

// CGI

const Script = struct {
    path_buf: [1400]u8 = undefined,
    path_len: usize = 0,
    interpreter: ?[]const u8 = null,
    name_len: usize = 0, // SCRIPT_NAME in r.path

    fn path(self: *const Script) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

// "/functions/..."
fn inCgiDir(path: []const u8) bool {
    const dir = cfg.cgi_dir.get();
    if (dir.len == 0 or path.len < dir.len + 1) return false;
    return path[0] == '/' and std.mem.eql(u8, path[1 .. 1 + dir.len], dir) and
        (path.len == dir.len + 1 or path[1 + dir.len] == '/');
}

// A script's extension or .app: never sent as a file.
fn isCgiName(path: []const u8) bool {
    const base = std.fs.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot + 1 ..];
    if (eqlAny(ext, "app")) return true;
    for (cfg.interpreters[0..cfg.interpreter_count]) |*it| {
        if (eqlAny(ext, it.ext())) return true;
    }
    return false;
}

// /functions/a/b/rest: the first of a, a/b ... that is name.EXT or
// name.app on disk; what follows it is PATH_INFO.
fn findScript(r: *const Request) !?Script {
    if (!inCgiDir(r.path)) return null;
    var s: Script = .{};
    var at: usize = 1 + cfg.cgi_dir.len;
    while (at < r.path.len) {
        const next = std.mem.indexOfScalarPos(u8, r.path, at + 1, '/') orelse r.path.len;
        const seg_end = next;
        if (seg_end == at + 1) break; // "//" or a trailing "/"
        const prefix = r.path[0..seg_end];
        // A file that is there as it is named: not a script:
        var pb: [1400]u8 = undefined;
        const plain = std.fmt.bufPrint(&pb, "{s}{s}", .{ cfg.root.get(), prefix }) catch return null;
        if (zdos.stat(plain)) |e| {
            if (!e.is_dir) return null;
            at = seg_end;
            continue;
        } else |_| {}
        for (cfg.interpreters[0..cfg.interpreter_count]) |*it| {
            const p = std.fmt.bufPrint(&s.path_buf, "{s}.{s}", .{ plain, it.ext() }) catch continue;
            if (isFile(p)) {
                s.path_len = p.len;
                s.interpreter = it.path();
                s.name_len = seg_end;
                return s;
            }
        }
        const p = std.fmt.bufPrint(&s.path_buf, "{s}.app", .{plain}) catch return null;
        if (isFile(p)) {
            s.path_len = p.len;
            s.name_len = seg_end;
            return s;
        }
        return null;
    }
    return null;
}

fn isFile(path: []const u8) bool {
    const e = zdos.stat(path) catch return false;
    return !e.is_dir;
}

fn addVar(vars: []u8, len: *usize, name: []const u8, value: []const u8) void {
    var b: [700]u8 = undefined;
    // One line, as long as a ZDOS variable holds:
    var clean: [512]u8 = undefined;
    var n: usize = 0;
    for (value) |ch| {
        if (n == clean.len) break;
        clean[n] = if (ch == '\n' or ch == '\r') ' ' else ch;
        n += 1;
    }
    const line = std.fmt.bufPrint(&b, "{s}={s}\n", .{ name, clean[0..n] }) catch return;
    if (len.* + line.len > vars.len) return;
    @memcpy(vars[len.*..][0..line.len], line);
    len.* += line.len;
}

fn runScript(c: *Conn, r: *Request, script: Script, head_only: bool, keep: *bool) anyerror!u16 {
    // The body, read whole (MAX_BODY at most):
    const body_len: usize = @intCast(r.content_length orelse 0);
    const body = try zdos.allocator.alloc(u8, body_len);
    defer zdos.allocator.free(body);
    var got: usize = @min(body_len, c.buffered().len);
    @memcpy(body[0..got], c.buffered()[0..got]);
    c.in_start += got;
    while (got < body_len) {
        const n = try c.recvSome(body[got..]);
        if (n == 0) return error.Closed;
        got += n;
    }

    // The CGI variables (RFC 3875), and HTTP_ ones for the headers:
    var vars: [8 * 1024]u8 = undefined;
    var vl: usize = 0;
    var tb: [32]u8 = undefined;
    var ab: [16]u8 = undefined;
    addVar(&vars, &vl, "GATEWAY_INTERFACE", "CGI/1.1");
    addVar(&vars, &vl, "SERVER_SOFTWARE", version);
    addVar(&vars, &vl, "SERVER_PROTOCOL", if (r.http11) "HTTP/1.1" else "HTTP/1.0");
    addVar(&vars, &vl, "SERVER_PORT", std.fmt.bufPrint(&tb, "{d}", .{if (c.secure) cfg.https_port else cfg.port}) catch "");
    addVar(&vars, &vl, "SERVER_NAME", if (std.mem.indexOfScalar(u8, r.host, ':')) |i| r.host[0..i] else r.host);
    addVar(&vars, &vl, "REQUEST_METHOD", r.method);
    addVar(&vars, &vl, "REQUEST_URI", r.target);
    addVar(&vars, &vl, "SCRIPT_NAME", r.path[0..script.name_len]);
    addVar(&vars, &vl, "PATH_INFO", r.path[script.name_len..]);
    addVar(&vars, &vl, "SCRIPT_FILENAME", script.path());
    addVar(&vars, &vl, "QUERY_STRING", r.query);
    addVar(&vars, &vl, "REMOTE_ADDR", net.addressText(c.peer.addr, &ab));
    addVar(&vars, &vl, "CONTENT_TYPE", r.content_type);
    addVar(&vars, &vl, "CONTENT_LENGTH", std.fmt.bufPrint(&tb, "{d}", .{body_len}) catch "");
    if (c.secure) addVar(&vars, &vl, "HTTPS", "on");
    var lines = std.mem.splitSequence(u8, r.headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (eqlAny(name, "Content-Type") or eqlAny(name, "Content-Length") or eqlAny(name, "Authorization")) continue;
        var nb: [64]u8 = undefined;
        if (name.len + 5 > nb.len) continue;
        @memcpy(nb[0..5], "HTTP_");
        for (name, 0..) |ch, i| nb[5 + i] = if (ch == '-') '_' else std.ascii.toUpper(ch);
        addVar(&vars, &vl, nb[0 .. 5 + name.len], std.mem.trim(u8, line[colon + 1 ..], " \t"));
    }

    var s = cgi.start(.{
        .own_path = own_path,
        .script = script.path(),
        .interpreter = script.interpreter,
        .vars = vars[0..vl],
        .body = body,
        .timeout_ms = cfg.cgi_timeout_ms,
    }) catch |err| {
        log("CGI {s}: {s}", .{ script.path(), errText(err) });
        return simple(c, r, .{ .code = 500, .text = "Internal Server Error" }, "", head_only, keep);
    };
    defer s.finish();

    // Its headers, up to the empty line:
    var out: [head_max]u8 = undefined;
    var ol: usize = 0;
    var head_end: usize = 0;
    var sep: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, out[0..ol], "\r\n\r\n")) |i| {
            head_end = i;
            sep = 4;
            break;
        }
        if (std.mem.indexOf(u8, out[0..ol], "\n\n")) |i| {
            head_end = i;
            sep = 2;
            break;
        }
        if (ol == out.len) return simple(c, r, .{ .code = 502, .text = "Bad Gateway" }, "", head_only, keep);
        const n = s.read(out[ol..]) catch |err| {
            if (err == error.TimedOut) {
                log("CGI {s}: no reply in time", .{script.path()});
                return simple(c, r, .{ .code = 504, .text = "Gateway Timeout" }, "", head_only, keep);
            }
            return simple(c, r, .{ .code = 502, .text = "Bad Gateway" }, "", head_only, keep);
        };
        if (n == 0) return simple(c, r, .{ .code = 502, .text = "Bad Gateway" }, "", head_only, keep);
        ol += n;
    }

    var status = ok;
    var status_text: [64]u8 = undefined;
    var location = false;
    var length_known = false;
    var have_type = false;
    var extra: [head_max + 256]u8 = undefined;
    var el: usize = 0;
    var hl = std.mem.splitScalar(u8, out[0..head_end], '\n');
    while (hl.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (eqlAny(name, "Status")) {
            const sp = std.mem.indexOfScalar(u8, value, ' ') orelse value.len;
            const code = std.fmt.parseInt(u16, value[0..sp], 10) catch 200;
            const text = std.mem.trim(u8, value[sp..], " ");
            const t = text[0..@min(text.len, status_text.len)];
            @memcpy(status_text[0..t.len], t);
            status = .{ .code = code, .text = if (t.len > 0) status_text[0..t.len] else reasonOf(code) };
            continue;
        }
        if (eqlAny(name, "Connection") or eqlAny(name, "Transfer-Encoding") or eqlAny(name, "Server") or eqlAny(name, "Date")) continue;
        if (eqlAny(name, "Location")) location = true;
        if (eqlAny(name, "Content-Length")) length_known = true;
        if (eqlAny(name, "Content-Type")) have_type = true;
        if (el + line.len + 2 > extra.len) continue;
        @memcpy(extra[el..][0..line.len], line);
        el += line.len;
        @memcpy(extra[el..][0..2], "\r\n");
        el += 2;
    }
    if (location and status.code == 200) status = .{ .code = 302, .text = "Found" };
    if (!have_type and !location) {
        const t = "Content-Type: text/html; charset=utf-8\r\n";
        @memcpy(extra[el..][0..t.len], t);
        el += t.len;
    }
    // Without a length: chunks (HTTP/1.1), or the end of the connection:
    const chunked = !length_known and r.http11 and !head_only;
    if (!length_known and !r.http11) keep.* = false;
    if (chunked) {
        const t = "Transfer-Encoding: chunked\r\n";
        @memcpy(extra[el..][0..t.len], t);
        el += t.len;
    }
    try writeHead(c, r, status, extra[0..el], keep.*);
    if (head_only) return status.code;

    // The body: what came with the headers, then the rest:
    var rest = out[head_end + sep .. ol];
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        if (rest.len > 0) {
            if (chunked) {
                var cb: [16]u8 = undefined;
                try c.send(std.fmt.bufPrint(&cb, "{x}\r\n", .{rest.len}) catch unreachable);
                try c.send(rest);
                try c.send("\r\n");
            } else try c.send(rest);
            c.sent += rest.len;
        }
        const n = s.read(&buf) catch |err| {
            // Cut off mid-reply: the connection can't go on:
            log("CGI {s}: {s}", .{ script.path(), if (err == error.TimedOut) "stopped: out of time" else errText(err) });
            keep.* = false;
            return error.Closed;
        };
        if (n == 0) break;
        rest = buf[0..n];
    }
    if (chunked) try c.send("0\r\n\r\n");
    return status.code;
}
