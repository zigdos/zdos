// Paths and file operations for COMMAND.APP and ATTRIB.APP. Paths are
// full, as ZDOS resolves them: "C:\DOCS\Report.txt", on-disk spelling.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const term = @import("term.zig");

pub const max_path = 1024; // as ZDOS's own limit
pub const Error = zdos.Error;
pub const Attr = zdos.Attr;
pub const DirEntry = zdos.DirEntry;
pub const message = zdos.message;

// Drive letter, ':', then the absolute path on the drive.
pub const Path = struct {
    buf: [max_path + 2]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn drive(self: *const Path) u8 {
        return self.buf[0];
    }

    // "\DOCS" of "C:\DOCS"
    pub fn onDrive(self: *const Path) []const u8 {
        return self.buf[2..self.len];
    }

    pub fn isRoot(self: *const Path) bool {
        return self.len <= 3;
    }

    pub fn set(self: *Path, s: []const u8) bool {
        if (s.len > self.buf.len) return false;
        @memcpy(self.buf[0..s.len], s);
        self.len = s.len;
        return true;
    }

    pub fn append(self: *Path, part: []const u8) bool {
        const sep: usize = if (self.buf[self.len - 1] == '\\') 0 else 1;
        if (self.len + sep + part.len > self.buf.len) return false;
        if (sep == 1) {
            self.buf[self.len] = '\\';
            self.len += 1;
        }
        @memcpy(self.buf[self.len..][0..part.len], part);
        self.len += part.len;
        return true;
    }

    // The root stays the root.
    pub fn pop(self: *Path) void {
        var i = self.len;
        while (i > 0 and self.buf[i - 1] != '\\') i -= 1;
        self.len = if (i <= 3) 3 else i - 1;
    }

    // "\A\B" -> "B"; "" for the root.
    pub fn name(self: *const Path) []const u8 {
        const s = self.slice();
        var i = s.len;
        while (i > 0 and s[i - 1] != '\\') i -= 1;
        return s[i..];
    }

    pub fn print(self: *const Path) void {
        term.print(self.slice());
    }
};

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

// "/C:/DOCS" (or "\C:\DOCS") -> "C:/DOCS", as POSIX programs name other drives.
pub fn dropRootSlash(path: []const u8) []const u8 {
    if (path.len >= 3 and isSep(path[0]) and std.ascii.isAlphabetic(path[1]) and path[2] == ':') return path[1..];
    return path;
}

// Quotes removed wherever they are, as in DOS, and "/C:/X" made "C:/X".
// The result may live in buf.
pub const TypedBuf = [max_path + 8]u8;
pub fn typedPath(arg: []const u8, buf: *TypedBuf) []const u8 {
    if (std.mem.indexOfScalar(u8, arg, '"') == null) return dropRootSlash(arg);
    var n: usize = 0;
    for (arg) |c| {
        if (c == '"') continue;
        if (n == buf.len) break; // too long anyway: resolving reports it
        buf[n] = c;
        n += 1;
    }
    return dropRootSlash(buf[0..n]);
}

pub fn driveExists(letter: u8) bool {
    var buf: [26]u8 = undefined;
    const up = std.ascii.toUpper(letter);
    return std.mem.indexOfScalar(u8, zdos.getDrives(&buf), up) != null;
}

// "D:...", or null for the current drive.
pub fn driveOf(typed: []const u8) ?u8 {
    return if (typed.len >= 2 and typed[1] == ':') std.ascii.toUpper(typed[0]) else null;
}

// Quotes allowed. The folders leading to it must exist; the last part needn't.
// "" is the current folder.
pub fn resolve(arg: []const u8) Error!Path {
    var buf: TypedBuf = undefined;
    const p = typedPath(arg, &buf);
    var out: Path = .{};
    out.len = (try zdos.fullPath(p, &out.buf)).len;
    return out;
}

// PathNotFound if missing, NotADirectory if a file.
pub fn resolveDir(arg: []const u8) Error!Path {
    const p = try resolve(arg);
    const kind = try kindOf(&p) orelse return error.PathNotFound;
    if (kind != .dir) return error.NotADirectory;
    return p;
}

pub const Kind = enum { file, dir };

// Null if nothing. A disk error is not "nothing": callers would go on
// and create what may well exist.
pub fn kindOf(path: *const Path) Error!?Kind {
    const e = zdos.stat(path.slice()) catch |err| return switch (err) {
        error.NotFound => null,
        else => err,
    };
    return if (e.is_dir) .dir else .file;
}

pub fn entryInfo(path: *const Path) Error!DirEntry {
    return zdos.stat(path.slice());
}

// Or the same; both from fullPath, so the case is compared exactly (on
// ext2 and Minix, Report and report are two names).
pub fn isInside(path: []const u8, dir: []const u8) bool {
    if (path.len < dir.len) return false;
    if (!std.mem.eql(u8, path[0..dir.len], dir)) return false;
    return path.len == dir.len or dir[dir.len - 1] == '\\' or path[dir.len] == '\\';
}

