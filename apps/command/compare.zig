// FC and COMP: compare two files, by lines or by bytes
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const vars = @import("vars.zig");
const text = @import("textcmds.zig");

// After the switches (letters: the known ones).
fn twoNames(args: []const u8, cmd: []const u8, letters: []const u8, flags: []bool, names: *[2][fs.max_path + 8]u8, lens: *[2]usize) bool {
    var w: text.Words = .{ .rest = args };
    var n: usize = 0;
    while (w.next()) |word| {
        if (word.len > 1 and word[0] == '-' and letters.len > 0) {
            if (!text.takeSwitches(word, letters, flags, cmd)) return false;
            continue;
        }
        if (n == 2) break;
        @memcpy(names[n][0..word.len], word);
        lens[n] = word.len;
        n += 1;
    }
    if (n < 2 or w.next() != null) {
        con.printf("{s}{s} file1 file2\n", .{ cmd, if (letters.len > 0) " [-i]" else "" });
        vars.errorlevel = 2;
        return false;
    }
    return true;
}

fn open(name: []const u8) ?zdos.File {
    var buf: fs.TypedBuf = undefined;
    return zdos.open(fs.typedPath(name, &buf), .read) catch |err| {
        con.printf("{s} - {s}\n", .{ fs.message(err), name });
        vars.errorlevel = 2;
        return null;
    };
}

// As lines.
const TextFile = struct {
    data: fs.Grow(u8) = .{},
    ends: fs.Grow(usize) = .{}, // where each line ends in data

    fn load(self: *TextFile, f: zdos.File) bool {
        var lines: text.Lines = .{ .file = f };
        while (lines.next()) |l| {
            if (!self.data.append(l) or !self.ends.append(&.{self.data.len})) {
                con.print("FC: not enough memory\n");
                return false;
            }
        }
        return !lines.failed;
    }

    fn count(self: *const TextFile) usize {
        return self.ends.len;
    }

    fn line(self: *const TextFile, i: usize) []const u8 {
        const ends = self.ends.slice();
        const start = if (i == 0) 0 else ends[i - 1];
        return self.data.slice()[start..ends[i]];
    }

    fn deinit(self: *TextFile) void {
        self.data.deinit();
        self.ends.deinit();
    }
};

const window = 100; // lines ahead to look for a match

const Fc = struct {
    a: *const TextFile,
    b: *const TextFile,
    names: [2][]const u8,
    ignore_case: bool,

    fn same(self: *const Fc, i: usize, j: usize) bool {
        const x = self.a.line(i);
        const y = self.b.line(j);
        return if (self.ignore_case) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
    }

    // Two lines alike at i and j (or one, or both at their end)?
    fn resync(self: *const Fc, i: usize, j: usize) bool {
        const na = self.a.count();
        const nb = self.b.count();
        if (i == na or j == nb) return i == na and j == nb;
        if (!self.same(i, j)) return false;
        if (i + 1 == na or j + 1 == nb) return i + 1 == na and j + 1 == nb;
        return self.same(i + 1, j + 1);
    }

    // The line before, the lines that differ, and the line
    // where they match again.
    fn show(name: []const u8, f: *const TextFile, from: usize, to: usize) void {
        con.printf("***** {s}\n", .{name});
        const first = if (from > 0) from - 1 else 0;
        const last = @min(to + 1, f.count());
        for (first..last) |i| {
            con.print(f.line(i));
            con.print("\n");
        }
    }

    fn run(self: *const Fc) bool {
        const na = self.a.count();
        const nb = self.b.count();
        var i: usize = 0;
        var j: usize = 0;
        var differ = false;
        while (i < na or j < nb) {
            if (con.breakRequested()) return true;
            if (i < na and j < nb and self.same(i, j)) {
                i += 1;
                j += 1;
                continue;
            }
            // The nearest match: fewest lines skipped:
            var skip_a = na - i;
            var skip_b = nb - j;
            search: for (1..2 * window + 1) |d| {
                for (0..d + 1) |da| {
                    const db = d - da;
                    if (da > window or db > window or i + da > na or j + db > nb) continue;
                    if (self.resync(i + da, j + db)) {
                        skip_a = da;
                        skip_b = db;
                        break :search;
                    }
                }
            }
            differ = true;
            show(self.names[0], self.a, i, i + skip_a);
            show(self.names[1], self.b, j, j + skip_b);
            con.print("*****\n\n");
            i += skip_a;
            j += skip_b;
        }
        return differ;
    }
};

