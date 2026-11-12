//! virtio-blk, after Minix 3's virtio_blk: one request at a
//! time on the one queue: a header, the data and a status byte.

const virtio = @import("virtio.zig");

const f_size_max: u64 = 1 << 1;
const f_seg_max: u64 = 1 << 2;
const f_ro: u64 = 1 << 5;
const f_blk_size: u64 = 1 << 6;
const f_flush: u64 = 1 << 9;

const t_in: u32 = 0;
const t_out = 1;
const t_flush = 4;

const max_segments = 16;

// Pages the driver needs: the queue, then the header and status
pub const pages = virtio.Queue.pages + 1;

const Header = extern struct { kind: u32, reserved: u32, sector: u64 };

pub const Error = virtio.Error || error{ DeviceError, DeviceTimeout };

pub const Blk = struct {
    dev: virtio.Device,
    q: virtio.Queue = undefined,
    header: *volatile Header = undefined,
    status: *volatile u8 = undefined,
    block_size: u32 = 512,
    blocks: u64 = 0, // of block_size
    read_only: bool = false,
    segments: u16 = 1, // data descriptors a request may have
    segment_bytes: u32 = 64 * 1024,
    broken: bool = false, // a request timed out: the descriptors may still be the device's
    delay_us: *const fn (u32) void = undefined,
    // Once tasks switch: waits for the
    // queue's interrupt (as nvme.zig's)
    wait_hook: ?*const fn (ctx: *anyopaque) u32 = null,
    wait_ctx: ?*anyopaque = null,

    pub fn irq(self: *const Blk) bool {
        return self.q.irq;
    }

    // mem: `pages` pages; vector: the queue's
    // MSI-X entry (or virtio.no_vector)
    pub fn init(self: *Blk, mem: [*]align(4096) u8, delay_us: *const fn (u32) void, vector: u16) Error!void {
        self.delay_us = delay_us;
        try self.dev.begin(f_size_max | f_seg_max | f_ro | f_blk_size | f_flush, delay_us);
        errdefer self.dev.fail();
        try self.dev.setupQueue(&self.q, 0, mem, virtio.Queue.max_size, vector);
        const page = mem + virtio.Queue.pages * 4096;
        self.header = @ptrCast(@alignCast(page));
        self.status = @ptrCast(page + 64);

        const sectors = self.dev.config(u64, 0); // always of 512 bytes
        if (self.dev.has(f_blk_size)) {
            const bs = self.dev.config(u32, 20);
            if (bs >= 512 and bs <= 64 * 1024 and bs & (bs - 1) == 0) self.block_size = bs;
        }
        self.blocks = sectors / (self.block_size / 512);
        self.read_only = self.dev.has(f_ro);
        // Header and status take two descriptors
        var segs: u32 = @min(max_segments, self.q.size - 2);
        if (self.dev.has(f_seg_max)) segs = @min(segs, @max(self.dev.config(u32, 12), 1));
        self.segments = @intCast(segs);
        if (self.dev.has(f_size_max)) {
            const m = self.dev.config(u32, 8);
            if (m >= self.block_size) self.segment_bytes = @min(self.segment_bytes, m / self.block_size * self.block_size);
        }
        self.dev.ready();
    }

    pub fn read(self: *Blk, lba: u64, count: usize, buf: []u8) Error!void {
        return self.transfer(t_in, lba, count, buf);
    }

    pub fn write(self: *Blk, lba: u64, count: usize, buf: []u8) Error!void {
        if (self.read_only) return error.DeviceError;
        return self.transfer(t_out, lba, count, buf);
    }

    // The device's write cache to the
    // medium (if it has one it tells of)
    pub fn flush(self: *Blk) Error!void {
        if (!self.dev.has(f_flush)) return;
        return self.request(t_flush, 0, &.{});
    }

    fn transfer(self: *Blk, kind: u32, lba: u64, count: usize, buf: []u8) Error!void {
        const bs: usize = self.block_size;
        const most = @as(usize, self.segments) * self.segment_bytes / bs;
        var done: usize = 0;
        while (done < count) {
            const n = @min(count - done, most);
            try self.request(kind, (lba + done) * (bs / 512), buf[done * bs ..][0 .. n * bs]);
            done += n;
        }
    }

    fn request(self: *Blk, kind: u32, sector: u64, data: []u8) Error!void {
        if (self.broken) return error.DeviceError;
        self.header.* = .{ .kind = kind, .reserved = 0, .sector = sector };
        self.status.* = 0xFF;
        const d = self.q.desc;
        d[0] = .{ .addr = @intFromPtr(self.header), .len = @sizeOf(Header), .flags = virtio.desc_next, .next = 1 };
        var i: u16 = 1;
        var off: usize = 0;
        while (off < data.len) : (i += 1) {
            const len = @min(data.len - off, self.segment_bytes);
            d[i] = .{
                .addr = @intFromPtr(data.ptr + off),
                .len = @intCast(len),
                .flags = if (kind == t_in) virtio.desc_next | virtio.desc_write else virtio.desc_next,
                .next = i + 1,
            };
            off += len;
        }
        d[i] = .{ .addr = @intFromPtr(self.status), .len = 1, .flags = virtio.desc_write, .next = 0 };
        self.q.offer(0);
        self.q.kick();

        var waited: u64 = 0;
        while (self.q.take() == null) {
            if (waited > 30_000_000) {
                self.broken = true;
                return error.DeviceTimeout;
            }
            if (self.wait_hook) |hook| {
                waited += hook(self.wait_ctx.?);
            } else {
                self.delay_us(5);
                waited += 5;
            }
        }
        virtio.barrier();
        if (self.status.* != 0) return error.DeviceError;
    }
};
