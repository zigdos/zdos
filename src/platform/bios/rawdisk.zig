// Raw disk access (platform.zig: disk) over disk.zig; the index
// counts floppy drives too.
const platform = @import("../../platform.zig");
const disk = @import("disk.zig");

pub fn count() usize {
    return disk.disks.len;
}

pub fn info(index: usize) ?platform.DiskInfo {
    if (index >= disk.disks.len) return null;
    const d = &disk.disks[index];
    return .{
        .sectors = d.sectors,
        .sector_size = disk.sector_size,
        .removable = d.drive < 0x80, // floppy drives are 0x00 and 0x01
        .read_only = false, // the BIOS doesn't say; a failed write reports it
    };
}

pub fn read(index: usize, lba: u64, buf: []u8) platform.Error!void {
    if (index >= disk.disks.len or buf.len == 0 or buf.len % disk.sector_size != 0) return error.InvalidArgument;
    return disk.read(&disk.disks[index], lba, buf.len / disk.sector_size, buf);
}

pub fn write(index: usize, lba: u64, data: []const u8) platform.Error!void {
    if (index >= disk.disks.len or data.len == 0 or data.len % disk.sector_size != 0) return error.InvalidArgument;
    return disk.write(&disk.disks[index], lba, data.len / disk.sector_size, data);
}