// "DOCS\Report.txt\" -> "Report.txt"
pub fn lastComponent(arg: []const u8) []const u8 {
    var n = arg;
    while (n.len > 1 and isSep(n[n.len - 1])) n = n[0 .. n.len - 1];
    var i = n.len;
    while (i > 0 and !isSep(n[i - 1])) i -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (i == 0 and n.len >= 2 and n[1] == ':' and std.ascii.isAlphabetic(n[0])) i = 2;
    return n[i..];
}

// Doubling, on the ZDOS heap.
pub fn Grow(comptime T: type) type {
    return struct {
        items: []T = &.{},
        len: usize = 0,

        const Self = @This();

        pub fn append(self: *Self, values: []const T) bool {
            if (self.len + values.len > self.items.len) {
                const cap = @max(16 * 1024 / @sizeOf(T), (self.len + values.len) * 2);
                const mem = zdos.alloc(cap * @sizeOf(T)) orelse return false;
                const new: [*]T = @ptrCast(@alignCast(mem));
                @memcpy(new[0..self.len], self.items[0..self.len]);
                self.deinit();
                self.items = new[0..cap];
            }
            @memcpy(self.items[self.len..][0..values.len], values);
            self.len += values.len;
            return true;
        }

        pub fn slice(self: *const Self) []T {
            return self.items[0..self.len];
        }

        pub fn deinit(self: *Self) void {
            if (self.items.len > 0) zdos.free(@ptrCast(@alignCast(self.items.ptr)));
            self.items = &.{};
        }
    };
}

// TREE WALKS: no recursion, one heap Stack entry per level holding its
// folder's names (collected first, so the folder may change)

