// NSLOOKUP NAME: the name's address, HOSTS.CFG first, then DNS
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0 or name[0] == '-' or name[0] == '/') {
        zdos.print("NSLOOKUP NAME\n");
        return 1;
    }
    const i = net.info();
    var b: [16]u8 = undefined;
    if (i.flags & net.Flags.started != 0) zdos.printf("Server:   {s}\n\n", .{net.addressText(i.dns[0], &b)});
    const addr = net.resolve(name) catch |err| {
        zdos.eprintf("NSLOOKUP: {s}: {s}\n", .{ name, zdos.message(err) });
        return 1;
    };
    zdos.printf("Name:     {s}\nAddress:  {s}\n", .{ name, net.addressText(addr, &b) });
    return 0;
}
