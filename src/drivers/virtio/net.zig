//! virtio-net, after Minix 3's virtio_net: one receive and one
//! transmit queue, each descriptor a fixed 2 KiB buffer (the
//! 12-byte virtio header, then the frame).

const virtio = @import("virtio.zig");

const f_mac: u64 = 1 << 5;
const f_status: u64 = 1 << 16;
const f_ctrl_vq: u64 = 1 << 17;
const f_ctrl_rx: u64 = 1 << 18;

const header_len = 12; // virtio_net_hdr with num_buffers (VERSION_1)
const buf_size = 2048;
pub const rx_max = 128;
pub const tx_max = 64;

// Pages the driver needs: three
// queues, the control page, the buffers
pub const pages = 3 * virtio.Queue.pages + 1 + (rx_max + tx_max) * buf_size / 4096;

pub const Net = struct {
    dev: virtio.Device,
    mac: [6]u8 = undefined,
    rx: virtio.Queue = undefined,
    tx: virtio.Queue = undefined,
    ctrl: ?virtio.Queue = null,
    ctrl_page: [*]u8 = undefined,
    rx_bufs: [*]u8 = undefined,
    tx_bufs: [*]u8 = undefined,
    tx_busy: [tx_max]bool = @splat(false),
    tx_next: u16 = 0,
    delay_us: *const fn (u32) void = undefined,

    pub fn irq(self: *const Net) bool {
        return self.rx.irq;
    }

    // mem: `pages` pages; vector: the receive queue's MSI-X
    // entry (or virtio.no_vector). Sent frames are taken back as
    // more are sent: no interrupt for them.
    pub fn init(self: *Net, mem: [*]align(4096) u8, delay_us: *const fn (u32) void, vector: u16) virtio.Error!void {
        self.delay_us = delay_us;
        try self.dev.begin(f_mac | f_status | f_ctrl_vq | f_ctrl_rx, delay_us);
        errdefer self.dev.fail();
        const q_bytes = virtio.Queue.pages * 4096;
        try self.dev.setupQueue(&self.rx, 0, mem, rx_max, vector);
        try self.dev.setupQueue(&self.tx, 1, mem + q_bytes, tx_max, virtio.no_vector);
        if (self.dev.has(f_ctrl_vq) and self.dev.has(f_ctrl_rx)) {
            var q: virtio.Queue = undefined;
            if (self.dev.setupQueue(&q, 2, mem + 2 * q_bytes, 4, virtio.no_vector)) |_| {
                self.ctrl = q;
            } else |_| {}
        }
        self.ctrl_page = mem + 3 * q_bytes;
        self.rx_bufs = self.ctrl_page + 4096;
        self.tx_bufs = self.rx_bufs + rx_max * buf_size;

        if (self.dev.has(f_mac)) {
            for (&self.mac, 0..) |*b, i| b.* = self.dev.config(u8, i);
        } else {
            self.mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x57 }; // locally administered
        }

        for (0..self.rx.size) |i| {
            self.rx.desc[i] = .{ .addr = @intFromPtr(self.rx_bufs + i * buf_size), .len = buf_size, .flags = virtio.desc_write, .next = 0 };
            self.rx.offer(@intCast(i));
        }
        for (0..self.tx.size) |i| {
            self.tx.desc[i] = .{ .addr = @intFromPtr(self.tx_bufs + i * buf_size), .len = 0, .flags = 0, .next = 0 };
        }
        self.dev.ready();
        self.rx.kick();
    }

    pub fn linkUp(self: *const Net) bool {
        if (!self.dev.has(f_status)) return true;
        return self.dev.config(u16, 6) & 1 != 0;
    }

    pub fn send(self: *Net, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > buf_size - header_len) return false;
        while (self.tx.take()) |u| self.tx_busy[u.id] = false;
        const i = self.tx_next;
        if (self.tx_busy[i]) return false; // the queue is full
        const buf = self.tx_bufs + @as(usize, i) * buf_size;
        @memset(buf[0..header_len], 0);
        @memcpy(buf[header_len..][0..frame.len], frame);
        self.tx.desc[i].len = @intCast(header_len + frame.len);
        self.tx_busy[i] = true;
        self.tx_next = (i + 1) % self.tx.size;
        self.tx.offer(i);
        self.tx.kick();
        return true;
    }

    // One received frame into buf (its length), null if none waits;
    // one too long for buf is dropped
    pub fn receive(self: *Net, buf: []u8) ?usize {
        while (self.rx.take()) |u| {
            const len: usize = if (u.len > header_len) @min(u.len, buf_size) - header_len else 0;
            const ok = len != 0 and len <= buf.len;
            if (ok) @memcpy(buf[0..len], (self.rx_bufs + @as(usize, u.id) * buf_size + header_len)[0..len]);
            self.rx.offer(u.id);
            self.rx.kick();
            if (ok) return len;
        }
        return null;
    }

    // Every frame, not only its own address's (the control queue's
    // VIRTIO_NET_CTRL_RX_PROMISC); false if the device can't
    pub fn promiscuous(self: *Net) bool {
        if (self.ctrl == null) return false;
        const q = &self.ctrl.?;
        const p = self.ctrl_page;
        p[0] = 0; // class: RX
        p[1] = 0; // command: PROMISC
        p[2] = 1; // on
        p[3] = 0xFF; // the ack
        q.desc[0] = .{ .addr = @intFromPtr(p), .len = 2, .flags = virtio.desc_next, .next = 1 };
        q.desc[1] = .{ .addr = @intFromPtr(p + 2), .len = 1, .flags = virtio.desc_next, .next = 2 };
        q.desc[2] = .{ .addr = @intFromPtr(p + 3), .len = 1, .flags = virtio.desc_write, .next = 0 };
        q.offer(0);
        q.kick();
        for (0..100_000) |_| {
            if (q.take() != null) {
                virtio.barrier();
                return @as(*volatile u8, @ptrCast(p + 3)).* == 0;
            }
            self.delay_us(10);
        }
        self.ctrl = null; // no answer: not asked again
        return false;
    }
};
