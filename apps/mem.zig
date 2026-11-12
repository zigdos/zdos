// MEM: the CPU and the memory, as DOS's MEM
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    const info = zdos.systemInfo();
    zdos.print("CPU                 ");
    zdos.print(info.cpuName());
    zdos.print("\n");
    if (info.cpu_mhz != 0) zdos.printf("CPU speed           about {d} MHz\n", .{info.cpu_mhz});
    zdos.printf("CPU cores           {d}\n", .{system.coreCount()});
    zdos.print("Total memory     ");
    printNum(info.total_memory / 1024, 12);
    zdos.print(" KB\nFree memory      ");
    printNum(info.free_memory / 1024, 12);
    zdos.print(" KB\nLargest free block");
    printNum(info.largest_free / 1024, 11);
    zdos.print(" KB\n");
    return 0;
}

// "    12,345"
fn printNum(n: u64, width: usize) void {
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    var v = n;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        digits += 1;
        if (v == 0) break;
    }
    var pad = width -| (buf.len - i);
    while (pad > 0) : (pad -= 1) zdos.print(" ");
    zdos.print(buf[i..]);
}
