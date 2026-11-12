// Firmware boot entries (SYS): a Boot#### variable for a file
// on a volume, put first in BootOrder. Device path: the
// partition's path, then a file path node. An existing entry
// for the same file is reused. Metal: addEntry with a GPT or
// MBR hard drive node (runtime services only).
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const storage = @import("storage.zig");
const text = @import("text.zig");

const load_option_active: u32 = 0x1;
const variable_attributes: u32 = 0x1 | 0x2 | 0x4;
const max_entries = 0x1000; // Boot0000 ... Boot0FFF
const max_option = 2048;

// "Boot" and four hex digits, zero-terminated, as UTF-16
fn bootName(index: u16, buf: *[9]u16) void {
    const hex = "0123456789ABCDEF";
    for ("Boot", 0..) |c, i| buf[i] = c;
    for (0..4) |k| {
        const shift: u4 = @intCast(12 - 4 * k);
        buf[4 + k] = hex[(index >> shift) & 0xF];
    }
    buf[8] = 0;
}

// The file path as UTF-16 bytes,
// zero-terminated (for the file path node)
fn pathBytes(file_path: []const u8, out: *[max_option]u8) ?usize {
    var ucs: [256]u16 = undefined;
    const z = text.utf8ToUcs2Z(file_path, &ucs) orelse return null;
    const chars = std.mem.len(z) + 1;
    @memcpy(out[0 .. 2 * chars], std.mem.sliceAsBytes(ucs[0..chars]));
    return 2 * chars;
}

fn containsPath(data: []const u8, path_ucs: []const u8) bool {
    if (path_ucs.len == 0 or data.len < path_ucs.len) return false;
    var i: usize = 0;
    while (i + path_ucs.len <= data.len) : (i += 1) {
        if (std.mem.eql(u8, data[i..][0..path_ucs.len], path_ucs)) return true;
    }
    return false;
}

// The file ZDOS was started from, from
// LoadedImage's file path nodes. A path
// may be split over several nodes
// ("\EFI", "BOOT", "BOOTX64.EFI"):
// joined with single backslashes.
var boot_path_buf: [256]u8 = undefined;
var boot_path_len: ?usize = null;

pub fn file() ?[]const u8 {
    if (boot_path_len) |n| return if (n == 0) null else boot_path_buf[0..n];
    boot_path_len = 0;
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.boot_services.?.handleProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, &ptr) != .success) return null;
    const image: *const uefi.protocol.LoadedImage = @ptrCast(@alignCast(ptr.?));
    // The nodes may be unaligned: read as bytes
    var p: [*]const u8 = @ptrCast(image.file_path);
    var n: usize = 0;
    var nodes: usize = 0;
    while (nodes < 64) : (nodes += 1) {
        const kind = p[0];
        const sub = p[1];
        const len = std.mem.readInt(u16, p[2..4], .little);
        if (kind == 0x7F or len < 4) break; // the end node
        if (kind == 4 and sub == 4) {
            // A file path node: UCS-2, zero-terminated
            var chars: usize = 0;
            while (4 + 2 * chars + 1 < len) : (chars += 1) {
                const c = std.mem.readInt(u16, p[4 + 2 * chars ..][0..2], .little);
                if (c == 0) break;
                var ucs = [1]u16{if (c == '/') '\\' else c};
                // One backslash where two nodes meet, and one at the start
                if (ucs[0] == '\\' and n > 0 and boot_path_buf[n - 1] == '\\') continue;
                if (chars == 0 and ucs[0] != '\\' and (n == 0 or boot_path_buf[n - 1] != '\\')) {
                    if (n == boot_path_buf.len) return null;
                    boot_path_buf[n] = '\\';
                    n += 1;
                }
                const out = text.ucs2ToUtf8(&ucs, boot_path_buf[n..]);
                if (out.len == 0) return null; // too long
                n += out.len;
            }
        }
        p += len;
    }
    // A trailing backslash (a folder node at
    // the end) is not part of a file's path
    if (n > 1 and boot_path_buf[n - 1] == '\\') n -= 1;
    boot_path_len = n;
    return if (n == 0) null else boot_path_buf[0..n];
}

