// The users, in \CONF on the programs' drive (# comments):
//   USERS.CFG   name:uid:x:shell    (shell empty: COMSPEC)
//   SHADOW.CFG  name:hash           (root only; Argon2id, or sha256$)
//   GROUPS.CFG  name:gid:member,... (ADMINS, gid 10: SU and SUDO)
// Programs share all memory: permissions only keep out mistakes.
const std = @import("std");
const zdos = @import("zdos.zig");

pub const max_users = 64;
pub const max_name = 32;

pub const User = struct {
    name: []const u8,
    uid: u32,
    password: []const u8,
    shell: []const u8,
};

pub const List = struct {
    users: [max_users]User = undefined,
    count: usize = 0,
    text: [16 * 1024]u8 = undefined, // the file's text, where the fields point
    shadow_text: [16 * 1024]u8 = undefined,
    // SHADOW.CFG read, or no passwords anywhere yet; saving needs it, so
    // that none is lost:
    passwords_known: bool = false,
    // New passwords and users live here:
    extra: [4 * 1024]u8 = undefined,
    extra_len: usize = 0,

    pub fn find(self: *List, name: []const u8) ?*User {
        for (self.users[0..self.count]) |*u| {
            if (std.ascii.eqlIgnoreCase(u.name, name)) return u;
        }
        return null;
    }

    pub fn findUid(self: *List, uid: u32) ?*User {
        for (self.users[0..self.count]) |*u| {
            if (u.uid == uid) return u;
        }
        return null;
    }

    // Lives as long as the list.
    pub fn keep(self: *List, text: []const u8) ?[]const u8 {
        if (self.extra_len + text.len > self.extra.len) return null;
        const out = self.extra[self.extra_len..][0..text.len];
        @memcpy(out, text);
        self.extra_len += text.len;
        return out;
    }

    // 1-4294967294: 0 is root's, the last means "keep".
    pub fn parseUid(text: []const u8) ?u32 {
        const v = std.fmt.parseInt(u32, text, 10) catch return null;
        return if (v == 0 or v == std.math.maxInt(u32)) null else v;
    }

    // From 1000, as on Linux.
    pub fn nextUid(self: *List) u32 {
        var uid: u32 = 1000;
        for (self.users[0..self.count]) |u| uid = @max(uid, u.uid + 1);
        return uid;
    }

    pub fn add(self: *List, user: User) bool {
        if (self.count == max_users) return false;
        self.users[self.count] = user;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *List, name: []const u8) bool {
        for (self.users[0..self.count], 0..) |u, i| {
            if (!std.ascii.eqlIgnoreCase(u.name, name)) continue;
            std.mem.copyForwards(User, self.users[i .. self.count - 1], self.users[i + 1 .. self.count]);
            self.count -= 1;
            return true;
        }
        return false;
    }
};

// On the drive this program is on.
fn onProgramDrive(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var prog_buf: [300]u8 = undefined;
    const prog = zdos.programPath(&prog_buf);
    const drive = if (prog.len >= 2 and prog[1] == ':') prog[0] else 'C';
    return std.fmt.bufPrint(buf, "{c}:" ++ fmt, .{drive} ++ args) catch "";
}

pub fn filePath(buf: []u8) []const u8 {
    return onProgramDrive(buf, "\\CONF\\USERS.CFG", .{});
}

pub fn homeOf(name: []const u8, buf: []u8) []const u8 {
    return onProgramDrive(buf, "\\USERS\\{s}", .{name});
}

// Made if missing; where the drive has owners it becomes the user's, mode 0700.
// Run as root.
pub fn makeHome(u: *const User, buf: []u8) []const u8 {
    const home = homeOf(u.name, buf);
    zdos.makeDir(home[0 .. home.len - u.name.len - 1]) catch {};
    if (zdos.makeDir(home)) {
        zdos.setOwner(home, u.uid, u.uid) catch {};
        zdos.setMode(home, 0o700) catch {};
    } else |_| {}
    return home;
}

pub fn shadowPath(buf: []u8) []const u8 {
    return onProgramDrive(buf, "\\CONF\\SHADOW.CFG", .{});
}

