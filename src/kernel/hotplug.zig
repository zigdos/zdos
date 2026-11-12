// USB disks plugged in and pulled out (metal): a task woken by
// the USB interrupt mounts or lets go of their volumes, gives
// new ones letters and says so on the console.
const std = @import("std");
const platform = @import("../platform.zig");
const storage = platform.storage;
const tasks = @import("tasks.zig");
const fs = @import("fs.zig");
const con = @import("console.zig");

pub fn start() void {
    if (comptime !@hasDecl(storage, "hotplugStart")) return;
    if (!tasks.active() or tasks.kernelTask(&taskMain, 0, "USB", 20) == null) return;
    storage.hotplugStart(&wake);
}

fn wake() void {
    tasks.wake(storage.hotplug_news);
}

fn taskMain(_: usize) callconv(.c) noreturn {
    while (true) {
        const seen = storage.hotplug_news.load(.acquire);
        _ = tasks.enterKernel();
        update();
        tasks.leaveKernel();
        _ = tasks.waitObjectSince(storage.hotplug_news, null, storage.hotplug_news, seen);
        // The debounce after a connect; news of a few ports taken together
        _ = tasks.sleep(100);
    }
}

fn update() void {
    var changes: [24]storage.HotplugChange = undefined;
    const n = storage.hotplugUpdate(&changes);
    if (n == 0) return;
    fs.volumesChanged();
    for (changes[0..n]) |c| {
        const d = for (fs.drives) |*d| {
            if (d.vol == c.vol) break d;
        } else continue;
        d.checked = std.math.maxInt(u32); // checked again at the next request
        if (d.letter == 0) continue;
        if (con.getCursor().col != 0) con.print("\n");
        if (!c.came) {
            con.printf("USB: {c}: removed\n", .{d.letter});
            continue;
        }
        const info = storage.volumeInfo(c.vol) orelse continue;
        var size_buf: [16]u8 = undefined;
        con.printf("USB: {c}: ({s}, {s})\n", .{ d.letter, info.fs_name, sizeText(info.size, &size_buf) });
    }
}

// "7.5 GB", "64 MB"
fn sizeText(bytes: u64, buf: *[16]u8) []const u8 {
    const gb = 1024 * 1024 * 1024;
    if (bytes < gb) return std.fmt.bufPrint(buf, "{d} MB", .{bytes / (1024 * 1024)}) catch "";
    const tenths = (bytes * 10 + gb / 2) / gb;
    return std.fmt.bufPrint(buf, "{d}.{d} GB", .{ tenths / 10, tenths % 10 }) catch "";
}
