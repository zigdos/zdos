// SFTPSRV: SFTP v3 over stdin and stdout, run by SSHD as the user.
// "/C:/USERS/alice/x.txt" is C:\USERS\alice\x.txt, relative paths are
// from the home folder, "/" lists the drives.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

const Fxp = struct {
    const init = 1;
    const version = 2;
    const open = 3;
    const close = 4;
    const read = 5;
    const write = 6;
    const lstat = 7;
    const fstat = 8;
    const setstat = 9;
    const fsetstat = 10;
    const opendir = 11;
    const readdir = 12;
    const remove = 13;
    const mkdir = 14;
    const rmdir = 15;
    const realpath = 16;
    const stat = 17;
    const rename = 18;
    const status = 101;
    const handle = 102;
    const data = 103;
    const name = 104;
    const attrs = 105;
};

const Status = struct {
    const ok = 0;
    const eof = 1;
    const no_such_file = 2;
    const permission_denied = 3;
    const failure = 4;
    const bad_message = 5;
    const op_unsupported = 8;
};

const Attr = struct {
    const size = 0x1;
    const uidgid = 0x2;
    const permissions = 0x4;
    const acmodtime = 0x8;
};

const Pflag = struct {
    const read = 0x1;
    const write = 0x2;
    const append = 0x4;
    const creat = 0x8;
    const trunc = 0x10;
    const excl = 0x20;
};

const max_handles = 32;
const Handle = union(enum) {
    free,
    file: struct { f: zdos.File, append: bool },
    dir: struct { d: zdos.Dir, done: bool },
    drives: bool, // "/": the drive letters (true once listed)
};
var handles = [_]Handle{.free} ** max_handles;

// The biggest request is a WRITE of 32 KiB and a bit.
var in_buf: [70 * 1024]u8 = undefined;
var out_buf: [70 * 1024]u8 = undefined;

pub fn main(_: []const u8) u8 {
    while (true) {
        var len_bytes: [4]u8 = undefined;
        if (!readAll(&len_bytes)) return 0;
        const len = std.mem.readInt(u32, &len_bytes, .big);
        if (len == 0 or len > in_buf.len) return 1;
        if (!readAll(in_buf[0..len])) return 1;
        handle(in_buf[0..len]);
    }
}

fn readAll(buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = zdos.readInput(buf[got..]);
        if (n == 0) return false;
        got += n;
    }
    return true;
}

