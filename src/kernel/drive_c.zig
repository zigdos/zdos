// Which volume becomes C:, for the kernel's drive scan and for
// metal before it leaves the firmware.
const platform = @import("../platform.zig");

pub fn normal(f: platform.VolumeFlags) bool {
    return !f.system and !f.hidden and !f.floppy and !f.unreadable;
}

pub fn hasApps(comptime Storage: type, v: Storage.Volume) bool {
    var info: platform.EntryInfo = .{};
    Storage.stat(v, "\\APPS", &info) catch return false;
    return info.is_dir;
}

// The boot volume unless it is an ESP (or has no \APPS while
// another normal volume has), else the first normal volume with
// \APPS, else the first normal volume,
// the ESP only if there is none
pub fn pick(comptime Storage: type, vols: []const Storage.Volume, flags: []const platform.VolumeFlags) ?usize {
    var c: ?usize = null;
    for (flags, 0..) |f, i| {
        if (f.boot and normal(f)) c = i;
    }
    // A boot volume without \APPS (a stick's FAT boot partition,
    // the system on a second one): the normal volume that has it
    if (c) |i| {
        if (!hasApps(Storage, vols[i])) {
            for (flags, 0..) |f, k| {
                if (k != i and normal(f) and hasApps(Storage, vols[k])) return k;
            }
        }
        return i;
    }
    for (flags, 0..) |f, i| {
        if (normal(f) and hasApps(Storage, vols[i])) return i;
    }
    for (flags, 0..) |f, i| {
        if (normal(f)) return i;
    }
    for (flags, 0..) |f, i| {
        if (!f.hidden and !f.floppy and !f.unreadable and (c == null or f.boot)) c = i;
    }
    return c;
}
