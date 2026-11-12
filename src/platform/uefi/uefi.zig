// Platform backend on UEFI firmware (see platform.zig).
// ExitBootServices is never called: the
// firmware's drivers keep running the hardware.
const std = @import("std");
const uefi = std.os.uefi;

pub const console = @import("console.zig");
pub const storage = @import("storage.zig");
pub const memory = @import("memory.zig");
pub const clock = @import("clock.zig");
pub const graphics = @import("graphics.zig");
pub const boot = @import("boot.zig");
pub const disk = @import("rawdisk.zig");
// Other CPU cores, through the firmware (platform.cores)
pub const cores = @import("cores.zig");
// The network card, through the firmware (platform.net)
pub const net = @import("net.zig");
// Tasks switch only inside ZDOS (platform.switching)
pub const switching = @import("switching.zig");
const screen_mode = @import("screen_mode.zig");

pub const name = "UEFI";
pub const config = @import("config.zig");

pub const power = struct {
    pub fn shutdown() noreturn {
        uefi.system_table.runtime_services.resetSystem(.reset_shutdown, .success, 0, null);
    }

    pub fn restart() noreturn {
        uefi.system_table.runtime_services.resetSystem(.reset_cold, .success, 0, null);
    }
};

pub fn init() void {
    console.init();
    // The firmware resets the machine after 5
    // minutes unless the watchdog is disabled
    _ = uefi.system_table.boot_services.?.setWatchdogTimer(0, 0, 0, null);
    storage.init();
    clock.init();
}

// After SYSTEM.CFG, before FONT= sizes the text to the screen
pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    const value = get("RESOLUTION") orelse return;
    const g = console.gop() orelse return;
    screen_mode.record(g);
    screen_mode.apply(g, value) catch |err| screen_mode.report(value, err, &console.write);
}
