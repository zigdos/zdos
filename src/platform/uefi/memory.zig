// Memory: the firmware's page and pool allocators
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");

pub fn allocPages(count: usize, executable: bool) ?[*]align(4096) u8 {
    // loader_code memory may run code; the
    // firmware may mark other types non-executable
    const kind: uefi.tables.MemoryType = if (executable) .loader_code else .loader_data;
    var mem: [*]align(4096) u8 = undefined;
    if (uefi.system_table.boot_services.?.allocatePages(.allocate_any_pages, kind, count, &mem) != .success) return null;
    return mem;
}

pub fn freePages(ptr: [*]align(4096) u8, count: usize) void {
    _ = uefi.system_table.boot_services.?.freePages(ptr, count);
}

pub fn alloc(size: usize) ?[*]align(8) u8 {
    var mem: [*]align(8) u8 = undefined;
    if (uefi.system_table.boot_services.?.allocatePool(.loader_data, size, &mem) != .success) return null;
    return mem;
}

pub fn free(ptr: [*]align(8) u8) void {
    _ = uefi.system_table.boot_services.?.freePool(ptr);
}

// RAM: every memory map type the firmware and loaded images
// use, plus conventional (free) memory
pub fn stats() platform.MemoryStats {
    var result: platform.MemoryStats = .{ .total = 0, .free = 0, .largest_free = 0 };
    const bs = uefi.system_table.boot_services.?;
    var size: usize = 0;
    var key: usize = 0;
    var desc_size: usize = 0;
    var version: u32 = 0;
    _ = bs.getMemoryMap(&size, null, &key, &desc_size, &version);
    if (desc_size == 0) return result;
    // Room for a few more entries: allocating the buffer can split one
    size += 8 * desc_size;
    const buf = alloc(size) orelse return result;
    defer free(buf);
    if (bs.getMemoryMap(&size, @ptrCast(@alignCast(buf)), &key, &desc_size, &version) != .success) return result;
    var off: usize = 0;
    while (off + desc_size <= size) : (off += desc_size) {
        const d: *const uefi.tables.MemoryDescriptor = @ptrCast(@alignCast(buf + off));
        const bytes = d.number_of_pages * 4096;
        switch (d.type) {
            .conventional_memory => {
                result.total += bytes;
                result.free += bytes;
                result.largest_free = @max(result.largest_free, bytes);
            },
            .loader_code, .loader_data, .boot_services_code, .boot_services_data, .runtime_services_code, .runtime_services_data, .acpi_reclaim_memory, .acpi_memory_nvs => result.total += bytes,
            else => {},
        }
    }
    return result;
}
