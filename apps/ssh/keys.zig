// SSH key files as OpenSSH writes them:
// "openssh-key-v1" Ed25519 keys (passphrase: bcrypt + aes256-ctr), public key
// lines, authorized_keys and known_hosts.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const wire = @import("wire.zig");
const transport = @import("transport.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const b64 = std.base64.standard;

pub const Error = error{ BadKeyFile, NeedPassphrase, WrongPassphrase, UnsupportedKey } || wire.Error || zdos.Error;

const begin_line = "-----BEGIN OPENSSH PRIVATE KEY-----";
const end_line = "-----END OPENSSH PRIVATE KEY-----";
const magic = "openssh-key-v1\x00";

// A small file.
pub fn readFile(path: []const u8, buf: []u8) zdos.Error![]u8 {
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

// passphrase null: NeedPassphrase if it has one.
pub fn loadPrivate(path: []const u8, passphrase: ?[]const u8) Error!Ed25519.KeyPair {
    var text_buf: [8192]u8 = undefined;
    const text = try readFile(path, &text_buf);
    defer std.crypto.secureZero(u8, &text_buf);
    const b = std.mem.indexOf(u8, text, begin_line) orelse return error.BadKeyFile;
    const e = std.mem.indexOf(u8, text, end_line) orelse return error.BadKeyFile;
    if (e < b) return error.BadKeyFile;
    var clean: [6000]u8 = undefined;
    defer std.crypto.secureZero(u8, &clean);
    var n: usize = 0;
    for (text[b + begin_line.len .. e]) |c| {
        if (c == '\r' or c == '\n' or c == ' ' or c == '\t') continue;
        if (n == clean.len) return error.BadKeyFile;
        clean[n] = c;
        n += 1;
    }
    var raw: [4500]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    const len = b64.Decoder.calcSizeForSlice(clean[0..n]) catch return error.BadKeyFile;
    if (len > raw.len) return error.BadKeyFile;
    b64.Decoder.decode(raw[0..len], clean[0..n]) catch return error.BadKeyFile;
    return parsePrivate(raw[0..len], passphrase);
}

fn parsePrivate(data: []u8, passphrase: ?[]const u8) Error!Ed25519.KeyPair {
    if (!std.mem.startsWith(u8, data, magic)) return error.BadKeyFile;
    var r = wire.Reader.init(data[magic.len..]);
    const cipher = r.string() catch return error.BadKeyFile;
    const kdf = r.string() catch return error.BadKeyFile;
    const kdf_opts = r.string() catch return error.BadKeyFile;
    if ((r.int() catch return error.BadKeyFile) != 1) return error.UnsupportedKey;
    _ = r.string() catch return error.BadKeyFile; // the public key
    const at = magic.len + r.pos + 4;
    const section_len = r.int() catch return error.BadKeyFile;
    if (at + section_len > data.len) return error.BadKeyFile;
    const section = data[at..][0..section_len];
    if (std.mem.eql(u8, cipher, "aes256-ctr") and std.mem.eql(u8, kdf, "bcrypt")) {
        const pass = passphrase orelse return error.NeedPassphrase;
        var o = wire.Reader.init(kdf_opts);
        const salt = o.string() catch return error.BadKeyFile;
        const rounds = o.int() catch return error.BadKeyFile;
        var key_iv: [48]u8 = undefined;
        defer std.crypto.secureZero(u8, &key_iv);
        std.crypto.pwhash.bcrypt.opensshKdf(pass, salt, &key_iv, rounds) catch return error.BadKeyFile;
        const aes = std.crypto.core.aes.Aes256.initEnc(key_iv[0..32].*);
        var tmp: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &tmp);
        if (section.len > tmp.len) return error.BadKeyFile;
        std.crypto.core.modes.ctr(@TypeOf(aes), aes, tmp[0..section.len], section, key_iv[32..48].*, .big);
        @memcpy(section, tmp[0..section.len]);
    } else if (!std.mem.eql(u8, cipher, "none")) return error.UnsupportedKey;
    var s = wire.Reader.init(section);
    const check1 = s.int() catch return error.BadKeyFile;
    const check2 = s.int() catch return error.BadKeyFile;
    if (check1 != check2) return if (passphrase != null) error.WrongPassphrase else error.BadKeyFile;
    if (!std.mem.eql(u8, s.string() catch return error.BadKeyFile, "ssh-ed25519")) return error.UnsupportedKey;
    const pk = s.string() catch return error.BadKeyFile;
    const sk = s.string() catch return error.BadKeyFile;
    if (pk.len != 32 or sk.len != 64) return error.BadKeyFile;
    const secret = Ed25519.SecretKey.fromBytes(sk[0..64].*) catch return error.BadKeyFile;
    return Ed25519.KeyPair.fromSecretKey(secret) catch return error.BadKeyFile;
}

// Unencrypted, as ssh-keygen -N "".
pub fn savePrivate(path: []const u8, kp: Ed25519.KeyPair, comment: []const u8) Error!void {
    var blob: [51]u8 = undefined;
    transport.ed25519Blob(kp.public_key.toBytes(), &blob);
    var sec: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &sec);
    var s = wire.Writer.init(&sec);
    var check: [4]u8 = undefined;
    zdos.randomBytes(&check);
    try s.bytes(&check);
    try s.bytes(&check);
    try s.string("ssh-ed25519");
    try s.string(&kp.public_key.toBytes());
    try s.string(&kp.secret_key.toBytes());
    try s.string(comment[0..@min(comment.len, 200)]);
    var pad: u8 = 1;
    while (s.len % 8 != 0) : (pad += 1) try s.byte(pad);

    var raw: [1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &raw);
    var w = wire.Writer.init(&raw);
    try w.bytes(magic);
    try w.string("none");
    try w.string("none");
    try w.string("");
    try w.int(1);
    try w.string(&blob);
    try w.string(s.slice());

    var text: [1600]u8 = undefined;
    defer std.crypto.secureZero(u8, &text);
    var t = wire.Writer.init(&text);
    try t.bytes(begin_line ++ "\n");
    var enc: [1400]u8 = undefined;
    defer std.crypto.secureZero(u8, &enc);
    const encoded = b64.Encoder.encode(&enc, w.slice());
    var i: usize = 0;
    while (i < encoded.len) : (i += 70) {
        try t.bytes(encoded[i..@min(i + 70, encoded.len)]);
        try t.byte('\n');
    }
    try t.bytes(end_line ++ "\n");
    const f = try zdos.open(path, .write);
    defer f.close();
    try f.writeAll(t.slice());
    // Owner only, where the file system keeps modes:
    zdos.setMode(path, 0o600) catch {};
}