// 0 if it isn't there.
fn readAll(path: []const u8, buf: []u8) zdos.Error!usize {
    const f = zdos.open(path, .read) catch |err| {
        if (err == error.NotFound or err == error.PathNotFound) return 0;
        return err;
    };
    defer f.close();
    var len: usize = 0;
    while (len < buf.len) {
        const n = try f.read(buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return len;
}

// With their passwords where the program may read them; a missing
// file gives root alone, without a password.
pub fn load(list: *List) zdos.Error!void {
    try loadUsers(list);
    // SHADOW.CFG, else what older ZDOS kept in USERS.CFG:
    var path_buf: [300]u8 = undefined;
    const len = readAll(shadowPath(&path_buf), &list.shadow_text) catch |err| switch (err) {
        error.AccessDenied => return, // not root: the passwords stay "x"
        else => return err,
    };
    var lines = std.mem.splitScalar(u8, list.shadow_text[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (list.find(line[0..colon])) |u| u.password = line[colon + 1 ..];
    }
    list.passwords_known = true;
    // Users without a line in SHADOW.CFG: no password:
    for (list.users[0..list.count]) |*u| {
        if (std.mem.eql(u8, u.password, "x")) u.password = "";
    }
}

fn loadUsers(list: *List) zdos.Error!void {
    list.count = 0;
    list.extra_len = 0;
    list.passwords_known = false;
    var path_buf: [300]u8 = undefined;
    const f = zdos.open(filePath(&path_buf), .read) catch |err| {
        if (err != error.NotFound and err != error.PathNotFound) return err;
        _ = list.add(.{ .name = "ROOT", .uid = 0, .password = "", .shell = "" });
        return;
    };
    defer f.close();
    var len: usize = 0;
    while (len < list.text.len) {
        const n = try f.read(list.text[len..]);
        if (n == 0) break;
        len += n;
    }
    var lines = std.mem.splitScalar(u8, list.text[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        const uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const password = fields.next() orelse "";
        const shell = fields.rest();
        if (!validName(name)) continue;
        _ = list.add(.{ .name = name, .uid = uid, .password = password, .shell = shell });
    }
    if (list.find("ROOT") == null) _ = list.add(.{ .name = "ROOT", .uid = 0, .password = "", .shell = "" });
}

// SHADOW.CFG gets mode 0600 where the drive keeps modes.
pub fn save(list: *const List) zdos.Error!void {
    if (!list.passwords_known) return error.AccessDenied; // they would be lost
    var path_buf: [300]u8 = undefined;
    const path = filePath(&path_buf);
    zdos.makeDir(path[0 .. path.len - "\\USERS.CFG".len]) catch {};
    // The passwords first: a crash between the two loses no password:
    var shadow_buf: [300]u8 = undefined;
    const shadow = shadowPath(&shadow_buf);
    const s = try zdos.open(shadow, .write);
    zdos.setMode(shadow, 0o600) catch {};
    errdefer s.close();
    try s.writeAll("# ZDOS passwords: name:hash, for root only (see README.md, Users)\n");
    for (list.users[0..list.count]) |u| {
        var line: [256]u8 = undefined;
        try s.writeAll(std.fmt.bufPrint(&line, "{s}:{s}\n", .{ u.name, u.password }) catch continue);
    }
    try s.closeChecked();
    const f = try zdos.open(path, .write);
    errdefer f.close();
    try f.writeAll("# ZDOS users: name:uid:x:shell (see README.md, Users)\n");
    for (list.users[0..list.count]) |u| {
        var line: [512]u8 = undefined;
        try f.writeAll(std.fmt.bufPrint(&line, "{s}:{d}:x:{s}\n", .{ u.name, u.uid, u.shell }) catch continue);
    }
    try f.closeChecked();
}

// Letters, digits, _ . -; up to 32, starting with a letter or _.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-') return false;
    }
    return true;
}

// USER; root if unset.
pub fn current(buf: []u8) []const u8 {
    return zdos.getVar("USER", buf) orelse "ROOT";
}

// Also a setuid program such as SU.
pub fn isRoot() bool {
    return zdos.getIds().uid == 0;
}

// The disk tools pass file permissions, so ZDOS lets only root: true
// and a message if not root.
pub fn diskToolDenied(tool: []const u8) bool {
    if (isRoot()) return false;
    zdos.printf("{s}: Access denied: only root may use it (SUDO {s} ...)\n", .{ tool, tool });
    return true;
}

// May set the clock, power off and global variables (ZDOS checks too).
pub fn isAdmin() bool {
    const ids = zdos.getIds();
    if (ids.uid == 0 or ids.gid == admins_gid) return true;
    for (ids.groups[0..@min(ids.group_count, ids.groups.len)]) |g| {
        if (g == admins_gid) return true;
    }
    return false;
}

// LOGIN restores the variables after startup for each login.

pub const Snapshot = struct {
    text: [16 * 1024]u8 = undefined,
    len: usize = 0,
};

// "NAME=value" lines.
pub fn takeSnapshot(s: *Snapshot) void {
    s.len = 0;
    var index: u32 = 0;
    var buf: [600]u8 = undefined;
    while (zdos.varAt(index, &buf)) |entry| : (index += 1) {
        if (s.len + entry.len + 1 > s.text.len) break;
        @memcpy(s.text[s.len..][0..entry.len], entry);
        s.text[s.len + entry.len] = '\n';
        s.len += entry.len + 1;
    }
}

// Those set since removed, the others back.
pub fn restoreSnapshot(s: *const Snapshot) void {
    // Names first: removing changes the numbering:
    var names: [128][40]u8 = undefined;
    var lens: [128]usize = undefined;
    var count: usize = 0;
    var index: u32 = 0;
    var buf: [600]u8 = undefined;
    while (zdos.varAt(index, &buf)) |entry| : (index += 1) {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (count == names.len or eq > names[0].len) continue;
        @memcpy(names[count][0..eq], entry[0..eq]);
        lens[count] = eq;
        count += 1;
    }
    for (names[0..count], lens[0..count]) |*n, l| zdos.setVar(n[0..l], "") catch {};
    var lines = std.mem.splitScalar(u8, s.text[0..s.len], '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        zdos.setVar(line[0..eq], line[eq + 1 ..]) catch {};
    }
}

// Users must be loaded.
pub fn realUser(list: *List) ?*User {
    return list.findUid(zdos.getIds().real);
}

// GROUPS

pub const max_groups = 32;
pub const admins = "ADMINS";
pub const admins_gid = 10;

pub const Group = struct {
    name: []const u8,
    gid: u32,
    members: []const u8, // "alice,bob"
};

pub const Groups = struct {
    groups: [max_groups]Group = undefined,
    count: usize = 0,
    text: [8 * 1024]u8 = undefined,
    extra: [4 * 1024]u8 = undefined,
    extra_len: usize = 0,

    pub fn find(self: *Groups, name: []const u8) ?*Group {
        for (self.groups[0..self.count]) |*g| {
            if (std.ascii.eqlIgnoreCase(g.name, name)) return g;
        }
        return null;
    }

    pub fn isMember(self: *Groups, group: []const u8, user: []const u8) bool {
        const g = self.find(group) orelse return false;
        return hasMember(g.members, user);
    }

    // Besides their own, as numbers.
    pub fn gidsOf(self: *Groups, user: []const u8, out: []u32) usize {
        var n: usize = 0;
        for (self.groups[0..self.count]) |g| {
            if (n < out.len and hasMember(g.members, user)) {
                out[n] = g.gid;
                n += 1;
            }
        }
        return n;
    }

    pub fn keep(self: *Groups, text: []const u8) ?[]const u8 {
        if (self.extra_len + text.len > self.extra.len) return null;
        const out = self.extra[self.extra_len..][0..text.len];
        @memcpy(out, text);
        self.extra_len += text.len;
        return out;
    }

    // Exactly the groups in list ("ADMINS,games"); new ones are
    // made (from 100). False if one is unusable.
    pub fn setMembership(self: *Groups, user: []const u8, list: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |name| {
            if (!validName(name)) return false;
            if (self.find(name) == null) {
                if (self.count == max_groups) return false;
                var gid: u32 = 100;
                for (self.groups[0..self.count]) |g| {
                    if (g.gid >= 100 and g.gid < 1000) gid = @max(gid, g.gid + 1);
                }
                self.groups[self.count] = .{ .name = self.keep(name) orelse return false, .gid = gid, .members = "" };
                self.count += 1;
            }
        }
        for (self.groups[0..self.count]) |*g| {
            const wanted = hasMember(list, g.name);
            if (wanted == hasMember(g.members, user)) continue;
            // The member list again, with or without user:
            var buf: [1024]u8 = undefined;
            var n: usize = 0;
            var members = std.mem.tokenizeScalar(u8, g.members, ',');
            while (members.next()) |m| {
                if (std.ascii.eqlIgnoreCase(m, user)) continue;
                if (n + m.len + 1 > buf.len) return false;
                if (n > 0) {
                    buf[n] = ',';
                    n += 1;
                }
                @memcpy(buf[n..][0..m.len], m);
                n += m.len;
            }
            if (wanted) {
                if (n + user.len + 1 > buf.len) return false;
                if (n > 0) {
                    buf[n] = ',';
                    n += 1;
                }
                @memcpy(buf[n..][0..user.len], user);
                n += user.len;
            }
            g.members = self.keep(buf[0..n]) orelse return false;
        }
        return true;
    }
};

fn hasMember(members: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, members, ',');
    while (it.next()) |m| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, m, " "), name)) return true;
    }
    return false;
}