const Out = struct {
    len: usize = 4, // the length field comes last

    fn byte(self: *Out, v: u8) void {
        if (self.len < out_buf.len) out_buf[self.len] = v;
        self.len += 1;
    }

    fn int(self: *Out, v: u32) void {
        if (self.len + 4 > out_buf.len) return;
        std.mem.writeInt(u32, out_buf[self.len..][0..4], v, .big);
        self.len += 4;
    }

    fn long(self: *Out, v: u64) void {
        if (self.len + 8 > out_buf.len) return;
        std.mem.writeInt(u64, out_buf[self.len..][0..8], v, .big);
        self.len += 8;
    }

    fn string(self: *Out, s: []const u8) void {
        if (self.len + 4 + s.len > out_buf.len) return;
        self.int(@intCast(s.len));
        @memcpy(out_buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn send(self: *Out) void {
        std.mem.writeInt(u32, out_buf[0..4], @intCast(self.len - 4), .big);
        zdos.print(out_buf[0..self.len]);
    }
};

fn status(id: u32, code: u32, msg: []const u8) void {
    var o: Out = .{};
    o.byte(Fxp.status);
    o.int(id);
    o.int(code);
    o.string(msg);
    o.string("");
    o.send();
}

fn failed(id: u32, err: zdos.Error) void {
    const code: u32 = switch (err) {
        error.NotFound, error.PathNotFound => Status.no_such_file,
        error.AccessDenied, error.WriteProtected => Status.permission_denied,
        else => Status.failure,
    };
    status(id, code, zdos.message(err));
}

const In = struct {
    data: []const u8,
    pos: usize = 0,

    fn int(self: *In) ?u32 {
        if (self.data.len - self.pos < 4) return null;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn long(self: *In) ?u64 {
        if (self.data.len - self.pos < 8) return null;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn string(self: *In) ?[]const u8 {
        const n = self.int() orelse return null;
        if (self.data.len - self.pos < n) return null;
        const s = self.data[self.pos..][0..n];
        self.pos += n;
        return s;
    }
};

const Attrs = struct {
    flags: u32 = 0,
    size: u64 = 0,
    permissions: u32 = 0,
    mtime: u32 = 0,
};

fn readAttrs(r: *In) ?Attrs {
    var a: Attrs = .{ .flags = r.int() orelse return null };
    if (a.flags & Attr.size != 0) a.size = r.long() orelse return null;
    if (a.flags & Attr.uidgid != 0) {
        _ = r.int() orelse return null;
        _ = r.int() orelse return null;
    }
    if (a.flags & Attr.permissions != 0) a.permissions = r.int() orelse return null;
    if (a.flags & Attr.acmodtime != 0) {
        _ = r.int() orelse return null;
        a.mtime = r.int() orelse return null;
    }
    return a;
}

fn handle(msg: []const u8) void {
    var r: In = .{ .data = msg[1..] };
    if (msg[0] == Fxp.init) {
        var o: Out = .{};
        o.byte(Fxp.version);
        o.int(3);
        return o.send();
    }
    const id = r.int() orelse return;
    switch (msg[0]) {
        Fxp.realpath => realpath(id, &r),
        Fxp.stat, Fxp.lstat => statPath(id, &r),
        Fxp.fstat => fstat(id, &r),
        Fxp.open => openFile(id, &r),
        Fxp.close => closeHandle(id, &r),
        Fxp.read => readFile(id, &r),
        Fxp.write => writeFile(id, &r),
        Fxp.opendir => openDir(id, &r),
        Fxp.readdir => readDir(id, &r),
        Fxp.setstat => setStat(id, &r),
        Fxp.fsetstat => status(id, Status.ok, ""), // kept as they are
        Fxp.remove => pathOp(id, &r, .remove),
        Fxp.mkdir => pathOp(id, &r, .mkdir),
        Fxp.rmdir => pathOp(id, &r, .rmdir),
        Fxp.rename => rename(id, &r),
        else => status(id, Status.op_unsupported, "not supported"),
    }
}

// "/C:/x" is "C:\x", "/" null (the drives).
fn zdosPath(p: []const u8, buf: *[600]u8) ?[]const u8 {
    var s = p;
    if (s.len == 0) return ".";
    if (s[0] == '/') {
        s = std.mem.trimLeft(u8, s, "/");
        if (s.len == 0) return null;
    }
    const n = @min(s.len, buf.len - 1);
    for (s[0..n], 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    // "C:" alone is that drive's root:
    if (n == 2 and buf[1] == ':') {
        buf[2] = '\\';
        return buf[0..3];
    }
    return buf[0..n];
}

// "C:\USERS\x" as "/C:/USERS/x"
fn clientPath(full: []const u8, buf: *[600]u8) []const u8 {
    buf[0] = '/';
    var n: usize = 1;
    for (full) |c| {
        if (n == buf.len) break;
        buf[n] = if (c == '\\') '/' else c;
        n += 1;
    }
    if (n > 4 and buf[n - 1] == '/') n -= 1; // "/C:/" stays, "/C:/X/" doesn't
    return buf[0..n];
}

fn realpath(id: u32, r: *In) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    var pb: [600]u8 = undefined;
    var full_buf: [600]u8 = undefined;
    var cb: [600]u8 = undefined;
    const out = if (zdosPath(p, &pb)) |zp|
        clientPath(zdos.fullPath(zp, &full_buf) catch |err| return failed(id, err), &cb)
    else
        "/";
    var o: Out = .{};
    o.byte(Fxp.name);
    o.int(id);
    o.int(1);
    o.string(out);
    o.string(out);
    o.int(0);
    o.send();
}

fn putAttrs(o: *Out, x: *const zdos.StatEx) void {
    o.int(Attr.size | Attr.uidgid | Attr.permissions | Attr.acmodtime);
    o.long(x.file_size);
    o.int(x.uid);
    o.int(x.gid);
    var mode = x.mode;
    if (mode & 0o170000 == 0) mode |= if (x.is_dir) 0o040000 else 0o100000;
    o.int(mode);
    const t: u32 = @intCast(@max(0, unixTime(x.modified)));
    o.int(if (x.accessed.year != 0) @intCast(@max(0, unixTime(x.accessed))) else t);
    o.int(t);
}

fn statPath(id: u32, r: *In) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    var pb: [600]u8 = undefined;
    var o: Out = .{};
    o.byte(Fxp.attrs);
    o.int(id);
    const zp = zdosPath(p, &pb) orelse {
        o.int(Attr.permissions);
        o.int(0o040555);
        return o.send();
    };
    const x = zdos.statEx(zp) catch |err| return failed(id, err);
    putAttrs(&o, &x);
    o.send();
}

fn fstat(id: u32, r: *In) void {
    const h = handleOf(r) orelse return status(id, Status.failure, "bad handle");
    switch (h.*) {
        .file => |f| {
            const x = f.f.statEx() catch |err| return failed(id, err);
            var o: Out = .{};
            o.byte(Fxp.attrs);
            o.int(id);
            putAttrs(&o, &x);
            o.send();
        },
        else => status(id, Status.failure, "not a file"),
    }
}

// From ZDOS's local time.
fn unixTime(t: zdos.Time) i64 {
    if (t.year == 0) return 0;
    const y: i64 = if (t.month <= 2) @as(i64, t.year) - 1 else t.year;
    const m: i64 = t.month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}

fn fromUnix(secs: u32) zdos.Time {
    const days: i64 = @divFloor(@as(i64, secs), 86400);
    const rest: u32 = @intCast(@mod(@as(i64, secs), 86400));
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d), .hour = @intCast(rest / 3600), .minute = @intCast(rest / 60 % 60), .second = @intCast(rest % 60) };
}

fn setStat(id: u32, r: *In) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    const a = readAttrs(r) orelse return status(id, Status.bad_message, "");
    var pb: [600]u8 = undefined;
    const zp = zdosPath(p, &pb) orelse return status(id, Status.permission_denied, "");
    if (a.flags & Attr.size != 0) {
        const f = zdos.open(zp, .update) catch |err| return failed(id, err);
        defer f.close();
        f.setSize(a.size) catch |err| return failed(id, err);
    }
    if (a.flags & Attr.permissions != 0) zdos.setMode(zp, a.permissions & 0o7777) catch {};
    if (a.flags & Attr.acmodtime != 0) zdos.setFileTime(zp, fromUnix(a.mtime)) catch {};
    status(id, Status.ok, "");
}