// "ssh-ed25519 AAAA... comment"
pub fn publicLine(pk: [32]u8, comment: []const u8, buf: []u8) []const u8 {
    var blob: [51]u8 = undefined;
    transport.ed25519Blob(pk, &blob);
    var enc: [80]u8 = undefined;
    const encoded = b64.Encoder.encode(&enc, &blob);
    return std.fmt.bufPrint(buf, "ssh-ed25519 {s} {s}", .{ encoded, comment }) catch buf[0..0];
}

// "SHA256:..." as ssh-keygen -l shows it.
pub fn fingerprint(blob: []const u8, buf: *[64]u8) []const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &h, .{});
    @memcpy(buf[0..7], "SHA256:");
    const enc = std.base64.standard_no_pad.Encoder.encode(buf[7..], &h);
    return buf[0 .. 7 + enc.len];
}

// Kind and base64 into buf; null if not a key line (options before it allowed).
pub fn lineBlob(line: []const u8, buf: []u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |word| {
        if (!std.mem.startsWith(u8, word, "ssh-") and !std.mem.startsWith(u8, word, "ecdsa-")) continue;
        const data = it.next() orelse return null;
        const len = b64.Decoder.calcSizeForSlice(data) catch return null;
        if (len > buf.len) return null;
        b64.Decoder.decode(buf[0..len], data) catch return null;
        var r = wire.Reader.init(buf[0..len]);
        const kind = r.string() catch return null;
        if (!std.mem.eql(u8, kind, word)) return null;
        return buf[0..len];
    }
    return null;
}

// authorized_keys
pub fn fileHasKey(path: []const u8, blob: []const u8) bool {
    var text_buf: [16384]u8 = undefined;
    const text = readFile(path, &text_buf) catch return false;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (l.len == 0 or l[0] == '#') continue;
        var b: [600]u8 = undefined;
        const found = lineBlob(l, &b) orelse continue;
        if (std.mem.eql(u8, found, blob)) return true;
    }
    return false;
}

pub const HostCheck = enum { known, unknown, changed };

// "host[:port] keytype base64" lines (OpenSSH's [host]:port too).
pub fn checkKnownHost(path: []const u8, host: []const u8, blob: []const u8) HostCheck {
    var text_buf: [32768]u8 = undefined;
    const text = readFile(path, &text_buf) catch return .unknown;
    var result: HostCheck = .unknown;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t");
        if (l.len == 0 or l[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, l, " \t");
        const hosts = words.next() orelse continue;
        if (!hostMatches(hosts, host)) continue;
        var b: [600]u8 = undefined;
        const found = lineBlob(l, &b) orelse continue;
        var fr = wire.Reader.init(found);
        var br = wire.Reader.init(blob);
        const same_kind = std.mem.eql(u8, fr.string() catch "", br.string() catch "x");
        if (std.mem.eql(u8, found, blob)) return .known;
        if (same_kind) result = .changed;
    }
    return result;
}

fn hostMatches(list: []const u8, host: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h, host)) return true;
    }
    return false;
}

pub fn addKnownHost(path: []const u8, host: []const u8, blob: []const u8) zdos.Error!void {
    var r = wire.Reader.init(blob);
    const kind = r.string() catch return error.InvalidArgument;
    var enc: [800]u8 = undefined;
    if (b64.Encoder.calcSize(blob.len) > enc.len) return error.InvalidArgument;
    const encoded = b64.Encoder.encode(&enc, blob);
    var line: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{s} {s} {s}\n", .{ host, kind, encoded }) catch return error.InvalidArgument;
    const f = zdos.open(path, .update) catch |err| switch (err) {
        error.NotFound => try zdos.open(path, .write),
        else => return err,
    };
    defer f.close();
    try f.seek(try f.size());
    try f.writeAll(text);
}
