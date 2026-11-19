// FETCH [-o FILE] [-k] URL: AN HTTP OR HTTPS GET -k: no certificate
// check against CACERT.PEM. Exit code 0 for 2xx.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");
const Tls = @import("zdos/zcrypt.zig").Tls; // ZCRYPT.ZDL

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

fn usage() u8 {
    zdos.print("FETCH [-o FILE] [-k] URL   (http:// or https://host[:port]/path)\n");
    return 1;
}

const Url = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(text: []const u8) ?Url {
    var rest = text;
    var tls = false;
    if (std.ascii.startsWithIgnoreCase(rest, "http://")) {
        rest = rest["http://".len..];
    } else if (std.ascii.startsWithIgnoreCase(rest, "https://")) {
        rest = rest["https://".len..];
        tls = true;
    } else if (std.mem.indexOf(u8, rest, "://") != null) {
        return null;
    }
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    return .{ .tls = tls, .host = host, .port = port, .path = path };
}

var url_buf: [2048]u8 = undefined;
var next_buf: [2048]u8 = undefined;
var buf: [16 * 1024]u8 = undefined;
var verify = true;

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var out_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "-o")) {
            out_path = words.next() orelse return usage();
        } else if (std.mem.eql(u8, w, "-k")) {
            verify = false;
        } else if (w[0] == '-') {
            return usage();
        } else {
            target = w;
        }
    }
    var url_text = target orelse return usage();
    var redirects: u32 = 0;
    while (true) {
        const url = parseUrl(url_text) orelse return usage();
        const r = get(url, out_path) catch |err| {
            zdos.eprintf("FETCH: {s}: {s}\n", .{ url.host, errorText(err) });
            return 1;
        };
        switch (r) {
            .done => |status| return if (status >= 200 and status < 300) 0 else 1,
            .redirect => |location| {
                redirects += 1;
                if (redirects > 5) {
                    zdos.eprintf("FETCH: too many redirects\n", .{});
                    return 1;
                }
                // A path alone stays on the same server
                // (url still points into url_buf):
                const next = if (location.len > 0 and location[0] == '/')
                    std.fmt.bufPrint(&next_buf, "{s}://{s}:{d}{s}", .{ if (url.tls) "https" else "http", url.host, url.port, location }) catch return 1
                else if (location.len <= next_buf.len) blk: {
                    @memcpy(next_buf[0..location.len], location);
                    break :blk next_buf[0..location.len];
                } else return 1;
                @memcpy(url_buf[0..next.len], next);
                url_text = url_buf[0..next.len];
            },
        }
    }
}

fn errorText(err: anyerror) []const u8 {
    inline for (@typeInfo(zdos.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return zdos.message(@field(zdos.Error, e.name));
    }
    return switch (err) {
        error.TlsCertificateNotVerified => "the certificate isn't from a known authority (-k: don't check)",
        error.CertificateHostMismatch => "the certificate is for another name",
        error.CertificateExpired, error.CertificateNotYetValid => "the certificate isn't valid now (the clock?)",
        error.NoCertificates => "\\CONF\\CACERT.PEM is missing or empty (-k: don't check)",
        else => @errorName(err),
    };
}

const Result = union(enum) {
    done: u32, // the status
    redirect: []const u8, // Location (in buf)
};

const Conn = struct {
    s: net.Socket,
    tls: ?Tls,

    fn writeAll(self: Conn, data: []const u8) !void {
        if (self.tls) |c| return c.writeAll(data);
        return self.s.sendAll(data);
    }

    // 0: the end.
    fn read(self: Conn, out: []u8) !usize {
        if (self.tls) |c| return c.read(out);
        return self.s.recv(out);
    }
};

fn get(url: Url, out_path: ?[]const u8) !Result {
    const s = try net.Socket.connectTo(url.host, url.port);
    defer s.close();
    var conn: Conn = .{ .s = s, .tls = null };
    if (url.tls) conn.tls = try Tls.connect(s, url.host, verify, unixTime());
    defer if (conn.tls) |c| c.deinit();
    // HTTP/1.0: the body ends with the connection, never chunked:
    const request = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: ZDOS-FETCH\r\nAccept: */*\r\nConnection: close\r\n\r\n", .{ url.path, url.host }) catch return error.InvalidArgument;
    try conn.writeAll(request);

    var len: usize = 0;
    const header_end = while (true) {
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |e| break e + 4;
        if (len == buf.len) return error.MessageTooLong;
        const n = try conn.read(buf[len..]);
        if (n == 0) return error.ConnectionAborted;
        len += n;
    };
    const header = buf[0..header_end];
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    const status_line = lines.next() orelse return error.InvalidArgument;
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    if (status >= 300 and status < 400) {
        while (lines.next()) |line| {
            if (line.len > 9 and std.ascii.eqlIgnoreCase(line[0..9], "location:")) {
                return .{ .redirect = std.mem.trim(u8, line[9..], " \t") };
            }
        }
    }
    if (status < 200 or status >= 300) zdos.eprintf("FETCH: {s}\n", .{status_line});

    const file: ?zdos.File = if (out_path) |p| try zdos.open(p, .write) else null;
    defer if (file) |f| f.close();
    var body = buf[header_end..len];
    while (true) {
        if (body.len > 0) {
            if (file) |f| try f.writeAll(body) else zdos.print(body);
        }
        const n = try conn.read(&buf);
        if (n == 0) break;
        body = buf[0..n];
    }
    return .{ .done = status };
}

// ZDOS keeps local time: close enough for certificates.
fn unixTime() i64 {
    const t = zdos.getTime();
    const y: i64 = if (t.month <= 2) @as(i64, t.year) - 1 else t.year;
    const m: i64 = t.month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}
