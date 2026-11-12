const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const command_lookup = @import("command_lookup.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len == 0) {
        errout.print("usage: where COMMAND...\n");
        return 2;
    }
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result: u8 = 0;
    for (args) |name| {
        const matches = command_lookup.find(allocator, name) catch {
            errout.print("where: not enough memory\n");
            return 1;
        };
        if (matches.len == 0) {
            errout.printf("where: {s}: not found\n", .{name});
            result = 1;
            continue;
        }
        for (matches) |path| zdos.printf("{s}\n", .{path});
    }
    return result;
}
