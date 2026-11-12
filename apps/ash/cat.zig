// cat [-n] [FILE...]: byte for byte, DOS line ends stay
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

pub fn run(args: []const []const u8) u8 {
    var number = false;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(zdos.allocator);
    var options = true;
    for (args) |arg| {
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
        } else if (options and std.mem.eql(u8, arg, "-n")) {
            number = true;
        } else if (options and arg.len > 1 and arg[0] == '-') {
            errout.printf("cat: unknown option: {s}\n", .{arg});
            return 2;
        } else files.append(zdos.allocator, arg) catch return outOfMemory();
    }
    if (files.items.len == 0) files.append(zdos.allocator, "-") catch return outOfMemory();
    var out: text.Output = .{};
    defer out.deinit();
    // With -n the count goes on, and a last line without a line end goes
    // on in the next file, as GNU cat:
    var n: usize = 0;
    var line_start = true;
    var status: u8 = 0;
    // Without -n 64 KiB per read and write, for fewer disk requests; else
    // or without the memory 4 KiB:
    const big = if (number) null else zdos.alloc(big_size);
    defer zdos.free(big);
    for (files.items) |path| {
        if (big != null and !std.mem.eql(u8, path, "-")) {
            out.flush();
            if (!copyFile(path, big.?[0..big_size])) status = 1;
            continue;
        }
        var reader = text.Reader.open(path) catch |err| {
            errout.printf("cat: {s}: {s}\n", .{ path, zdos.message(err) });
            status = 1;
            continue;
        };
        defer reader.close();
        while (true) {
            const chunk = reader.readChunk() catch |err| {
                errout.printf("cat: {s}: {s}\n", .{ path, zdos.message(err) });
                status = 1;
                break;
            };
            if (chunk.len == 0) break;
            if (!number) {
                out.write(chunk);
                continue;
            }
            var rest = chunk;
            while (rest.len > 0) {
                if (line_start) {
                    n += 1;
                    var buf: [24]u8 = undefined;
                    out.write(std.fmt.bufPrint(&buf, "{d:>6}\t", .{n}) catch unreachable);
                    line_start = false;
                }
                const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| nl + 1 else rest.len;
                out.write(rest[0..end]);
                if (rest[end - 1] == '\n') line_start = true;
                rest = rest[end..];
            }
        }
    }
    return status;
}

const big_size = 64 * 1024;

fn copyFile(path: []const u8, buf: []u8) bool {
    const f = zdos.open(path, .read) catch |err| {
        errout.printf("cat: {s}: {s}\n", .{ path, zdos.message(err) });
        return false;
    };
    defer f.close();
    while (true) {
        const n = f.read(buf) catch |err| {
            errout.printf("cat: {s}: {s}\n", .{ path, zdos.message(err) });
            return false;
        };
        if (n == 0) return true;
        zdos.print(buf[0..n]);
    }
}

fn outOfMemory() u8 {
    errout.print("cat: not enough memory\n");
    return 1;
}
