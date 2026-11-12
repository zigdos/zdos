// Firmware boot entries (platform.zig: boot). A BIOS has none:
// it boots the active partition, which SYS sets up itself.
const platform = @import("../../platform.zig");

// The file the boot sector loads, from the root of the boot volume
pub fn file() ?[]const u8 {
    return "\\ZIGDOS.SYS";
}

pub fn add(vol: anytype, description: []const u8, file_path: []const u8) platform.Error!u16 {
    _ = vol;
    _ = description;
    _ = file_path;
    return error.NotSupported;
}