fn newHandle(h: Handle) ?u32 {
    for (&handles, 0..) |*slot, i| {
        if (slot.* == .free) {
            slot.* = h;
            return @intCast(i);
        }
    }
    return null;
}

fn handleOf(r: *In) ?*Handle {
    const s = r.string() orelse return null;
    if (s.len != 4) return null;
    const i = std.mem.readInt(u32, s[0..4], .big);
    if (i >= max_handles or handles[i] == .free) return null;
    return &handles[i];
}

fn sendHandle(id: u32, i: u32) void {
    var hb: [4]u8 = undefined;
    std.mem.writeInt(u32, &hb, i, .big);
    var o: Out = .{};
    o.byte(Fxp.handle);
    o.int(id);
    o.string(&hb);
    o.send();
}

fn openFile(id: u32, r: *In) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    const flags = r.int() orelse return status(id, Status.bad_message, "");
    _ = readAttrs(r);
    var pb: [600]u8 = undefined;
    const zp = zdosPath(p, &pb) orelse return status(id, Status.permission_denied, "");
    const exists = if (zdos.stat(zp)) |_| true else |_| false;
    if (flags & Pflag.excl != 0 and exists) return status(id, Status.failure, "exists already");
    const mode: zdos.OpenMode = if (flags & Pflag.write == 0)
        .read
    else if (flags & Pflag.trunc != 0 or (!exists and flags & Pflag.creat != 0))
        .write
    else if (exists)
        .update
    else
        return status(id, Status.no_such_file, "no such file");
    const f = zdos.open(zp, mode) catch |err| return failed(id, err);
    const i = newHandle(.{ .file = .{ .f = f, .append = flags & Pflag.append != 0 } }) orelse {
        f.close();
        return status(id, Status.failure, "too many open files");
    };
    sendHandle(id, i);
}

