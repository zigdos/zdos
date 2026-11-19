// SSHKEY [-f FILE] [-C COMMENT] | -l FILE: Ed25519 KEYS FOR SSH
// Default FILE: %HOME%\.SSH\ID_ED25519.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const keys = @import("ssh/keys.zig");
const transport = @import("ssh/transport.zig");
const Ed25519 = @import("zdos/zcrypt.zig").Ed25519; // ZCRYPT.ZDL

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

fn usage() u8 {
    zdos.print("SSHKEY [-f FILE] [-C COMMENT]   or   SSHKEY -l FILE\n");
    return 1;
}

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var file: ?[]const u8 = null;
    var comment: ?[]const u8 = null;
    var list: ?[]const u8 = null;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "-f")) {
            file = words.next() orelse return usage();
        } else if (std.mem.eql(u8, w, "-C")) {
            comment = words.next() orelse return usage();
        } else if (std.mem.eql(u8, w, "-l")) {
            list = words.next() orelse return usage();
        } else return usage();
    }
    if (list) |path| return showFingerprint(path);

    var hb: [300]u8 = undefined;
    var path_buf: [320]u8 = undefined;
    const path = file orelse blk: {
        const home = zdos.getVar("HOME", &hb) orelse return usage();
        var dir_buf: [310]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}\\.SSH", .{home}) catch return 1;
        zdos.makeDir(dir) catch {};
        break :blk std.fmt.bufPrint(&path_buf, "{s}\\ID_ED25519", .{dir}) catch return 1;
    };
    if (zdos.stat(path)) |_| {
        zdos.printf("{s} exists already; delete it first to make a new key\n", .{path});
        return 1;
    } else |_| {}
    var ub: [64]u8 = undefined;
    var host_b: [64]u8 = undefined;
    var cb: [140]u8 = undefined;
    const who = comment orelse (std.fmt.bufPrint(&cb, "{s}@{s}", .{ zdos.getVar("USER", &ub) orelse "ROOT", zdos.getVar("HOSTNAME", &host_b) orelse "zdos" }) catch "zdos");

    var seed: [32]u8 = undefined;
    zdos.randomBytes(&seed);
    defer std.crypto.secureZero(u8, &seed);
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return 1;
    keys.savePrivate(path, kp, who) catch |err| {
        zdos.printf("{s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    var pub_path_buf: [330]u8 = undefined;
    const pub_path = std.fmt.bufPrint(&pub_path_buf, "{s}.PUB", .{path}) catch return 1;
    var line_buf: [300]u8 = undefined;
    const line = keys.publicLine(kp.public_key.toBytes(), who, &line_buf);
    const f = zdos.open(pub_path, .write) catch |err| {
        zdos.printf("{s}: {s}\n", .{ pub_path, zdos.message(err) });
        return 1;
    };
    defer f.close();
    f.writeAll(line) catch {};
    f.writeAll("\n") catch {};
    var blob: [51]u8 = undefined;
    transport.ed25519Blob(kp.public_key.toBytes(), &blob);
    var fp: [64]u8 = undefined;
    zdos.printf("Private key: {s}\nPublic key:  {s}\nFingerprint: {s}\n{s}\n", .{ path, pub_path, keys.fingerprint(&blob, &fp), line });
    return 0;
}

fn showFingerprint(path: []const u8) u8 {
    var text_buf: [4096]u8 = undefined;
    const text = keys.readFile(path, &text_buf) catch |err| {
        zdos.printf("{s}: {s}\n", .{ path, zdos.message(err) });
        return 1;
    };
    var blob_buf: [600]u8 = undefined;
    var blob: []const u8 = undefined;
    var pk_blob: [51]u8 = undefined;
    if (keys.lineBlob(text, &blob_buf)) |b| {
        blob = b;
    } else {
        const kp = keys.loadPrivate(path, null) catch |err| {
            zdos.printf("{s}: {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        transport.ed25519Blob(kp.public_key.toBytes(), &pk_blob);
        blob = &pk_blob;
    }
    var fp: [64]u8 = undefined;
    zdos.printf("{s}\n", .{keys.fingerprint(blob, &fp)});
    return 0;
}