// FC [-i] file1 file2
pub fn fc(args: []const u8) void {
    var flags = [_]bool{false};
    var names: [2][fs.max_path + 8]u8 = undefined;
    var lens: [2]usize = undefined;
    if (!twoNames(args, "FC", "i", &flags, &names, &lens)) return;
    const name_a = names[0][0..lens[0]];
    const name_b = names[1][0..lens[1]];
    var a: TextFile = .{};
    defer a.deinit();
    var b: TextFile = .{};
    defer b.deinit();
    vars.errorlevel = 2;
    {
        const f = open(name_a) orelse return;
        defer f.close();
        if (!a.load(f)) return;
    }
    {
        const f = open(name_b) orelse return;
        defer f.close();
        if (!b.load(f)) return;
    }
    con.printf("Comparing files {s} and {s}\n", .{ name_a, name_b });
    const run: Fc = .{ .a = &a, .b = &b, .names = .{ name_a, name_b }, .ignore_case = flags[0] };
    const differ = run.run();
    if (!differ) con.print("FC: no differences encountered\n\n");
    vars.errorlevel = if (differ) 1 else 0;
}

// COMP file1 file2: files of different sizes aren't compared, as DOS.
pub fn comp(args: []const u8) void {
    var names: [2][fs.max_path + 8]u8 = undefined;
    var lens: [2]usize = undefined;
    if (!twoNames(args, "COMP", "", &.{}, &names, &lens)) return;
    const name_a = names[0][0..lens[0]];
    const name_b = names[1][0..lens[1]];
    const a = open(name_a) orelse return;
    defer a.close();
    const b = open(name_b) orelse return;
    defer b.close();
    con.printf("Comparing {s} and {s}...\n", .{ name_a, name_b });
    vars.errorlevel = 2;
    const size_a = a.size() catch |err| return con.printf("{s}\n", .{fs.message(err)});
    const size_b = b.size() catch |err| return con.printf("{s}\n", .{fs.message(err)});
    if (size_a != size_b) {
        con.print("Files are different sizes\n");
        vars.errorlevel = 1;
        return;
    }
    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    var offset: u64 = 0;
    var errors: usize = 0;
    while (offset < size_a) {
        if (con.breakRequested()) return;
        const want: usize = @intCast(@min(buf_a.len, size_a - offset));
        const got_a = readFull(a, buf_a[0..want]) catch |err| return con.printf("Read error: {s}\n", .{fs.message(err)});
        const got_b = readFull(b, buf_b[0..want]) catch |err| return con.printf("Read error: {s}\n", .{fs.message(err)});
        if (got_a != want or got_b != want) return con.print("Read error: the file ended early\n");
        for (buf_a[0..want], buf_b[0..want], 0..) |x, y, k| {
            if (x == y) continue;
            con.printf("Compare error at OFFSET {X}\nfile1 = {X:0>2}\nfile2 = {X:0>2}\n", .{ offset + k, x, y });
            errors += 1;
            if (errors == 10) {
                con.print("10 mismatches - ending compare\n");
                vars.errorlevel = 1;
                return;
            }
        }
        offset += want;
    }
    if (errors == 0) con.print("Files compare OK\n");
    vars.errorlevel = if (errors == 0) 0 else 1;
}

fn readFull(f: zdos.File, buf: []u8) zdos.Error!usize {
    var n: usize = 0;
    while (n < buf.len) {
        const got = try f.read(buf[n..]);
        if (got == 0) break;
        n += got;
    }
    return n;
}
