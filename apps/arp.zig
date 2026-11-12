// ARP [-a] | -s ADDRESS MAC | -d ADDRESS|*: THE ARP TABLE
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

fn usage() u8 {
    zdos.print("ARP [-a]\nARP -s ADDRESS MAC\nARP -d ADDRESS | *\n");
    return 1;
}

fn failed(err: zdos.Error) u8 {
    zdos.eprintf("ARP: {s}\n", .{zdos.message(err)});
    return 1;
}

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    const first = words.next() orelse return list();
    if (std.ascii.eqlIgnoreCase(first, "-a") or std.mem.eql(u8, first, "/a")) return list();
    if (std.ascii.eqlIgnoreCase(first, "-s")) {
        const addr = net.parseAddress(words.next() orelse return usage()) orelse return usage();
        const mac = net.parseMac(words.next() orelse return usage()) orelse return usage();
        net.arpAdd(addr, mac) catch |err| return failed(err);
        return 0;
    }
    if (std.ascii.eqlIgnoreCase(first, "-d")) {
        const which = words.next() orelse return usage();
        const addr: ?[4]u8 = if (std.mem.eql(u8, which, "*")) null else net.parseAddress(which) orelse return usage();
        net.arpRemove(addr) catch |err| return failed(err);
        return 0;
    }
    return usage();
}

fn list() u8 {
    const i = net.info();
    if (i.flags & net.Flags.started == 0) {
        zdos.print("No network\n");
        return 1;
    }
    var b: [16]u8 = undefined;
    zdos.printf("Interface: {s}\n  Internet address      Physical address      Type\n", .{net.addressText(i.address, &b)});
    var index: u32 = 0;
    while (net.arpEntry(index)) |e| : (index += 1) {
        var m: [18]u8 = undefined;
        zdos.printf("  {s: <20}  {s: <20}  {s}\n", .{ net.addressText(e.address, &b), net.macText(e.mac, &m), if (e.is_static) "static" else "dynamic" });
    }
    if (index == 0) zdos.print("  (none)\n");
    return 0;
}