fn closeHandle(id: u32, r: *In) void {
    const h = handleOf(r) orelse return status(id, Status.failure, "bad handle");
    switch (h.*) {
        .file => |f| {
            h.* = .free;
            f.f.closeChecked() catch |err| return failed(id, err);
        },
        .dir => |d| d.d.close(),
        else => {},
    }
    h.* = .free;
    status(id, Status.ok, "");
}

fn readFile(id: u32, r: *In) void {
    const h = handleOf(r) orelse return status(id, Status.failure, "bad handle");
    const offset = r.long() orelse return status(id, Status.bad_message, "");
    const want = @min(r.int() orelse return status(id, Status.bad_message, ""), 64 * 1024);
    const f = switch (h.*) {
        .file => |x| x.f,
        else => return status(id, Status.failure, "not a file"),
    };
    f.seek(offset) catch return status(id, Status.eof, "");
    // Type, id, then the data as a string, read straight into place:
    var o: Out = .{};
    o.byte(Fxp.data);
    o.int(id);
    const at = o.len + 4;
    var got: usize = 0;
    while (got < want) {
        const n = f.read(out_buf[at + got .. at + want]) catch |err| return failed(id, err);
        if (n == 0) break;
        got += n;
    }
    if (got == 0) return status(id, Status.eof, "");
    o.int(@intCast(got));
    o.len += got;
    o.send();
}

fn writeFile(id: u32, r: *In) void {
    const h = handleOf(r) orelse return status(id, Status.failure, "bad handle");
    const offset = r.long() orelse return status(id, Status.bad_message, "");
    const data = r.string() orelse return status(id, Status.bad_message, "");
    const x = switch (h.*) {
        .file => |x| x,
        else => return status(id, Status.failure, "not a file"),
    };
    const at = if (x.append) x.f.size() catch offset else offset;
    x.f.seek(at) catch |err| return failed(id, err);
    x.f.writeAll(data) catch |err| return failed(id, err);
    status(id, Status.ok, "");
}

fn openDir(id: u32, r: *In) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    var pb: [600]u8 = undefined;
    const i = if (zdosPath(p, &pb)) |zp| blk: {
        const d = zdos.openDir(zp) catch |err| return failed(id, err);
        break :blk newHandle(.{ .dir = .{ .d = d, .done = false } }) orelse {
            d.close();
            return status(id, Status.failure, "too many open folders");
        };
    } else newHandle(.{ .drives = false }) orelse return status(id, Status.failure, "too many open folders");
    sendHandle(id, i);
}

