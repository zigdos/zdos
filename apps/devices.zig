// DEVICES: the CPU and devices
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");
const net = @import("zdos/net.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;

    const cpu = zdos.systemInfo();
    zdos.printf("CPU                 {s}\n", .{cpu.cpuName()});
    if (cpu.cpu_mhz != 0) zdos.printf("CPU speed           about {d} MHz\n", .{cpu.cpu_mhz});
    zdos.printf("CPU cores           {d}\n", .{system.coreCount()});
    zdos.print("Logical CPU threads  not reported by ZDOS\n");

    zdos.print("\nStorage devices:\n");
    const disks = system.diskCount();
    if (disks == 0) {
        zdos.print("  No disks reported\n");
    } else {
        for (0..disks) |index| {
            const info = system.diskInfo(@intCast(index)) orelse continue;
            const mib = info.sectors * info.sector_size / (1024 * 1024);
            zdos.printf("  Disk {d}: {d} MiB, sector size {d} bytes{s}{s}\n", .{
                index,
                mib,
                info.sector_size,
                if (info.removable) ", removable" else "",
                if (info.read_only) ", read-only" else "",
            });
        }
    }

    zdos.print("\nVolumes:\n");
    var drive_index: u32 = 0;
    var drives_found = false;
    while (system.driveAt(drive_index)) |drive| : (drive_index += 1) {
        drives_found = true;
        if (drive.letter != 0) {
            zdos.printf("  {c}: ", .{drive.letter});
        } else {
            zdos.printf("  Drive {d}: ", .{drive_index});
        }
        if (drive.label().len > 0) zdos.printf("{s} ", .{drive.label()});
        if (drive.ready or drive.unreadable) {
            const fs_name = zdos.fileSystemName(drive.file_system);
            zdos.printf("{s}, {d} MiB", .{
                if (fs_name.len > 0) fs_name else "unknown filesystem",
                drive.size / (1024 * 1024),
            });
        } else {
            zdos.print("(no readable media)");
        }
        if (drive.removable) zdos.print(", removable");
        if (drive.unreadable) zdos.print(", unreadable");
        zdos.print("\n");
    }
    if (!drives_found) zdos.print("  No volumes reported\n");

    zdos.print("\nNetwork interfaces:\n");
    var interfaces_found = false;
    var interface_index: u32 = 0;
    while (net.interface(interface_index)) |interface| : (interface_index += 1) {
        if (interface.flags & net.Flags.started == 0) continue;
        interfaces_found = true;
        if (interface.card().len > 0) {
            zdos.printf("  {s}\n", .{interface.card()});
        } else {
            zdos.printf("  Interface {d}\n", .{interface_index});
        }
    }
    if (!interfaces_found) zdos.print("  No configured interfaces reported\n");

    zdos.print("\nPCI/ISA/USB bus enumeration is not yet emplemented in this app.\n");
    return 0;
}
