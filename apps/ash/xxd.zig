const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

const max_columns = 256;

const Options = struct {
    columns: usize = 16,
    group: usize = 2,
    length: ?u64 = null,
    offset: u64 = 0,
    path: ?[]const u8 = null,
};

const Reader = struct {
    file: ?zdos.File,

    fn read(self: *Reader, buffer: []u8) zdos.Error!usize {
        if (self.file) |file| return file.read(buffer);
        return zdos.readInput(buffer);
    }
};

const SkipResult = enum { ready, end_of_input, failed };

pub fn run(args: []const []const u8) u8 {
    var options: Options = .{};
    var index: usize = 0;
    var parsing_options = true;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (parsing_options and std.mem.eql(u8, arg, "--")) {
            parsing_options = false;
            continue;
        }
        if (parsing_options and arg.len > 1 and arg[0] == '-') {
            const option = arg[1];
            if (option != 'c' and option != 'g' and option != 'l' and option != 's') {
                errout.printf("xxd: unsupported option: {s}\n", .{arg});
                return 2;
            }
            var value = arg[2..];
            if (value.len == 0) {
                index += 1;
                if (index == args.len) return usageError();
                value = args[index];
            }
            switch (option) {
                'c' => {
                    const columns = parseUnsigned(value, false) catch return usageError();
                    if (columns == 0 or columns > max_columns) return usageError();
                    options.columns = @intCast(columns);
                },
                'g' => {
                    const group = parseUnsigned(value, false) catch return usageError();
                    if (group == 0 or group > max_columns) return usageError();
                    options.group = @intCast(group);
                },
                'l' => options.length = parseUnsigned(value, false) catch return usageError(),
                's' => options.offset = parseUnsigned(value, true) catch return usageError(),
                else => unreachable,
            }
            continue;
        }
        if (options.path != null) {
            errout.print("xxd: only one input file is supported\n");
            return 2;
        }
        options.path = arg;
    }

    var reader: Reader = .{ .file = null };
    defer if (reader.file) |f| f.closeChecked() catch |err| printError(options.path.?, err);
    if (options.path) |path| {
        if (!std.mem.eql(u8, path, "-")) {
            reader.file = zdos.open(path, .read) catch |err| {
                printError(path, err);
                return 1;
            };
            reader.file.?.seek(options.offset) catch |err| {
                printError(path, err);
                return 1;
            };
        } else if (!zdos.inputRedirected()) {
            errout.print("xxd: standard input is not redirected\n");
            return 2;
        }
    } else if (!zdos.inputRedirected()) {
        errout.print("xxd: standard input is not redirected\n");
        return 2;
    }

    if (reader.file == null and options.offset > 0) {
        switch (skipInput(&reader, options.offset)) {
            .ready => {},
            .end_of_input => return 0,
            .failed => return 1,
        }
    }
    return dump(&reader, options);
}

fn skipInput(reader: *Reader, amount: u64) SkipResult {
    var remaining = amount;
    var buffer: [1024]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, buffer.len));
        const count = reader.read(buffer[0..want]) catch |err| {
            printError("standard input", err);
            return .failed;
        };
        if (count == 0) return .end_of_input;
        remaining -= @intCast(count);
    }
    return .ready;
}

fn dump(reader: *Reader, options: Options) u8 {
    var line: [max_columns]u8 = undefined;
    var bytes_read: u64 = 0;
    var line_offset = options.offset;
    while (options.length == null or bytes_read < options.length.?) {
        const available = if (options.length) |length|
            @as(usize, @intCast(@min(@as(u64, @intCast(options.columns)), length - bytes_read)))
        else
            options.columns;
        var count: usize = 0;
        while (count < available) {
            const n = reader.read(line[count..available]) catch |err| {
                printError(options.path orelse "standard input", err);
                return 1;
            };
            if (n == 0) break;
            count += n;
        }
        if (count == 0) return 0;

        printLine(line[0..count], options, line_offset);
        line_offset +%= @intCast(count);
        bytes_read +%= @intCast(count);
    }
    return 0;
}

fn printLine(bytes: []const u8, options: Options, offset: u64) void {
    var buf: [max_columns * 4 + 32]u8 = undefined;
    var n = (std.fmt.bufPrint(&buf, "{x:0>8}: ", .{offset}) catch unreachable).len;
    const hex = "0123456789abcdef";
    for (0..options.columns) |column| {
        if (column > 0 and column % options.group == 0) {
            buf[n] = ' ';
            n += 1;
        }
        if (column < bytes.len) {
            buf[n] = hex[bytes[column] >> 4];
            buf[n + 1] = hex[bytes[column] & 15];
        } else {
            buf[n] = ' ';
            buf[n + 1] = ' ';
        }
        n += 2;
    }
    buf[n] = ' ';
    buf[n + 1] = ' ';
    n += 2;
    for (bytes) |byte| {
        buf[n] = if (byte >= 0x20 and byte <= 0x7e) byte else '.';
        n += 1;
    }
    buf[n] = '\n';
    zdos.print(buf[0 .. n + 1]);
}

fn parseUnsigned(text: []const u8, allow_hex: bool) error{InvalidNumber}!u64 {
    if (allow_hex and text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        return std.fmt.parseInt(u64, text[2..], 16) catch error.InvalidNumber;
    }
    return std.fmt.parseInt(u64, text, 10) catch error.InvalidNumber;
}

fn usageError() u8 {
    errout.print("usage: xxd [-c COLUMNS] [-g GROUP] [-l LENGTH] [-s OFFSET] [FILE]\n");
    return 2;
}

fn printError(path: []const u8, err: zdos.Error) void {
    errout.printf("xxd: {s}: {s}\n", .{ path, zdos.message(err) });
}
