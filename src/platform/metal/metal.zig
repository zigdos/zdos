// Platform backend for bare metal (see platform.zig),
// x86_64 and ARM64. It starts as a UEFI application
// (src/main.zig) and calls ExitBootServices in init;
// afterwards only runtime services (time, power off) are used.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");

pub const console = @import("console.zig");
pub const storage = @import("storage.zig");
pub const memory = @import("memory.zig");
pub const clock = @import("clock.zig");
// The other CPU cores, as workers for programs' jobs (platform.cores)
pub const cores = @import("smp.zig");
// Switching between tasks (tasks.zig)
pub const switching = @import("switching.zig");
// The network card (platform.net)
pub const net = @import("net.zig");
pub const net_core = @import("net_core.zig");
// Drivers from files (kernel/drivers.zig): registers mapped
// late if need be W^X for loaded images (RW_NX=, paging.zig)
pub const exec_protect = struct {
    pub fn code(start: usize, end: usize, read_only: bool) bool {
        return paging.protectCode(start, end, read_only);
    }
    pub fn release(start: usize, end: usize) void {
        paging.releaseCode(start, end);
    }
};
pub const own_drivers = struct {
    pub fn mapDevice(start: u64, len: u64) bool {
        return paging.mapDevice(start, len);
    }
    pub const attachInterrupt = driver_irq.attach;
    pub const attachMessage = driver_irq.attachMessage;
    pub const attachTo = driver_irq.attachTo;
};
const driver_irq = @import("driver_irq.zig");
const framebuffer = @import("framebuffer.zig");
const acpi = @import("acpi.zig");
const usb = @import("usb.zig");
const ps2 = @import("ps2.zig");
const cpu = @import("cpu.zig");
const disks = @import("disks.zig");
const paging = @import("paging.zig");
const screen_mode = @import("../uefi/screen_mode.zig");
const early_config = @import("early_config.zig");
pub const serial = @import("serial.zig");

pub const name = "METAL";
pub const config = @import("config.zig");

pub fn init() void {
    // What only the firmware can tell: the ACPI tables (the serial
    // port is in them), the screen
    acpi.capture();
    var serial_buf: [8]u8 = undefined;
    serial.setMode(early_config.get("SERIAL", &serial_buf));
    console.init();
    clock.init(); // calibrated with the firmware's Stall: before leaving it
    framebuffer.capture(setScreenMode);
    disks.captureBootPartition();
    captureImage();
    // No screen ZDOS can draw on: the firmware's
    // last word points to the serial port
    if (!framebuffer.found()) {
        serial.mode = .on; // the only console, whatever SERIAL= says
        if (uefi.system_table.con_out) |out| {
            _ = out.outputString(std.unicode.utf8ToUtf16LeStringLiteral("ZDOS (metal): no framebuffer; the console is on the serial port\r\n"));
        }
    }
    if (builtin.cpu.arch == .x86_64) {
        var ps2_buf: [8]u8 = undefined;
        ps2.setMode(early_config.get("PS2INPUT", &ps2_buf));
    }
    var paging_buf: [16]u8 = undefined;
    memory.setGranule(paging.sizeFor(early_config.get("PAGING", &paging_buf)));
    if (!memory.leaveFirmware()) {
        console.write("\nZDOS could not leave the firmware. System halted.\n");
        halt();
    }
    disableInterrupts();
    cpu.init(); // x86_64: own interrupt table, exceptions, the idle timer
    cores.reserve();
    _ = framebuffer.start();
    switch (builtin.cpu.arch) {
        .x86_64 => ps2.init(),
        else => {},
    }
    usb.init(&console.write);
    disks.init(&console.write); // after USB: its mass storage devices are disks too
    net.probe(); // after USB has registered PCI's ECAM
    storage.init();
}

// Once tasks switch (tasks.zig): the
// disk and USB controllers' interrupts
pub fn startInterrupts() void {
    disks.startInterrupts();
    usb.startInterrupts();
    if (builtin.cpu.arch == .x86_64) ps2.startInterrupts();
}

// Settings from SYSTEM.CFG, once the kernel has read it:
// PAGING= and RW_NX= (paging.zig)
pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    paging.setRwNx(get("RW_NX"));
    paging.configure(get("PAGING"));
    if (resolution_err) |err| screen_mode.report(resolution.?, err, &console.write);
}

// RESOLUTION= of SYSTEM.CFG, read while the firmware can
// still switch modes; a problem is reported once the
// console works (configure)
var resolution_buf: [32]u8 = undefined;
var resolution: ?[]const u8 = null;
var resolution_err: ?screen_mode.Error = null;

// The modes for SCREEN, then RESOLUTION=
fn setScreenMode(g: *uefi.protocol.GraphicsOutput) void {
    screen_mode.record(g);
    resolution = early_config.get("RESOLUTION", &resolution_buf);
    if (resolution) |value| screen_mode.apply(g, value) catch |err| {
        resolution_err = err;
    };
}

