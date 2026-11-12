// A SYSTEM.CFG setting while the firmware
// still runs (RESOLUTION=): C: as the
// kernel will pick it, read through the
// UEFI edition's storage
const std = @import("std");
const platform = @import("../../platform.zig");
const fw_storage = @import("../uefi/storage.zig");
const drive_c = @import("../../kernel/drive_c.zig");
const config = @import("../../kernel/config.zig");

var text: [config.max_size]u8 = undefined;

// The value of name, copied into out; null if not set
pub fn get(name: []const u8, out: []u8) ?[]const u8 {
    defer fw_storage.forgetAll();
    var vols: [32]fw_storage.Volume = undefined;
    var flags: [32]platform.VolumeFlags = undefined;
    const n = fw_storage.listVolumes(&vols, &flags);
    const c = drive_c.pick(fw_storage, vols[0..n], flags[0..n]) orelse return null;
    const f = fw_storage.openFile(vols[c], config.path, .read) catch return null;
    defer fw_storage.close(f) catch {};
    var len: usize = 0;
    while (len < text.len) {
        const got = fw_storage.read(f, text[len..]) catch return null;
        if (got == 0) break;
        len += got;
    }
    // The last setting wins, as in the kernel's variables
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text[0..len], '\n');
    while (lines.next()) |raw| {
        switch (config.line(raw)) {
            .setting => |s| if (std.ascii.eqlIgnoreCase(s.name, name)) {
                found = s.value;
            },
            else => {},
        }
    }
    const value = found orelse return null;
    if (value.len > out.len) return null;
    @memcpy(out[0..value.len], value);
    return out[0..value.len];
}
