//! USB mass storage, Bulk-Only Transport (SCSI commands).
//!
//! The instance must stay put once readDiskCapacity() has run:
//! the block-device adapter keeps a pointer to it.

const std = @import("std");
const xhci = @import("xhci.zig");

pub const CommandBlockWrapper = extern struct {
    signature: u32 = 0x43425355,
    tag: u32 = 0,
    data_transfer_length: u32 = 0,
    flags: u8 = 0,
    lun: u8 = 0,
    cb_length: u8 = 0,
    cdb: [16]u8 = [_]u8{0} ** 16,
};

pub const CommandStatusWrapper = extern struct {
    signature: u32 = 0,
    tag: u32 = 0,
    data_residue: u32 = 0,
    status: u8 = 0,
};

pub const UsbStorageDriver = struct {
    slot_id: u8,
    /// Set by the core manager before readDiskCapacity(); needed
    /// for Bulk-Only Mass Storage Reset.
    interface_number: u8 = 0,

    /// xHCI device-context indexes (ep_number
    /// * 2 + IN) used for transfers.
    bulk_in_endpoint_id: u8 = 0,
    bulk_out_endpoint_id: u8 = 0,
    /// USB endpoint addresses (with direction bit) used for
    /// CLEAR_FEATURE(ENDPOINT_HALT).
    bulk_in_address: u8 = 0,
    bulk_out_address: u8 = 0,

    /// Number of logical blocks (last LBA + 1).
    /// Saturates at 0xFFFFFFFF for devices > 2 TB (READ
    /// CAPACITY(10) cannot describe them; this driver uses
    /// 32-bit LBAs anyway).
    block_count: u32 = 0,
    block_size: u32 = 512,
    is_write_protected: bool = false,

    current_tag: u32 = 1,
    xhci_driver: ?*xhci.XhciDriver = null,

    cbw_buffer: CommandBlockWrapper align(64) = .{},
    csw_buffer: CommandStatusWrapper align(64) = .{},
    sense_data: [18]u8 align(16) = [_]u8{0} ** 18,

    pub fn init(slot_id: u8) UsbStorageDriver {
        return .{ .slot_id = slot_id };
    }

    /// `in_ep` / `out_ep` are endpoint addresses
    /// as found in the endpoint descriptors.
    pub fn parseInterface(self: *UsbStorageDriver, class: u8, subclass: u8, protocol: u8, in_ep: u8, out_ep: u8) bool {
        if (class == 0x08 and subclass == 0x06 and protocol == 0x50) {
            self.bulk_in_address = in_ep;
            self.bulk_out_address = out_ep;
            self.bulk_in_endpoint_id = ((in_ep & 0x0F) * 2) + 1;
            self.bulk_out_endpoint_id = ((out_ep & 0x0F) * 2) + 0;
            return true;
        }
        return false;
    }

    pub fn testUnitReady(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        self.xhci_driver = xhci_drv;
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x00;

        var retries: u32 = 20;
        while (retries > 0) : (retries -= 1) {
            if (self.executeScsiTransaction(xhci_drv, &cdb, 6, 0x00, null, 0)) |_| {
                return;
            } else |_| {
                xhci.delayMs(100); // media spin-up / unit attention clears after REQUEST SENSE
            }
        }
        return error.DeviceNotReady;
    }

    pub fn requestSense(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x03;
        cdb[4] = @as(u8, @intCast(self.sense_data.len));

        try self.rawScsiTransaction(xhci_drv, &cdb, 6, 0x80, &self.sense_data, self.sense_data.len);
    }

    pub fn checkWriteProtection(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x1A;
        cdb[2] = 0x3F;
        cdb[4] = 32;

        var mode_buf: [32]u8 align(16) = [_]u8{0} ** 32;
        try self.executeScsiTransaction(xhci_drv, &cdb, 6, 0x80, &mode_buf, mode_buf.len);

        self.is_write_protected = (mode_buf[2] & 0x80) != 0;
    }

    pub fn readDiskCapacity(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        self.xhci_driver = xhci_drv;
        try self.testUnitReady(xhci_drv);
        // MODE SENSE is optional and many flash drives reject it; that
        // must not make the disk unusable.
        self.checkWriteProtection(xhci_drv) catch {};

        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x25;

        var capacity_data: [8]u8 align(16) = [_]u8{0} ** 8;
        try self.executeScsiTransaction(xhci_drv, &cdb, 10, 0x80, &capacity_data, capacity_data.len);

        // READ CAPACITY returns the LAST LBA (not the count) and the
        // block length, big-endian.
        const last_lba = std.mem.readInt(u32, capacity_data[0..4], .big);
        const bs = std.mem.readInt(u32, capacity_data[4..8], .big);
        if (bs == 0) return error.InvalidBlockSize;
        self.block_size = bs;
        self.block_count = if (last_lba == 0xFFFF_FFFF) last_lba else last_lba + 1;
    }

    /// SYNCHRONIZE CACHE (10): the device's write cache
    /// to the medium (before power off).
    /// Devices without a cache may reject it; that is
    /// no error for the caller to act on.
    pub fn syncCache(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x35;
        try self.executeScsiTransaction(xhci_drv, &cdb, 10, 0x00, null, 0);
    }

    /// START STOP UNIT with LoEj: the medium may be
    /// taken out (EJECT). Optional for devices.
    pub fn stopUnit(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver) !void {
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x1B;
        cdb[4] = 0x02; // LoEj, not Start
        try self.executeScsiTransaction(xhci_drv, &cdb, 6, 0x00, null, 0);
    }

    fn checkRange(self: *const UsbStorageDriver, lba: u32, count: u16, buf_len: usize) !void {
        const bytes = @as(usize, count) * self.block_size;
        if (buf_len < bytes) return error.BufferTooSmall;
        if (self.block_count != 0 and @as(u64, lba) + @as(u64, count) > @as(u64, self.block_count)) return error.LbaOutOfRange;
    }

    pub fn readBlocks(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver, lba: u32, count: u16, destination: []u8) !void {
        if (count == 0) return;
        self.xhci_driver = xhci_drv;
        try self.checkRange(lba, count, destination.len);
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x28;

        std.mem.writeInt(u32, cdb[2..6], lba, .big);
        std.mem.writeInt(u16, cdb[7..9], count, .big);

        try self.executeScsiTransaction(xhci_drv, &cdb, 10, 0x80, destination.ptr, @as(usize, count) * self.block_size);
    }

    pub fn writeBlocks(self: *UsbStorageDriver, xhci_drv: *xhci.XhciDriver, lba: u32, count: u16, source: []const u8) !void {
        if (self.is_write_protected) return error.DeviceWriteProtected;
        if (count == 0) return;
        self.xhci_driver = xhci_drv;
        try self.checkRange(lba, count, source.len);
        var cdb = [_]u8{0} ** 16;
        cdb[0] = 0x2A;

        std.mem.writeInt(u32, cdb[2..6], lba, .big);
        std.mem.writeInt(u16, cdb[7..9], count, .big);

        try self.executeScsiTransaction(xhci_drv, &cdb, 10, 0x00, @constCast(source.ptr), @as(usize, count) * self.block_size);
    }

    /// One Bulk-Only Transport transaction: CBW -> optional data ->
    /// CSW, with the recovery procedures from the BOT spec (clear
    /// halt on a stalled data/CSW pipe, reset recovery otherwise).
    fn rawScsiTransaction(
        self: *UsbStorageDriver,
        xhci_driver: *xhci.XhciDriver,
        cdb: *const [16]u8,
        cdb_len: u5,
        direction_flag: u8,
        data_ptr: ?*anyopaque,
        data_len: usize,
    ) !void {
        const tag = self.current_tag;
        self.current_tag +%= 1;

        self.cbw_buffer = .{
            .signature = 0x43425355,
            .tag = tag,
            .data_transfer_length = @as(u32, @intCast(data_len)),
            .flags = direction_flag,
            .lun = 0,
            .cb_length = cdb_len,
            .cdb = cdb.*,
        };

        // 1. Command block
        xhci_driver.submitBulkTransfer(self.slot_id, self.bulk_out_endpoint_id, &self.cbw_buffer, 31) catch |e| {
            self.resetRecovery(xhci_driver);
            return e;
        };

        // 2. Data phase. A device may STALL here (to end a short
        //    transfer): clear the halt and go on to the status:
        if (data_len > 0 and data_ptr != null) {
            const is_in = direction_flag == 0x80;
            const ep_id = if (is_in) self.bulk_in_endpoint_id else self.bulk_out_endpoint_id;
            const ep_addr = if (is_in) self.bulk_in_address else self.bulk_out_address;
            xhci_driver.submitBulkTransfer(self.slot_id, ep_id, data_ptr.?, data_len) catch |e| switch (e) {
                error.TransferStall => self.clearHalt(xhci_driver, ep_addr),
                else => {
                    self.resetRecovery(xhci_driver);
                    return e;
                },
            };
        }

        // 3. Status phase; after a stall, clear
        // the halt and read the CSW once more.
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            @memset(std.mem.asBytes(&self.csw_buffer), 0);
            xhci_driver.submitBulkTransfer(self.slot_id, self.bulk_in_endpoint_id, &self.csw_buffer, 13) catch |e| {
                if (e == error.TransferStall and attempt == 0) {
                    self.clearHalt(xhci_driver, self.bulk_in_address);
                    continue;
                }
                self.resetRecovery(xhci_driver);
                return e;
            };
            break;
        }

        if (self.csw_buffer.signature != 0x53425355) {
            self.resetRecovery(xhci_driver);
            return error.UsbBotStatusSignatureMismatch;
        }
        if (self.csw_buffer.tag != tag) {
            self.resetRecovery(xhci_driver);
            return error.UsbBotStatusTagMismatch;
        }
    }

    fn executeScsiTransaction(
        self: *UsbStorageDriver,
        xhci_driver: *xhci.XhciDriver,
        cdb: *const [16]u8,
        cdb_len: u5,
        direction_flag: u8,
        data_ptr: ?*anyopaque,
        data_len: usize,
    ) !void {
        try self.rawScsiTransaction(xhci_driver, cdb, cdb_len, direction_flag, data_ptr, data_len);

        switch (self.csw_buffer.status) {
            0 => return,
            1 => {
                // Command failed: fetch sense data (this
                // also clears a pending unit attention).
                self.requestSense(xhci_driver) catch {};
                return error.ScsiCommandExecutionFailed;
            },
            else => {
                self.resetRecovery(xhci_driver);
                return error.UsbBotPhaseError;
            },
        }
    }

    /// CLEAR_FEATURE(ENDPOINT_HALT).
    /// wIndex is the endpoint ADDRESS (e.g.
    /// 0x81), not the xHCI context index.
    /// (The xHC side of the stall is already
    /// reset by the xHCI driver.)
    fn clearHalt(self: *UsbStorageDriver, xhci_driver: *xhci.XhciDriver, endpoint_address: u8) void {
        xhci_driver.executeControlTransfer(self.slot_id, 0x02, 0x01, 0, endpoint_address, null, 0) catch {};
    }

    /// Bulk-Only Mass Storage Reset +
    /// clear both halts (BOT spec 5.3.4).
    fn resetRecovery(self: *UsbStorageDriver, xhci_driver: *xhci.XhciDriver) void {
        xhci_driver.executeControlTransfer(self.slot_id, 0x21, 0xFF, 0, self.interface_number, null, 0) catch {};
        self.clearHalt(xhci_driver, self.bulk_in_address);
        self.clearHalt(xhci_driver, self.bulk_out_address);
    }

    pub fn zdosRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) !void {
        const self: *UsbStorageDriver = @ptrCast(@alignCast(@constCast(ctx)));
        const drv = self.xhci_driver orelse return error.DriverNotConfigured;
        if (buf.len < count * self.block_size) return error.BufferTooSmall;
        if (lba + @as(u64, count) > 0x1_0000_0000) return error.LbaOutOfRange; // 32-bit LBAs (READ(10))
        var remaining = count;
        var cur_lba: u64 = lba;
        var offset: usize = 0;
        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, 64));
            const byte_len = @as(usize, chunk) * self.block_size;
            try self.readBlocks(drv, @intCast(cur_lba), chunk, buf[offset .. offset + byte_len]);
            remaining -= chunk;
            cur_lba += chunk;
            offset += byte_len;
        }
    }

    pub fn zdosWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) !void {
        const self: *UsbStorageDriver = @ptrCast(@alignCast(@constCast(ctx)));
        const drv = self.xhci_driver orelse return error.DriverNotConfigured;
        if (data.len < count * self.block_size) return error.BufferTooSmall;
        if (lba + @as(u64, count) > 0x1_0000_0000) return error.LbaOutOfRange;
        var remaining = count;
        var cur_lba: u64 = lba;
        var offset: usize = 0;
        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, 64));
            const byte_len = @as(usize, chunk) * self.block_size;
            try self.writeBlocks(drv, @intCast(cur_lba), chunk, data[offset .. offset + byte_len]);
            remaining -= chunk;
            cur_lba += chunk;
            offset += byte_len;
        }
    }

    pub const ZdosBlockDevice = struct {
        ctx: *const anyopaque,
        read: *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void,
        write: *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) anyerror!void,
    };

    pub fn asZdosDevice(self: *UsbStorageDriver) ZdosBlockDevice {
        return .{
            .ctx = self,
            .read = zdosRead,
            .write = zdosWrite,
        };
    }
};