// Where ZDOS's own image is (switching tells its code from programs')
fn captureImage() void {
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, &ptr) != .success) return;
    const image: *const uefi.protocol.LoadedImage = @ptrCast(@alignCast(ptr.?));
    switching.setImage(@intFromPtr(image.image_base), image.image_size);
    paging.setImage(@intFromPtr(image.image_base), image.image_size);
}

pub const power = struct {
    pub fn shutdown() noreturn {
        uefi.system_table.runtime_services.resetSystem(.reset_shutdown, .success, 0, null);
    }

    pub fn restart() noreturn {
        uefi.system_table.runtime_services.resetSystem(.reset_cold, .success, 0, null);
    }
};

// A program's picture on the framebuffer (graphics.zig)
pub const graphics = @import("graphics.zig");

// Whole disks for raw access (FDISK,
// FORMAT), in 512-byte sectors (disks.zig)
pub const disk = struct {
    pub fn count() usize {
        return disks.count;
    }

    pub fn info(index: usize) ?platform.DiskInfo {
        if (index >= disks.count) return null;
        const d = &disks.list[index];
        if (disks.missing(d)) return .{ .sectors = 0, .sector_size = disks.sector_size, .removable = true, .read_only = d.read_only };
        return .{ .sectors = d.sectors, .sector_size = disks.sector_size, .removable = d.removable, .read_only = d.read_only };
    }

    pub fn read(index: usize, lba: u64, buf: []u8) platform.Error!void {
        if (index >= disks.count or buf.len % disks.sector_size != 0) return error.InvalidArgument;
        return disks.read(&disks.list[index], lba, buf.len / disks.sector_size, buf);
    }

    pub fn write(index: usize, lba: u64, data: []const u8) platform.Error!void {
        if (index >= disks.count or data.len % disks.sector_size != 0) return error.InvalidArgument;
        return disks.write(&disks.list[index], lba, data.len / disks.sector_size, data);
    }
};

// Boot entries live in the firmware's variables: not reachable yet
pub const boot = struct {
    const entries = @import("../uefi/boot.zig");

    pub fn file() ?[]const u8 {
        return null;
    }

    // Through the runtime services, with a hard drive node for
    // the partition, from its disk's table: the firmware finds
    // the partition by it (GPT: slot and unique GUID; MBR: slot
    // and disk signature, primary partitions only)
    pub fn add(vol: storage.Volume, description: []const u8, file_path: []const u8) platform.Error!u16 {
        const where = storage.location(vol) orelse return error.NotSupported;
        var node: [42]u8 = @splat(0);
        node[0] = 4; // media device path
        node[1] = 1; // hard drive
        std.mem.writeInt(u16, node[2..4], node.len, .little);
        std.mem.writeInt(u64, node[8..16], where.start, .little);
        std.mem.writeInt(u64, node[16..24], where.sectors, .little);
        var sec: [512]u8 = undefined;
        if (!storage.diskSector(vol, 1, &sec)) return error.DeviceError;
        if (std.mem.eql(u8, sec[0..8], "EFI PART")) {
            const first = std.mem.readInt(u64, sec[72..80], .little);
            const count = std.mem.readInt(u32, sec[80..84], .little);
            const size = std.mem.readInt(u32, sec[84..88], .little);
            if (size < 128 or size > 512 or 512 % size != 0) return error.NotSupported;
            const per = 512 / size;
            var i: u32 = 0;
            const slot: u32 = while (i < @min(count, 1024)) : (i += 1) {
                if (i % per == 0 and !storage.diskSector(vol, first + i / per, &sec)) return error.DeviceError;
                const e = sec[(i % per) * size ..][0..128];
                if (std.mem.readInt(u64, e[32..40], .little) == where.start) {
                    @memcpy(node[24..40], e[16..32]);
                    break i + 1;
                }
            } else return error.NotSupported;
            std.mem.writeInt(u32, node[4..8], slot, .little);
            node[40] = 2; // GPT
            node[41] = 2; // GUID signature
        } else {
            if (!storage.diskSector(vol, 0, &sec) or sec[510] != 0x55 or sec[511] != 0xAA) return error.NotSupported;
            const slot: u32 = for (0..4) |k| {
                if (std.mem.readInt(u32, sec[446 + 16 * k + 8 ..][0..4], .little) == where.start) break @intCast(k + 1);
            } else return error.NotSupported;
            std.mem.writeInt(u32, node[4..8], slot, .little);
            @memcpy(node[24..28], sec[440..444]);
            node[40] = 1; // MBR
            node[41] = 1; // 32-bit signature
        }
        return entries.addEntry(&node, description, file_path);
    }
};

fn disableInterrupts() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("cli"),
        .aarch64 => asm volatile ("msr daifset, #0x3"), // IRQ and FIQ
        else => @compileError("metal: x86_64 and aarch64 only"),
    }
}

fn halt() noreturn {
    disableInterrupts();
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}

// A Zig panic is a kernel bug: show it and halt (src/main.zig)
pub fn panicHalt(msg: []const u8, _: ?usize) noreturn {
    serial.toPolled();
    console.setColor(15, 4);
    console.write("\n*** ZDOS panic: ");
    console.write(msg);
    console.write("\nSystem halted. Restart the computer.\n");
    halt();
}
