const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    bytes: u64 = 0,
    in_word: bool = false,

    fn consume(self: *Counts, bytes: []const u8) void {
        for (bytes) |byte| {
            self.bytes +%= 1;
            if (byte == '\n') self.lines +%= 1;
            if (std.ascii.isWhitespace(byte)) {
                self.in_word = false;
            } else if (!self.in_word) {
                self.words +%= 1;
                self.in_word = true;
            }
        }
    }
};

const Options = struct {
    lines: bool = false,
    words: bool = false,
    bytes: bool = false,
};

pub fn run(args: []const []const u8) u8 {
    var options: Options = .{};
    var explicit_options = false;
    var files: [32][]const u8 = undefined;
    var file_count: usize = 0;
    var parsing_options = true;
    for (args) |arg| {
        if (parsing_options and std.mem.eql(u8, arg, "--")) {
            parsing_options = false;
            continue;
        }
        if (parsing_options and arg.len > 1 and arg[0] == '-') {
            explicit_options = true;
            for (arg[1..]) |option| switch (option) {
                'l' => options.lines = true,
                'w' => options.words = true,
                'c' => options.bytes = true,
                else => {
                    errout.printf("wc: unsupported option: -{c}\n", .{option});
                    return 2;
                },
            };
            continue;
        }
        if (file_count == files.len) {
            errout.print("wc: too many input files\n");
            return 2;
        }
        files[file_count] = arg;
        file_count += 1;
    }
    if (!explicit_options) options = .{ .lines = true, .words = true, .bytes = true };
    if (file_count == 0 and !zdos.inputRedirected()) {
        errout.print("wc: standard input is not redirected\n");
        return 2;
    }

    var total: Counts = .{};
    var result: u8 = 0;
    if (file_count == 0) {
        var counts: Counts = .{};
        if (!readInput(&counts)) return 1;
        printCounts(counts, options, null);
        return 0;
    }
    for (files[0..file_count]) |path| {
        var counts: Counts = .{};
        if (std.mem.eql(u8, path, "-") and !zdos.inputRedirected()) {
            errout.print("wc: standard input is not redirected\n");
            result = 1;
            continue;
        }
        const ok = if (std.mem.eql(u8, path, "-"))
            readInput(&counts)
        else
            readFile(path, &counts);
        if (!ok) {
            result = 1;
            continue;
        }
        printCounts(counts, options, path);
        total.lines +%= counts.lines;
        total.words +%= counts.words;
        total.bytes +%= counts.bytes;
    }
    if (file_count > 1) printCounts(total, options, "total");
    return result;
}

fn readInput(counts: *Counts) bool {
    var buffer: [1024]u8 = undefined;
    while (true) {
        const length = zdos.readInput(&buffer);
        if (length == 0) return true;
        counts.consume(buffer[0..length]);
    }
}

fn readFile(path: []const u8, counts: *Counts) bool {
    const file = zdos.open(path, .read) catch |err| {
        printError(path, err);
        return false;
    };
    var buffer: [1024]u8 = undefined;
    while (true) {
        const length = file.read(&buffer) catch |err| {
            printError(path, err);
            file.close();
            return false;
        };
        if (length == 0) break;
        counts.consume(buffer[0..length]);
    }
    file.closeChecked() catch |err| {
        printError(path, err);
        return false;
    };
    return true;
}

fn printCounts(counts: Counts, options: Options, path: ?[]const u8) void {
    if (options.lines) zdos.printf("{d:>8}", .{counts.lines});
    if (options.words) zdos.printf("{d:>8}", .{counts.words});
    if (options.bytes) zdos.printf("{d:>8}", .{counts.bytes});
    if (path) |name| zdos.printf(" {s}", .{name});
    zdos.print("\n");
}

fn printError(path: []const u8, err: zdos.Error) void {
    errout.printf("wc: {s}: {s}\n", .{ path, zdos.message(err) });
}