fn readDir(id: u32, r: *In) void {
    const h = handleOf(r) orelse return status(id, Status.failure, "bad handle");
    var o: Out = .{};
    o.byte(Fxp.name);
    o.int(id);
    const count_at = o.len;
    o.int(0);
    var count: u32 = 0;
    switch (h.*) {
        .drives => |listed| {
            if (listed) return status(id, Status.eof, "");
            h.* = .{ .drives = true };
            var letters: [26]u8 = undefined;
            for (zdos.getDrives(&letters)) |l| {
                const name = [2]u8{ l, ':' };
                o.string(&name);
                o.string(&name);
                o.int(Attr.permissions);
                o.int(0o040755);
                count += 1;
            }
        },
        .dir => |*d| {
            if (d.done) return status(id, Status.eof, "");
            // As many as fit comfortably in one answer:
            while (count < 64 and o.len < out_buf.len - 2048) {
                var info: zdos.StatEx = undefined;
                var name_buf: [256]u8 = undefined;
                const name = (d.d.nextEx(&info, &name_buf) catch null) orelse {
                    d.done = true;
                    break;
                };
                o.string(name);
                var long_buf: [400]u8 = undefined;
                o.string(longName(name, &info, &long_buf));
                putAttrs(&o, &info);
                count += 1;
            }
            if (count == 0) return status(id, Status.eof, "");
        },
        else => return status(id, Status.failure, "not a folder"),
    }
    std.mem.writeInt(u32, out_buf[count_at..][0..4], count, .big);
    o.send();
}

// As ls -l: clients print it as it is.
fn longName(name: []const u8, x: *const zdos.StatEx, buf: *[400]u8) []const u8 {
    var perms: [10]u8 = "----------".*;
    if (x.is_dir) perms[0] = 'd';
    const bits = "rwxrwxrwx";
    for (0..9) |i| {
        if (x.mode & (@as(u32, 0o400) >> @intCast(i)) != 0) perms[i + 1] = bits[i];
    }
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const t = x.modified;
    const mon = if (t.month >= 1 and t.month <= 12) months[t.month - 1] else "Jan";
    return std.fmt.bufPrint(buf, "{s} 1 {d} {d} {d:>8} {s} {d:>2} {d:0>2}:{d:0>2} {s}", .{ perms, x.uid, x.gid, x.file_size, mon, t.day, t.hour, t.minute, name }) catch name;
}

const PathOp = enum { remove, mkdir, rmdir };

fn pathOp(id: u32, r: *In, op: PathOp) void {
    const p = r.string() orelse return status(id, Status.bad_message, "");
    var pb: [600]u8 = undefined;
    const zp = zdosPath(p, &pb) orelse return status(id, Status.permission_denied, "");
    switch (op) {
        .remove => zdos.delete(zp) catch |err| return failed(id, err),
        .mkdir => {
            const a = readAttrs(r);
            zdos.makeDir(zp) catch |err| return failed(id, err);
            if (a) |at| if (at.flags & Attr.permissions != 0) zdos.setMode(zp, at.permissions & 0o7777) catch {};
        },
        .rmdir => {
            // Only an empty one, as rmdir:
            const d = zdos.openDir(zp) catch |err| return failed(id, err);
            var e: zdos.DirEntry = undefined;
            var empty = true;
            while (d.next(&e) catch false) {
                const n = e.name();
                if (!std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..")) {
                    empty = false;
                    break;
                }
            }
            d.close();
            if (!empty) return status(id, Status.failure, "folder not empty");
            zdos.deleteTree(zp) catch |err| return failed(id, err);
        },
    }
    status(id, Status.ok, "");
}

fn rename(id: u32, r: *In) void {
    const from = r.string() orelse return status(id, Status.bad_message, "");
    const to = r.string() orelse return status(id, Status.bad_message, "");
    var fb: [600]u8 = undefined;
    var tb: [600]u8 = undefined;
    const zf = zdosPath(from, &fb) orelse return status(id, Status.permission_denied, "");
    const zt = zdosPath(to, &tb) orelse return status(id, Status.permission_denied, "");
    if (zdos.stat(zt)) |_| return status(id, Status.failure, "the target exists") else |_| {}
    zdos.move(zf, zt) catch |err| return failed(id, err);
    status(id, Status.ok, "");
}
