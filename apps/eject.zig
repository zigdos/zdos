// EJECT X:: writes out a USB disk's drives and lets the disk go (metal)
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    const a = std.mem.trim(u8, args, " \t");
    if (a.len != 2 or a[1] != ':' or !std.ascii.isAlphabetic(a[0])) {
        zdos.print("Usage: EJECT X:\n");
        return 1;
    }
    const letter = std.ascii.toUpper(a[0]);
    const info = zdos.driveInfo(letter) catch {
        zdos.print("Invalid drive specification\n");
        return 1;
    };
    if (!info.removable) {
        zdos.printf("Drive {c}: is not removable\n", .{letter});
        return 1;
    }
    if (info.boot) {
        zdos.printf("Drive {c}: is the boot drive\n", .{letter});
        return 1;
    }
    // The other drives on the same disk go with it:
    var others: [26]u8 = undefined;
    var n: usize = 0;
    if (sys.driveLocation(letter)) |here| {
        var buf: [26]u8 = undefined;
        for (zdos.getDrives(&buf)) |l| {
            if (l == letter) continue;
            const there = sys.driveLocation(l) catch continue;
            if (there.disk == here.disk) {
                others[n] = l;
                n += 1;
            }
        }
    } else |_| {}
    sys.eject(letter) catch |err| {
        switch (err) {
            error.AccessDenied => zdos.printf("Drive {c}: is in use: a file is open for writing there, or ZDOS runs from that disk\n", .{letter}),
            error.NotSupported => zdos.print("EJECT is not supported here\n"),
            error.DeviceError => zdos.printf("Drive {c}: is not ready\n", .{letter}),
            else => zdos.printf("Drive {c}: {s}\n", .{ letter, zdos.message(err) }),
        }
        return 1;
    };
    zdos.printf("Drive {c}:", .{letter});
    for (others[0..n]) |l| zdos.printf(", {c}:", .{l});
    zdos.print(" can be removed safely now\n");
    return 0;
}
