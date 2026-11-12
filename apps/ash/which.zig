const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const command_lookup = @import("command_lookup.zig");
const names = @import("names.zig");

pub fn run(args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var all = false;
    var first: usize = 0;
    if (args.len > 0 and std.mem.eql(u8, args[0], "-a")) {
        all = true;
        first = 1;
    }
    if (first == args.len) {
        errout.print("usage: which [-a] COMMAND...\n");
        return 2;
    }

    var result: u8 = 0;
    for (args[first..]) |name| {
        var found = false;
        if (names.isBuiltin(name)) {
            zdos.printf("{s}: shell built-in\n", .{name});
            found = true;
            if (!all) continue;
        }
        const matches = command_lookup.find(allocator, name) catch {
            errout.print("which: not enough memory\n");
            return 1;
        };
        for (matches) |path| {
            zdos.printf("{s}\n", .{path});
            found = true;
            if (!all) break;
        }
        if (!found) {
            errout.printf("which: {s}: not found\n", .{name});
            result = 1;
        }
    }
    return result;
}