pub fn groupsPath(buf: []u8) []const u8 {
    return onProgramDrive(buf, "\\CONF\\GROUPS.CFG", .{});
}

// A missing file gives root (0) and admins (10), both empty.
pub fn loadGroups(g: *Groups) zdos.Error!void {
    g.count = 0;
    g.extra_len = 0;
    var path_buf: [300]u8 = undefined;
    var len: usize = 0;
    if (zdos.open(groupsPath(&path_buf), .read)) |f| {
        defer f.close();
        while (len < g.text.len) {
            const n = try f.read(g.text[len..]);
            if (n == 0) break;
            len += n;
        }
    } else |err| if (err != error.NotFound and err != error.PathNotFound) return err;
    var lines = std.mem.splitScalar(u8, g.text[0..len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or g.count == max_groups) continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        const gid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        g.groups[g.count] = .{ .name = name, .gid = gid, .members = fields.rest() };
        g.count += 1;
    }
    for ([_]Group{ .{ .name = "ROOT", .gid = 0, .members = "" }, .{ .name = admins, .gid = admins_gid, .members = "" } }) |d| {
        if (g.find(d.name) == null and g.count < max_groups) {
            g.groups[g.count] = d;
            g.count += 1;
        }
    }
}

pub fn saveGroups(g: *const Groups) zdos.Error!void {
    var path_buf: [300]u8 = undefined;
    const f = try zdos.open(groupsPath(&path_buf), .write);
    errdefer f.close();
    try f.writeAll("# ZDOS groups: name:gid:member,member (see README.md, Users)\n");
    for (g.groups[0..g.count]) |gr| {
        var line: [1200]u8 = undefined;
        try f.writeAll(std.fmt.bufPrint(&line, "{s}:{d}:{s}\n", .{ gr.name, gr.gid, gr.members }) catch continue);
    }
    try f.closeChecked();
}