pub fn Stack(comptime T: type) type {
    return struct {
        items: []T = &.{},
        len: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, value: T) Error!void {
            if (self.len == self.items.len) {
                const cap = @max(16, self.items.len * 2);
                const mem = zdos.alloc(cap * @sizeOf(T)) orelse return error.OutOfMemory;
                const new: [*]T = @ptrCast(@alignCast(mem));
                @memcpy(new[0..self.len], self.items[0..self.len]);
                if (self.items.len > 0) zdos.free(@ptrCast(@alignCast(self.items.ptr)));
                self.items = new[0..cap];
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn top(self: *Self) ?*T {
            return if (self.len == 0) null else &self.items[self.len - 1];
        }

        pub fn pop(self: *Self) void {
            self.len -= 1;
        }

        pub fn deinit(self: *Self) void {
            if (self.items.len > 0) zdos.free(@ptrCast(@alignCast(self.items.ptr)));
            self.* = .{};
        }
    };
}

pub const NameIterator = std.mem.TokenIterator(u8, .scalar);

// "." and ".." excluded; collected first, so the directory
// can then be changed safely.
pub const NameList = struct {
    buf: ?[*]align(16) u8 = null,
    cap: usize = 0,
    len: usize = 0,
    count: usize = 0,
    dirs: usize = 0,

    pub fn add(self: *NameList, entry_name: []const u8) bool {
        if (self.len + entry_name.len + 1 > self.cap) {
            const new_cap = @max(4096, (self.len + entry_name.len + 1) * 2);
            const new = zdos.alloc(new_cap) orelse return false;
            if (self.buf) |old| {
                @memcpy(new[0..self.len], old[0..self.len]);
                zdos.free(old);
            }
            self.buf = new;
            self.cap = new_cap;
        }
        @memcpy(self.buf.?[self.len..][0..entry_name.len], entry_name);
        self.buf.?[self.len + entry_name.len] = 0;
        self.len += entry_name.len + 1;
        self.count += 1;
        return true;
    }

    pub fn iterator(self: *const NameList) NameIterator {
        const data: []const u8 = if (self.buf) |b| b[0..self.len] else "";
        return std.mem.tokenizeScalar(u8, data, 0);
    }

    pub fn deinit(self: *NameList) void {
        if (self.buf) |b| zdos.free(b);
        self.* = .{};
    }
};

// By the hidden attribute: -a and -a:h of DIR and the delete commands.
pub const Select = enum {
    visible, // the default: everything except hidden entries
    all, // -a
    hidden, // -a:h: only hidden entries

    pub fn takes(self: Select, attrs: u8) bool {
        const hidden = attrs & Attr.hidden != 0;
        return switch (self) {
            .visible => !hidden,
            .all => true,
            .hidden => hidden,
        };
    }
};

pub const DirIterator = struct {
    dir: zdos.Dir,
    entry: DirEntry = undefined,

    // Null at the end; valid until the next call.
    pub fn next(self: *DirIterator) Error!?*const DirEntry {
        if (!try self.dir.next(&self.entry)) return null;
        return &self.entry;
    }

    pub fn close(self: *DirIterator) void {
        self.dir.close();
    }
};

pub fn openDir(path: *const Path) Error!DirIterator {
    return .{ .dir = try zdos.openDir(path.slice()) };
}

// sel .all for everything.
pub fn listMatches(dir: *const Path, pattern: []const u8, sel: Select) Error!NameList {
    var list: NameList = .{};
    errdefer list.deinit();
    var it = try openDir(dir);
    defer it.close();
    while (try it.next()) |e| {
        const n = e.name();
        if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
        if (!matches(pattern, n)) continue;
        if (!sel.takes(e.attrs)) continue;
        if (!list.add(n)) return error.OutOfMemory;
        if (e.is_dir) list.dirs += 1;
    }
    return list;
}

// WILDCARDS

pub fn hasWildcard(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

// * and ?, ignoring case like FAT.
pub fn matches(pattern: []const u8, entry_name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null; // position after the last *
    var star_n: usize = 0; // where that * started matching
    while (n < entry_name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            p += 1;
            star_p = p;
            star_n = n;
        } else if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(entry_name[n]))) {
            p += 1;
            n += 1;
        } else if (star_p) |sp| {
            // Let the last * take one more character and try again:
            p = sp;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub const DeleteResult = struct {
    deleted: usize = 0,
    failed: bool = false, // something could not be deleted
    err: ?Error = null, // why the first failure happened

    pub fn fail(self: *DeleteResult, err: Error) void {
        self.failed = true;
        if (self.err == null) self.err = err;
    }
};

// Hidden entries included. Goes on after a failure; r counts and keeps
// the first error. Ctrl+C stops it.
pub fn deleteAll(path: *const Path, r: *DeleteResult) void {
    const Frame = struct {
        list: NameList,
        it: NameIterator,
        len: usize, // of cur for this folder
    };
    var stack: Stack(Frame) = .{};
    defer {
        while (stack.top()) |f| {
            f.list.deinit();
            stack.pop();
        }
        stack.deinit();
    }
    var cur: Path = path.*;
    var pending = true; // cur is an entry still to handle
    while (true) {
        if (term.breakRequested()) return;
        if (pending) {
            pending = false;
            if (kindOf(&cur)) |kind| {
                if (kind == .dir) {
                    // The names first: the listing
                    // changes while entries are deleted:
                    if (listMatches(&cur, "*", .all)) |list| {
                        stack.push(.{ .list = list, .it = list.iterator(), .len = cur.len }) catch |err| {
                            var l = list;
                            l.deinit();
                            r.fail(err);
                        };
                    } else |err| r.fail(err);
                } else if (kind == .file) {
                    deleteEntry(&cur, false, r);
                } else r.fail(error.NotFound);
            } else |err| r.fail(err);
        }
        const f = stack.top() orelse return;
        if (f.it.next()) |n| {
            cur.len = f.len;
            if (cur.append(n)) {
                pending = true;
            } else r.fail(error.InvalidName);
            continue;
        }
        // The folder's entries are done: now the folder itself:
        cur.len = f.len;
        f.list.deinit();
        stack.pop();
        deleteEntry(&cur, true, r);
    }
}

fn deleteEntry(path: *const Path, is_dir: bool, r: *DeleteResult) void {
    // Empty by now unless something failed: as a tree just the folder goes:
    const done = if (is_dir) zdos.deleteTree(path.slice()) else zdos.delete(path.slice());
    if (done) {
        r.deleted += 1;
    } else |err| r.fail(err);
}

// The copy keeps the original's modification time, as DOS's COPY.
pub fn copyFile(src: *const Path, dst: *const Path) Error!void {
    const info = try zdos.stat(src.slice());

    const buf_size = 64 * 1024;
    const buf = zdos.alloc(buf_size) orelse return error.OutOfMemory;
    defer zdos.free(buf);

    const in = try zdos.open(src.slice(), .read);
    defer in.close();
    const out = try zdos.open(dst.slice(), .write);
    copyData(in, out, buf[0..buf_size]) catch |err| {
        out.close();
        return err;
    };
    try out.closeChecked(); // the size and date are written now: may fail too
    // After closing, which stamps the current time; a failure is ignored:
    if (info.modified.year != 0) zdos.setFileTime(dst.slice(), info.modified) catch {};
    zdos.copyMode(src.slice(), dst.slice());
}

fn copyData(in: zdos.File, out: zdos.File, buf: []u8) Error!void {
    while (true) {
        const n = try in.read(buf);
        if (n == 0) return;
        try out.writeAll(buf[0..n]);
    }
}

// Null if it can't be read (no disk).
pub fn volumeInfo(letter: u8) ?zdos.DriveInfo {
    const info = zdos.driveInfo(letter) catch return null;
    return if (info.ready) info else null;
}

pub const fileSystemName = zdos.fileSystemName;

pub const LabelError = error{ InvalidCharacters, TooLong };

// DOS's rules: at most 11 characters, none of * ? . , ; : / \ | + = < >
// [ ] ". ZDOS stores it in capitals.
pub fn checkLabel(label: []const u8) LabelError!void {
    const view = std.unicode.Utf8View.init(label) catch return error.InvalidCharacters;
    var count: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        count += 1;
        if (c < 0x20 or (c < 0x80 and std.mem.indexOfScalar(u8, "*?.,;:/\\|+=<>[]\"", @intCast(c)) != null)) return error.InvalidCharacters;
    }
    if (count > 11) return error.TooLong;
}
