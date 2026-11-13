// Copying and moving trees: into existing folders (merged),
// with progress; Esc stops.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const dialog = @import("dialog.zig");
const panel = @import("panel.zig");

const max_path = panel.max_path;
const chunk = 64 * 1024;

pub const Job = struct {
    moving: bool,
    title: []const u8,
    files_total: u64 = 0,
    bytes_total: u64 = 0,
    files_done: u64 = 0,
    bytes_done: u64 = 0,
    overwrite_all: bool = false,
    stopped: bool = false,
    buf: []u8 = &.{},
    shown_at: u64 = 0,

    pub fn init(self: *Job) void {
        self.buf = zdos.allocator.alloc(u8, chunk) catch &static_buf;
    }

    pub fn deinit(self: *Job) void {
        if (@intFromPtr(self.buf.ptr) != @intFromPtr(&static_buf)) zdos.allocator.free(self.buf);
    }

    // What path holds, into the totals:
    pub fn count(self: *Job, path: []const u8, is_dir: bool, size: u64) void {
        if (!is_dir) {
            self.files_total += 1;
            self.bytes_total += size;
            return;
        }
        var list = Listing.read(path) orelse return;
        defer list.deinit();
        for (list.items.items) |it| {
            var buf: [max_path]u8 = undefined;
            const child = panel.joinPath(path, list.name(it), &buf) orelse continue;
            self.count(child, it.is_dir, it.size);
        }
    }

    // from to to (a file or a folder, merged into one there);
    // true if all of it was copied:
    pub fn copy(self: *Job, from: []const u8, to: []const u8, is_dir: bool) bool {
        if (self.stopped) return false;
        if (is_dir) return self.copyDir(from, to);
        if (zdos.stat(to)) |existing| {
            if (existing.is_dir) return self.fail(to, "is a folder");
            if (!self.mayOverwrite(to)) return false;
        } else |_| {}
        return self.copyFile(from, to);
    }

    fn copyDir(self: *Job, from: []const u8, to: []const u8) bool {
        if (zdos.stat(to)) |existing| {
            if (!existing.is_dir) return self.fail(to, "is a file");
        } else |_| {
            zdos.makeDir(to) catch |err| return self.fail(to, zdos.message(err));
            zdos.copyMode(from, to);
        }
        var list = Listing.read(from) orelse return self.fail(from, "can't be read");
        defer list.deinit();
        var all = true;
        for (list.items.items) |it| {
            if (self.stopped) return false;
            var f_buf: [max_path]u8 = undefined;
            var t_buf: [max_path]u8 = undefined;
            const name = list.name(it);
            const f = panel.joinPath(from, name, &f_buf) orelse continue;
            const t = panel.joinPath(to, name, &t_buf) orelse continue;
            if (!self.copy(f, t, it.is_dir)) all = false;
        }
        return all;
    }

    // An existing file is overwritten in place, as COPY does
    // (emptied first, so its space is free for the new one);
    // an incomplete one is deleted:
    fn copyFile(self: *Job, from: []const u8, to: []const u8) bool {
        const info = zdos.stat(from) catch |err| return self.fail(from, zdos.message(err));
        const src = zdos.open(from, .read) catch |err| return self.fail(from, zdos.message(err));
        defer src.close();
        const dst = zdos.open(to, .write) catch |err| return self.fail(to, zdos.message(err));
        var done: u64 = 0;
        self.show(from, 0, info.size);
        const ok = blk: {
            while (true) {
                const n = src.read(self.buf) catch |err| break :blk self.fail(from, zdos.message(err));
                if (n == 0) break :blk true;
                dst.writeAll(self.buf[0..n]) catch |err| break :blk self.fail(to, zdos.message(err));
                done += n;
                self.bytes_done += n;
                self.show(from, done, info.size);
                if (self.stopped) break :blk false;
            }
        };
        const closed = if (dst.closeChecked()) true else |err| self.fail(to, zdos.message(err));
        if (!ok or !closed) {
            zdos.delete(to) catch {};
            return false;
        }
        zdos.setFileTime(to, info.modified) catch {};
        zdos.copyMode(from, to);
        if (info.attrs & zdos.Attr.all != 0) zdos.setAttributes(to, info.attrs & zdos.Attr.all) catch {};
        self.files_done += 1;
        return true;
    }

    // On one drive a rename (merged into an existing folder),
    // else copied and then deleted; true if all of it moved:
    pub fn move(self: *Job, from: []const u8, to: []const u8, is_dir: bool) bool {
        if (self.stopped) return false;
        if (!sameDrive(from, to)) {
            if (!self.copy(from, to, is_dir)) return false;
            const gone = if (is_dir) zdos.deleteTree(from) else zdos.delete(from);
            gone catch |err| return self.fail(from, zdos.message(err));
            return true;
        }
        // A rename that only changes case finds itself:
        const existing = if (std.ascii.eqlIgnoreCase(from, to)) null else (zdos.stat(to) catch null);
        if (existing) |e| {
            if (is_dir and e.is_dir) return self.moveInto(from, to);
            if (is_dir or e.is_dir) return self.fail(to, if (e.is_dir) "is a folder" else "is a file");
            if (!self.mayOverwrite(to)) return false;
            zdos.delete(to) catch |err| return self.fail(to, zdos.message(err));
        }
        var size: u64 = 0;
        var files: u64 = 0;
        if (is_dir) {
            var sub: Job = .{ .moving = true, .title = self.title };
            sub.count(from, true, 0);
            files = sub.files_total;
            size = sub.bytes_total;
        } else {
            files = 1;
            size = if (zdos.stat(from)) |s| s.size else |_| 0;
        }
        self.show(from, 0, size);
        zdos.move(from, to) catch |err| return self.fail(from, zdos.message(err));
        self.files_done += files;
        self.bytes_done += size;
        return true;
    }

    // Each entry into the existing folder; from goes when
    // it is empty:
    fn moveInto(self: *Job, from: []const u8, to: []const u8) bool {
        var list = Listing.read(from) orelse return self.fail(from, "can't be read");
        defer list.deinit();
        var all = true;
        for (list.items.items) |it| {
            if (self.stopped) return false;
            var f_buf: [max_path]u8 = undefined;
            var t_buf: [max_path]u8 = undefined;
            const name = list.name(it);
            const f = panel.joinPath(from, name, &f_buf) orelse continue;
            const t = panel.joinPath(to, name, &t_buf) orelse continue;
            if (!self.move(f, t, it.is_dir)) all = false;
        }
        if (all) zdos.deleteTree(from) catch |err| return self.fail(from, zdos.message(err));
        return all;
    }

    fn mayOverwrite(self: *Job, to: []const u8) bool {
        if (self.overwrite_all) return true;
        switch (dialog.ask("Overwrite", &.{ to, "already exists. Overwrite it?" })) {
            .yes => return true,
            .all => {
                self.overwrite_all = true;
                return true;
            },
            .skip => return false,
            .cancel => {
                self.stopped = true;
                return false;
            },
        }
    }

    // False; Esc in the message stops the job:
    fn fail(self: *Job, what: []const u8, why: []const u8) bool {
        if (!dialog.message("Error", &.{ what, why }, true)) self.stopped = true;
        return false;
    }

    // The box anew at most 10 times a second; Esc asks
    // whether to stop:
    fn show(self: *Job, name: []const u8, done: u64, size: u64) void {
        while (zdos.pollKey()) |k| {
            if (k.scan == zdos.Scan.esc or k.char == 27) {
                const verb = if (self.moving) "Stop moving?" else "Stop copying?";
                if (dialog.confirm(self.title, &.{verb}, true)) {
                    self.stopped = true;
                    return;
                }
                self.shown_at = 0;
            }
        }
        const now = zdos.millis();
        if (self.shown_at != 0 and now -% self.shown_at < 100 and done < size) return;
        self.shown_at = now;
        var info_buf: [80]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d} of {d} files", .{ @min(self.files_done + 1, self.files_total), self.files_total }) catch "";
        dialog.progress(self.title, name, .{ done, size }, .{ self.bytes_done, self.bytes_total }, info);
    }
};