// For good: real and effective user, own and other groups; saved: what
// it may switch back to (keep_id: as it is, root's for LOGIN).
pub fn become(u: *const User, saved: u32) zdos.Error!void {
    var groups: Groups = .{};
    loadGroups(&groups) catch {};
    var ids: zdos.Ids = .{ .real = u.uid, .uid = u.uid, .saved = saved, .gid = u.uid, .group_count = 0, .groups = undefined };
    ids.group_count = @intCast(groups.gidsOf(u.name, &ids.groups));
    return zdos.setIds(ids);
}

// The old values go into saved: variables are global.
pub const SavedVars = struct {
    bufs: [3][300]u8 = undefined,
    values: [3]?[]const u8 = .{ null, null, null },
};
const user_vars = [_][]const u8{ "USER", "LOGNAME", "HOME" };

pub fn setUserVars(u: *const User, saved: ?*SavedVars) void {
    if (saved) |s| {
        for (user_vars, 0..) |name, i| s.values[i] = zdos.getVar(name, &s.bufs[i]);
    }
    var home_buf: [300]u8 = undefined;
    zdos.setVar("USER", u.name) catch {};
    zdos.setVar("LOGNAME", u.name) catch {};
    zdos.setVar("HOME", homeOf(u.name, &home_buf)) catch {};
}

pub fn restoreVars(saved: *const SavedVars) void {
    for (user_vars, 0..) |name, i| zdos.setVar(name, saved.values[i] orelse "") catch {};
}

// PASSWORDS: Argon2id, OWASP's settings (19 MB, 2 passes), 16-byte salt

