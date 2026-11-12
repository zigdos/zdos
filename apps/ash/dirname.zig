const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len != 1) {
        errout.print("usage: dirname PATH\n");
        return 2;
    }
    const path = args[0];
    if (path.len == 0) {
        zdos.print(".\n");
        return 0;
    }

    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) end -= 1;
    var separator: ?usize = null;
    var index = end;
    while (index > 0) {
        index -= 1;
        if (isSeparator(path[index])) {
            separator = index;
            break;
        }
    }
    if (separator) |at| {
        if (at == 0) {
            zdos.print(path[0..1]);
        } else {
            var result_end = at;
            while (result_end > 1 and isSeparator(path[result_end - 1])) result_end -= 1;
            zdos.print(path[0..result_end]);
        }
    } else {
        zdos.print(".");
    }
    zdos.print("\n");
    return 0;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}