// file_path: UTF-8 with backslashes. Returns the entry's index.
pub fn add(vol: storage.Volume, description: []const u8, file_path: []const u8) platform.Error!u16 {
    const bs = uefi.system_table.boot_services.?;
    const handle = storage.deviceHandle(vol) orelse return error.NotSupported;

    // The partition's device path, without its end node (4 bytes)
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(handle, &uefi.protocol.DevicePath.guid, &ptr) != .success) return error.NotSupported;
    const dp: *uefi.protocol.DevicePath = @ptrCast(@alignCast(ptr.?));
    return addEntry(@as([*]const u8, @ptrCast(dp))[0 .. dp.size() - 4], description, file_path);
}

// prefix: the partition's device path nodes, without an end node
pub fn addEntry(prefix: []const u8, description: []const u8, file_path: []const u8) platform.Error!u16 {
    const rs = uefi.system_table.runtime_services;
    const body = prefix.len;
    if (body + 8 > max_option) return error.InvalidArgument;

    var file_ucs: [max_option]u8 = undefined;
    const file_len = pathBytes(file_path, &file_ucs) orelse return error.InvalidName;

    // Partition path, file path node, end node
    var device: [max_option]u8 = undefined;
    if (body + 8 + file_len > device.len) return error.InvalidName;
    @memcpy(device[0..body], prefix);
    device[body] = 0x04; // media device path
    device[body + 1] = 0x04; // file path
    std.mem.writeInt(u16, device[body + 2 ..][0..2], @intCast(4 + file_len), .little);
    @memcpy(device[body + 4 ..][0..file_len], file_ucs[0..file_len]);
    const end = body + 4 + file_len;
    device[end] = 0x7F;
    device[end + 1] = 0xFF;
    device[end + 2] = 4;
    device[end + 3] = 0;
    const device_len = end + 4;

    var desc_ucs: [max_option]u8 = undefined;
    var desc_wide: [128]u16 = undefined;
    const desc_z = text.utf8ToUcs2Z(description, &desc_wide) orelse return error.InvalidName;
    const desc_len = 2 * (std.mem.len(desc_z) + 1);
    @memcpy(desc_ucs[0..desc_len], std.mem.sliceAsBytes(desc_wide[0 .. desc_len / 2]));

    // The first Boot#### name that is free;
    // an entry for the same file is reused
    var free: ?u16 = null;
    var found: ?u16 = null;
    var index: u32 = 0;
    while (index < max_entries) : (index += 1) {
        var name: [9]u16 = undefined;
        bootName(@intCast(index), &name);
        var data: [4096]u8 = undefined;
        var size: usize = data.len;
        const status = rs.getVariable(@ptrCast(&name), &uefi.tables.global_variable, null, &size, &data);
        if (status == .not_found) {
            if (free == null) free = @intCast(index);
            continue;
        }
        if (status == .success and containsPath(data[0..size], file_ucs[0..file_len])) {
            found = @intCast(index);
            break;
        }
    }
    if (found) |existing| return existing;
    const idx = free orelse return error.OutOfMemory;

    // The load option: attributes, device
    // path length, description, device path
    var option: [max_option]u8 = undefined;
    std.mem.writeInt(u32, option[0..4], load_option_active, .little);
    std.mem.writeInt(u16, option[4..6], @intCast(device_len), .little);
    @memcpy(option[6..][0..desc_len], desc_ucs[0..desc_len]);
    const option_len = 6 + desc_len + device_len;
    @memcpy(option[6 + desc_len ..][0..device_len], device[0..device_len]);

    var name: [9]u16 = undefined;
    bootName(idx, &name);
    if (rs.setVariable(@ptrCast(&name), &uefi.tables.global_variable, variable_attributes, option_len, &option) != .success) {
        return error.DeviceError;
    }

    // BootOrder: the new entry first, then the rest
    var order_name = std.unicode.utf8ToUtf16LeStringLiteral("BootOrder").*;
    var old: [512]u8 = undefined;
    var old_size: usize = old.len;
    var new_order: [514]u8 = undefined;
    std.mem.writeInt(u16, new_order[0..2], idx, .little);
    var n: usize = 1;
    if (rs.getVariable(&order_name, &uefi.tables.global_variable, null, &old_size, &old) == .success) {
        var i: usize = 0;
        while (i + 2 <= old_size) : (i += 2) {
            const entry = std.mem.readInt(u16, old[i..][0..2], .little);
            if (entry == idx) continue;
            std.mem.writeInt(u16, new_order[2 * n ..][0..2], entry, .little);
            n += 1;
        }
    }
    if (rs.setVariable(&order_name, &uefi.tables.global_variable, variable_attributes, 2 * n, &new_order) != .success) {
        return error.DeviceError;
    }
    return idx;
}