const argon2 = std.crypto.pwhash.argon2;
const params: argon2.Params = .{ .t = 2, .m = 19 * 1024, .p = 1 };
const b64 = std.base64.standard_no_pad;

// "" for none; 128 bytes of buf are enough.
pub fn hashPassword(password: []const u8, buf: []u8) []const u8 {
    if (password.len == 0) return "";
    var salt: [16]u8 = undefined;
    zdos.randomBytes(&salt);
    var key: [32]u8 = undefined;
    argon2.kdf(zdos.allocator, &key, password, &salt, params, .argon2id) catch return "";
    defer std.crypto.secureZero(u8, &key);
    var salt_text: [b64.Encoder.calcSize(16)]u8 = undefined;
    var key_text: [b64.Encoder.calcSize(32)]u8 = undefined;
    return std.fmt.bufPrint(buf, "$argon2id$v=19$m={d},t={d},p={d}${s}${s}", .{
        params.m, params.t, params.p, b64.Encoder.encode(&salt_text, &salt), b64.Encoder.encode(&key_text, &key),
    }) catch "";
}

// An empty field: any password does.
pub fn checkPassword(field: []const u8, password: []const u8) bool {
    return checkPasswordWith(zdos.allocator, field, password);
}

// Memory from alloc, so it can run on another core.
pub fn checkPasswordWith(alloc: std.mem.Allocator, field: []const u8, password: []const u8) bool {
    if (field.len == 0) return true;
    if (std.mem.startsWith(u8, field, "$argon2")) {
        argon2.strVerify(field, password, .{ .allocator = alloc }) catch return false;
        return true;
    }
    if (std.mem.startsWith(u8, field, "sha256$")) return checkOld(field, password);
    return false; // "x": not readable here
}

// Replaced with Argon2id at the next login.
pub fn isOldHash(field: []const u8) bool {
    return std.mem.startsWith(u8, field, "sha256$");
}

pub fn upgradeHash(list: *List, u: *User, password: []const u8) void {
    if (!isOldHash(u.password)) return;
    var buf: [128]u8 = undefined;
    const field = hashPassword(password, &buf);
    if (field.len == 0) return;
    u.password = list.keep(field) orelse return;
    save(list) catch {};
}

// Typed passwords don't stay in memory.
pub fn wipe(buf: []u8) void {
    std.crypto.secureZero(u8, buf);
}

// ZDOS's first hashes: SHA-256 over salt and password, then 5000 rounds.
fn checkOld(field: []const u8, password: []const u8) bool {
    var parts = std.mem.splitScalar(u8, field, '$');
    _ = parts.next();
    const salt = parts.next() orelse return false;
    const want_hex = parts.next() orelse return false;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(salt);
    h.update(password);
    var d: [32]u8 = undefined;
    h.final(&d);
    for (0..5000) |_| {
        var again = std.crypto.hash.sha2.Sha256.init(.{});
        again.update(&d);
        again.update(password);
        again.final(&d);
    }
    var want: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, want_hex) catch return false;
    return std.crypto.timing_safe.eql([32]u8, d, want);
}

// hidden: nothing shown. Null on Esc or Ctrl+C.
pub fn readLine(buf: []u8, hidden: bool) ?[]const u8 {
    var len: usize = 0;
    while (true) {
        const k = zdos.readKey();
        if (k.char == '\r' or k.char == '\n') {
            zdos.print("\n");
            return buf[0..len];
        }
        if (k.scan == zdos.Scan.esc or k.char == 3) {
            zdos.print("\n");
            return null;
        }
        if (k.char == 8 or k.char == 0x7F) {
            if (len > 0) {
                len -= 1;
                if (!hidden) zdos.print("\x08 \x08");
            }
            continue;
        }
        if (k.char < 0x20 or k.char > 0x7E or len == buf.len) continue;
        buf[len] = @intCast(k.char);
        len += 1;
        if (!hidden) zdos.print(buf[len - 1 .. len]);
    }
}

// Twice; null if they differ or on Esc.
pub fn askNewPassword(buf: []u8) ?[]const u8 {
    zdos.print("New password (Enter: none): ");
    const first = readLine(buf[0 .. buf.len / 2], true) orelse return null;
    zdos.print("Again: ");
    const second = readLine(buf[buf.len / 2 ..], true) orelse return null;
    if (!std.mem.eql(u8, first, second)) {
        zdos.print("The passwords differ\n");
        return null;
    }
    return first;
}
