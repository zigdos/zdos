// A panel: a folder's entries, sorted, and the cursor.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");

pub const max_path = 1024;

pub const Entry = struct {
    name_at: u32,
    name_len: u16,
    is_dir: bool,
    up: bool = false, // ".."
    attrs: u8,
    size: u64,
    modified: zdos.Time,
    selected: bool = false,
};

pub const SortBy = enum { name, size, time };

pub const Panel = struct {
    sort_by: SortBy = .name,
    descending: bool = false,
    path_buf: [max_path]u8 = undefined,
    path_len: usize = 0,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    names: std.ArrayListUnmanaged(u8) = .{},
    cursor: usize = 0,
    top: usize = 0,
    err: ?zdos.Error = null, // reading the folder
    loaded: u64 = 0, // the path's hash at the last load
    free: ?u64 = null, // bytes free on the drive

    pub fn path(self: *const Panel) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn name(self: *const Panel, e: Entry) []const u8 {
        return self.names.items[e.name_at..][0..e.name_len];
    }

    pub fn current(self: *Panel) ?*Entry {
        if (self.cursor >= self.entries.items.len) return null;
        return &self.entries.items[self.cursor];
    }

    pub fn setPath(self: *Panel, p: []const u8) bool {
        if (p.len > self.path_buf.len) return false;
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;
        return true;
    }

    pub fn isRoot(self: *const Panel) bool {
        const p = self.path();
        return p.len <= 3 and (p.len < 3 or p[2] == '\\' or p[2] == '/');
    }

    // The folder anew; the cursor stays on the entry named
    // keep, else on the one it was on:
    pub fn load(self: *Panel, keep: ?[]const u8) void {
        // Copied: keep may be one of the names read anew:
        var keep_buf: [768]u8 = undefined;
        var want: ?[]const u8 = null;
        const from = keep orelse if (self.current()) |e| self.name(e.*) else null;
        if (from) |n| {
            const len = @min(n.len, keep_buf.len);
            @memcpy(keep_buf[0..len], n[0..len]);
            want = keep_buf[0..len];
        }
        const old_cursor = self.cursor;
        // The same folder again keeps its selection:
        var marks: std.StringHashMapUnmanaged(void) = .{};
        var mark_names: std.ArrayListUnmanaged(u8) = .{};
        defer marks.deinit(zdos.allocator);
        defer mark_names.deinit(zdos.allocator);
        const here = std.hash.Wyhash.hash(0, self.path());
        if (here == self.loaded) self.saveMarks(&marks, &mark_names);
        self.loaded = here;
        self.entries.clearRetainingCapacity();
        self.names.clearRetainingCapacity();
        self.err = null;
        if (!self.isRoot()) self.add("..", .{ .name_at = 0, .name_len = 0, .is_dir = true, .up = true, .attrs = 0, .size = 0, .modified = zdos.Time{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 } });
        self.read() catch |err| {
            self.err = err;
        };
        const first: usize = if (self.isRoot()) 0 else 1;
        std.mem.sort(Entry, self.entries.items[first..], self, before);
        if (marks.count() > 0) {
            for (self.entries.items) |*e| {
                if (!e.up and marks.contains(self.name(e.*))) e.selected = true;
            }
        }
        self.free = if (self.path_len > 0) (if (zdos.driveInfo(std.ascii.toUpper(self.path_buf[0]))) |d| d.free else |_| null) else null;
        self.cursor = @min(old_cursor, self.entries.items.len -| 1);
        if (want) |w| {
            for (self.entries.items, 0..) |e, i| {
                if (std.mem.eql(u8, self.name(e), w)) {
                    self.cursor = i;
                    break;
                }
            }
        }
    }

    // The selected names, copied (the old ones are cleared):
    fn saveMarks(self: *Panel, marks: *std.StringHashMapUnmanaged(void), store: *std.ArrayListUnmanaged(u8)) void {
        var total: usize = 0;
        for (self.entries.items) |e| {
            if (e.selected) total += e.name_len;
        }
        if (total == 0) return;
        store.ensureTotalCapacity(zdos.allocator, total) catch return;
        for (self.entries.items) |e| {
            if (!e.selected) continue;
            const at = store.items.len;
            store.appendSliceAssumeCapacity(self.name(e));
            marks.put(zdos.allocator, store.items[at..], {}) catch return;
        }
    }

    fn read(self: *Panel) zdos.Error!void {
        const dir = try zdos.openDir(self.path());
        defer dir.close();
        var de: zdos.DirEntry = undefined;
        while (try dir.next(&de)) {
            const n = de.name();
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            self.add(n, .{ .name_at = 0, .name_len = 0, .is_dir = de.is_dir, .attrs = de.attrs, .size = de.size, .modified = de.modified });
        }
    }

    fn add(self: *Panel, n: []const u8, e: Entry) void {
        var entry = e;
        entry.name_at = @intCast(self.names.items.len);
        entry.name_len = @intCast(n.len);
        self.names.appendSlice(zdos.allocator, n) catch return;
        self.entries.append(zdos.allocator, entry) catch return;
    }

    // Folders first, then by sort_by (equal ones by name):
    fn before(self: *Panel, a: Entry, b: Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        const order: std.math.Order = switch (self.sort_by) {
            .name => .eq,
            .size => std.math.order(a.size, b.size),
            .time => timeOrder(a.modified, b.modified),
        };
        // Descending turns the key around, not the names of equals:
        if (order != .eq) return if (self.descending) order == .gt else order == .lt;
        const by_name = self.nameOrder(a, b);
        if (self.sort_by == .name and self.descending) return by_name == .gt;
        return by_name == .lt;
    }

    // Case ignored, then exact:
    fn nameOrder(self: *Panel, a: Entry, b: Entry) std.math.Order {
        const x = self.name(a);
        const y = self.name(b);
        const o = std.ascii.orderIgnoreCase(x, y);
        return if (o != .eq) o else std.mem.order(u8, x, y);
    }

    // path\child into buf:
    pub fn join(self: *const Panel, child: []const u8, buf: []u8) ?[]const u8 {
        return joinPath(self.path(), child, buf);
    }

    // To the parent folder, the cursor on the one left:
    pub fn up(self: *Panel) void {
        if (self.isRoot()) return;
        const p = self.path();
        const cut = std.mem.lastIndexOfAny(u8, p, "\\/") orelse return;
        var left_buf: [768]u8 = undefined;
        const left = p[cut + 1 ..];
        const n = @min(left.len, left_buf.len);
        @memcpy(left_buf[0..n], left[0..n]);
        self.path_len = if (cut <= 2) 3 else cut;
        self.cursor = 0;
        self.top = 0;
        self.load(left_buf[0..n]);
    }

    pub fn into(self: *Panel, child: []const u8) void {
        var buf: [max_path]u8 = undefined;
        const p = self.join(child, &buf) orelse return;
        const old_len = self.path_len;
        var old: [max_path]u8 = undefined;
        @memcpy(old[0..old_len], self.path());
        _ = self.setPath(p);
        self.cursor = 0;
        self.top = 0;
        self.load(null);
        if (self.err != null) {
            // Back where it was, the error kept:
            const err = self.err;
            _ = self.setPath(old[0..old_len]);
            self.load(child);
            self.err = err;
        }
    }

    pub fn selectedCount(self: *const Panel) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (e.selected) n += 1;
        }
        return n;
    }

    pub fn selectedBytes(self: *const Panel) u64 {
        var n: u64 = 0;
        for (self.entries.items) |e| {
            if (e.selected and !e.is_dir) n += e.size;
        }
        return n;
    }

    // Shows the cursor within height rows:
    pub fn scroll(self: *Panel, height: usize) void {
        if (height == 0) return;
        if (self.cursor < self.top) self.top = self.cursor;
        if (self.cursor >= self.top + height) self.top = self.cursor + 1 - height;
        const len = self.entries.items.len;
        if (self.top + height > len) self.top = len -| height;
    }

    pub fn move(self: *Panel, delta: isize) void {
        const len = self.entries.items.len;
        if (len == 0) return;
        const c: isize = @as(isize, @intCast(self.cursor)) + delta;
        self.cursor = @intCast(std.math.clamp(c, 0, @as(isize, @intCast(len - 1))));
    }
};

fn timeOrder(a: zdos.Time, b: zdos.Time) std.math.Order {
    const x = [_]u16{ a.year, a.month, a.day, a.hour, a.minute, a.second };
    const y = [_]u16{ b.year, b.month, b.day, b.hour, b.minute, b.second };
    return std.mem.order(u16, &x, &y);
}

pub fn joinPath(dir: []const u8, child: []const u8, buf: []u8) ?[]const u8 {
    const sep = if (dir.len > 0 and (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/')) "" else "\\";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, child }) catch null;
}