var static_buf: [4096]u8 = undefined;

fn sameDrive(a: []const u8, b: []const u8) bool {
    return a.len > 0 and b.len > 0 and std.ascii.toUpper(a[0]) == std.ascii.toUpper(b[0]);
}

// A folder's entries read at once, so changing the folder
// doesn't disturb reading it.
const Listing = struct {
    const Item = struct { at: u32, len: u16, is_dir: bool, size: u64 };
    items: std.ArrayListUnmanaged(Item) = .{},
    names: std.ArrayListUnmanaged(u8) = .{},

    fn read(path: []const u8) ?Listing {
        const dir = zdos.openDir(path) catch return null;
        defer dir.close();
        var l: Listing = .{};
        const de = zdos.allocator.create(zdos.DirEntry) catch return null;
        defer zdos.allocator.destroy(de);
        while (dir.next(de) catch false) {
            const n = de.name();
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            const at: u32 = @intCast(l.names.items.len);
            l.names.appendSlice(zdos.allocator, n) catch break;
            l.items.append(zdos.allocator, .{ .at = at, .len = @intCast(n.len), .is_dir = de.is_dir, .size = de.size }) catch break;
        }
        return l;
    }

    fn name(self: *const Listing, it: Item) []const u8 {
        return self.names.items[it.at..][0..it.len];
    }

    fn deinit(self: *Listing) void {
        self.items.deinit(zdos.allocator);
        self.names.deinit(zdos.allocator);
    }
};

// to inside from (copying a folder into itself):
pub fn inside(from: []const u8, to: []const u8) bool {
    if (to.len <= from.len or !std.ascii.eqlIgnoreCase(to[0..from.len], from)) return false;
    return to[from.len] == '\\' or to[from.len] == '/';
}
