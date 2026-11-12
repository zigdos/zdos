const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len == 0 or args.len > 2) {
        errout.print("usage: basename PATH [SUFFIX]\n");
        return 2;
    }
    const path = args[0];
    if (path.len == 0) {
        zdos.print("\n");
        return 0;
    }
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and !isSeparator(path[start - 1])) start -= 1;
    const base = if (end == 1 and isSeparator(path[0]))
        path[0..1]
    else
        path[start..end];
    const suffix = if (args.len == 2) args[1] else "";
    const result = if (suffix.len > 0 and base.len > suffix.len and
        std.mem.endsWith(u8, base, suffix))
        base[0 .. base.len - suffix.len]
    else
        base;
    zdos.print(result);
    zdos.print("\n");
    return 0;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}
