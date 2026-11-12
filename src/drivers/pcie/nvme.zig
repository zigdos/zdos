//! NVMe: PRP lists, namespaces, several I/O queues, optional
//! MSI-X.

const std = @import("std");
const builtin = @import("builtin");

// Physical address hook (identity by default)
pub var virtualToPhysicalFn: *const fn (virtual_address: usize) u64 = defaultVirtualToPhysical;

pub fn defaultVirtualToPhysical(virtual_address: usize) u64 {
    return @as(u64, virtual_address);
}

inline fn virtToPhys(va: usize) u64 {
    return virtualToPhysicalFn(va);
}

inline fn cpuRelax() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("pause" ::: "memory");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("yield" ::: "memory");
    } else {
        asm volatile ("" ::: "memory");
    }
}

const read32 = @import("../../arch/mmio.zig").load32; // full width: never narrowed

/// Replace with a timer-based delay (default: a rough spin).
/// Used for the controller's ready/reset waits, whose limit the
/// controller states itself (CAP.TO).
pub var delayUsFn: *const fn (us: u32) void = defaultDelayUs;

pub fn defaultDelayUs(us: u32) void {
    var i: u32 = 0;
    while (i < us * 100) : (i += 1) cpuRelax();
}

inline fn memoryBarrier() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("dmb sy" ::: "memory");
    } else {
        asm volatile ("" ::: "memory");
    }
}

// NVMe Controller Memory-Mapped (MMIO) Registers
pub const ControllerRegisters = extern struct {
    cap: u64, // Controller Capabilities
    vs: u32, // Version
    intms: u32, // Interrupt Mask Set
    intmc: u32, // Interrupt Mask Clear
    cc: u32, // Controller Configuration
    reserved1: u32,
    csts: u32, // Controller Status
    nssr: u32, // NVM Subsystem Reset (Optional)
    aqa: u32, // Admin Queue Attributes
    asq: u64, // Admin Submission Queue Base Address
    acq: u64, // Admin Completion Queue Base Address
    cmbloc: u32, // Controller Memory Buffer Location (Optional)
    cmbsz: u32, // Controller Memory Buffer Size (Optional)
};

// NVMe Queue Command / Status
// Structures (Fixed Hardware Layouts)
/// 64-byte NVMe Submission Queue Entry (SQE)
pub const NvmeCmd = extern struct {
    opcode: u8 = 0,
    flags: u8 = 0,
    command_id: u16 = 0, // Unique identifier for matching completions
    nsid: u32 = 0, // Namespace Identifier
    reserved1: u64 = 0,
    mptr: u64 = 0, // Metadata Pointer (Unused for standard block I/O)
    prp1: u64 = 0, // Physical Region Page 1
    prp2: u64 = 0, // Physical Region Page 2 (or PRP List physical address)
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,

    pub const zero: NvmeCmd = .{};
};

/// 16-byte NVMe Completion Queue Entry (CQE)
pub const NvmeCqe = extern struct {
    result: u32 = 0, // Command-specific result data
    reserved: u32 = 0,
    sq_head: u16 = 0, // SQ head pointer
    sq_id: u16 = 0, // ID of the submission queue that issued the command
    command_id: u16 = 0, // Matches the command_id in the original NvmeCmd
    status: u16 = 0, // Bit 0: Phase Tag (P), Bits 1-15: Error/Status codes
};

pub const MaxIoQueues = 4;
pub const QueueEntries = 64;

pub const NvmeDriver = struct {
    regs: *volatile ControllerRegisters,
    doorbells: [*]volatile u32,
    db_stride: u8 = 0,

    // Active disk capacities & geometry
    total_blocks: u64 = 0,
    block_size: u32 = 512,
    num_namespaces: u32 = 1,
    active_nsid: u32 = 1,

// Admin queues
    admin_sq: [QueueEntries]NvmeCmd align(4096) = [_]NvmeCmd{NvmeCmd.zero} ** QueueEntries,
    admin_cq: [QueueEntries]NvmeCqe align(4096) = [_]NvmeCqe{.{}} ** QueueEntries,

    admin_sq_tail: u16 = 0,
    admin_cq_head: u16 = 0,
    admin_phase: u1 = 1,
    cmd_id_counter: u16 = 1,
    /// DW0 of the most recent admin completion (e.g.
    /// Set Features: Number of Queues).
    last_admin_result: u32 = 0,
    /// Largest transfer one command may carry (Identify Controller
    /// MDTS, capped by our static PRP list).
    max_transfer_bytes: usize = 128 * 1024,
    max_blocks_per_cmd: u32 = 128,

// I/O queue pairs
    io_sqs: [MaxIoQueues][QueueEntries]NvmeCmd align(4096) = [_][QueueEntries]NvmeCmd{[_]NvmeCmd{NvmeCmd.zero} ** QueueEntries} ** MaxIoQueues,
    io_cqs: [MaxIoQueues][QueueEntries]NvmeCqe align(4096) = [_][QueueEntries]NvmeCqe{[_]NvmeCqe{.{}} ** QueueEntries} ** MaxIoQueues,

    io_sq_tails: [MaxIoQueues]u16 = [_]u16{0} ** MaxIoQueues,
    io_cq_heads: [MaxIoQueues]u16 = [_]u16{0} ** MaxIoQueues,
    io_phases: [MaxIoQueues]u1 = [_]u1{1} ** MaxIoQueues,
    configured_io_queues: u8 = 1,
    io_queue_rr_counter: u8 = 0,

// PRP list for transfers over 2 pages
    prp_list: [512]u64 align(4096) = [_]u64{0} ** 512,

    // MSI-X: the OS programs the MSI-X table and installs a handler
    // before setting this and calling setupAndStart().
    msix_enabled: bool = false,
    msix_vector_base: u16 = 0,

    // Completion records, indexed by command_id % QueueEntries (at
    // most one command in flight per I/O queue):
    // the ISR publishes, the waiter consumes.
    io_completion_status: [MaxIoQueues][QueueEntries]u16 = [_][QueueEntries]u16{[_]u16{0} ** QueueEntries} ** MaxIoQueues,
    io_completion_ready: [MaxIoQueues][QueueEntries]bool = [_][QueueEntries]bool{[_]bool{false} ** QueueEntries} ** MaxIoQueues,

    // Optional hook (MSI-X mode) that blocks until the
    // completion is signaled; without it, a bounded pause loop.
    completion_wait_context: ?*anyopaque = null,
    completion_wait_hook: ?*const fn (context: *anyopaque, qid: u16, command_id: u16) void = null,

    // Polled completions that wake on an interrupt:
    // cq_irq creates the I/O CQs with interrupts on (MSI-X
    // entry 0, programmed by the OS); wait_hook, if set,
    // replaces the pause while a command runs and returns about
    // how many microseconds passed.
    cq_irq: bool = false,
    wait_hook: ?*const fn (ctx: *anyopaque) u32 = null,
    wait_ctx: ?*anyopaque = null,

    pub fn init(pci_bar0_address: usize) NvmeDriver {
        const regs_ptr = @as(*volatile ControllerRegisters, @ptrFromInt(pci_bar0_address));
        const db_ptr = @as([*]volatile u32, @ptrFromInt(pci_bar0_address + 0x1000));

        const cap_value = regs_ptr.cap;
        const stride_shift = @as(u8, @intCast((cap_value >> 32) & 0xF));

        return .{
            .regs = regs_ptr,
            .doorbells = db_ptr,
            .db_stride = stride_shift,
        };
    }

    /// Request interrupt-driven I/O completions. The kernel
    /// programs MSI-X and installs handlers first.
    /// Admin completions stay polled.
    pub fn enableMsix(self: *NvmeDriver, enabled: bool) void {
        self.msix_enabled = enabled;
    }

    /// Install a hook for interrupt-mode waits: it blocks until
    /// `handleIoInterrupt` publishes the completion and must
    /// tolerate spurious wakeups. null: bounded pause loop.
    pub fn setCompletionWaitHook(
        self: *NvmeDriver,
        context: ?*anyopaque,
        hook: ?*const fn (context: *anyopaque, qid: u16, command_id: u16) void,
    ) void {
        self.completion_wait_context = context;
        self.completion_wait_hook = hook;
    }

    pub fn configureMsix(self: *NvmeDriver, enabled: bool, first_vector: u16) !void {
        if (enabled) {
            if (self.configured_io_queues == 0 or self.configured_io_queues > MaxIoQueues)
                return error.InvalidMsixVectorConfiguration;
            const last_vector = @as(u32, first_vector) + @as(u32, self.configured_io_queues) - 1;
            if (last_vector > 0xFFFF) return error.InvalidMsixVectorConfiguration;
        }
        self.msix_vector_base = first_vector;
        self.msix_enabled = enabled;
    }

    /// From the OS's MSI-X handler for I/O queue `qid`
    /// (1..configured_io_queues, not the CPU vector): drains the
    /// CQ, publishes status, rings the CQ doorbell.
    pub fn handleIoInterrupt(self: *NvmeDriver, qid: u16) void {
        if (qid == 0 or qid > self.configured_io_queues or qid > MaxIoQueues) return;
        const q_idx = @as(usize, qid - 1);
        var consumed = false;
        // At most a queue's worth: the
        // interrupt handler's work is bounded
        var n: usize = 0;
        while (n < QueueEntries) : (n += 1) {
            const head = self.io_cq_heads[q_idx];
            const cqp: *volatile NvmeCqe = &self.io_cqs[q_idx][head];
            const st = cqp.status;
            const phase: u1 = @truncate(st & 1);
            if (phase != self.io_phases[q_idx]) break;

            memoryBarrier();
            const slot = @as(usize, cqp.command_id) % QueueEntries;
            self.io_completion_status[q_idx][slot] = st & ~@as(u16, 1);
            memoryBarrier();
            self.io_completion_ready[q_idx][slot] = true;

            self.io_cq_heads[q_idx] = (head + 1) % QueueEntries;
            if (self.io_cq_heads[q_idx] == 0) self.io_phases[q_idx] ^= 1;
            consumed = true;
        }

        if (consumed) {
            memoryBarrier();
            const shift: std.math.Log2Int(usize) = @truncate(self.db_stride);
            const cq_db_idx = ((@as(usize, 2) * qid) + 1) << shift;
            self.doorbells[cq_db_idx] = self.io_cq_heads[q_idx];
        }
    }

    fn getNewCmdId(self: *NvmeDriver) u16 {
        const id = self.cmd_id_counter;
        self.cmd_id_counter = if (self.cmd_id_counter == 0xFFFF) 1 else self.cmd_id_counter + 1;
        return id;
    }

    pub fn setupAndStart(self: *NvmeDriver) !void {
        if (self.configured_io_queues == 0 or self.configured_io_queues > MaxIoQueues)
            return error.InvalidIoQueueCount;

        // CAP.TO: how long CSTS.RDY may take to change, in 500 ms units
        const cap = self.regs.cap;
        const ready_ms: u32 = @max(@as(u32, @intCast((cap >> 24) & 0xFF)) * 500, 500);

        // 1. Disable controller to reset internal state cleanly
        const cc = read32(&self.regs.cc);
        if ((cc & 1) != 0) self.regs.cc = cc & ~@as(u32, 1);
        if (!self.waitReady(false, ready_ms)) return error.ControllerResetTimeout;

        // Capability checks: queue depth, NVM
        // command set, 4 KB minimum page size.
        const mqes: u32 = @intCast(cap & 0xFFFF); // zero-based
        if (mqes + 1 < QueueEntries) return error.ControllerQueueSizeTooSmall;
        if (((cap >> 37) & 1) == 0) return error.NvmCommandSetNotSupported;
        if (((cap >> 48) & 0xF) != 0) return error.UnsupportedMinimumPageSize;

        // A controller reset zeroes all queue pointers, so start from a
        // clean software state too (this also makes calling
        // setupAndStart() again safe).
        @memset(std.mem.asBytes(&self.admin_cq), 0);
        @memset(std.mem.asBytes(&self.io_cqs), 0);
        @memset(std.mem.asBytes(&self.io_completion_ready), 0);
        self.admin_sq_tail = 0;
        self.admin_cq_head = 0;
        self.admin_phase = 1;
        @memset(&self.io_sq_tails, 0);
        @memset(&self.io_cq_heads, 0);
        @memset(&self.io_phases, 1);
        self.io_queue_rr_counter = 0;

        // Polled mode: mask pin-based/MSI interrupts so an unhandled
        // one can't fire. (INTMS/INTMC must
        // not be used when MSI-X is in use.)
        if (!self.msix_enabled and !self.cq_irq) self.regs.intms = 0xFFFF_FFFF;

        // 2. Admin queue sizes, 0-based (63 means 64 entries):
        self.regs.aqa = ((QueueEntries - 1) << 16) | (QueueEntries - 1);

        // 3. Program physical Base addresses for Admin Rings
        self.regs.asq = virtToPhys(@intFromPtr(&self.admin_sq));
        self.regs.acq = virtToPhys(@intFromPtr(&self.admin_cq));

        // 4. CC: EN[0], CSS[6:4]=0 (NVM), MPS[10:7]=0 (4 KB),
        //    AMS[13:11]=0 (round robin), IOSQES[19:16]=6 (64-byte
        //    SQE), IOCQES[23:20]=4 (16-byte CQE). Bit 16 is not the
        //    command set: IOSQES/IOCQES at 0 make the controller
        //    refuse to enable, or reject the I/O queues:
        const cc_config: u32 = 1 | (0 << 4) | (0 << 7) | (0 << 11) | (6 << 16) | (4 << 20);

        self.regs.cc = cc_config;
        if (!self.waitReady(true, ready_ms)) return error.ControllerEnableTimeout;

        // 5. Query Controller and Namespace Identify info
        try self.identifyControllerAndNamespaces();

        // 5b. Negotiate the number of I/O queues,
        // then never ask for more than were granted.
        {
            var sf = NvmeCmd.zero;
            sf.opcode = 0x09; // Set Features
            sf.command_id = self.getNewCmdId();
            sf.cdw10 = 0x07; // FID = Number of Queues
            const want: u32 = @as(u32, self.configured_io_queues) - 1; // zero-based
            sf.cdw11 = (want << 16) | want; // NCQR | NSQR
            try self.submitAdminCommand(sf);
            const granted_sq: u32 = (self.last_admin_result & 0xFFFF) + 1;
            const granted_cq: u32 = (self.last_admin_result >> 16) + 1;
            const granted: u32 = @min(granted_sq, granted_cq);
            if (granted < self.configured_io_queues) self.configured_io_queues = @intCast(granted);
        }

        // 6. Create Multiple I/O Queue Pairs
        // (configured_io_queues pairs, QID 1 to N)
        var qid: u16 = 1;
        while (qid <= self.configured_io_queues) : (qid += 1) {
            const idx = @as(usize, qid - 1);

            var create_cq = NvmeCmd.zero;
            create_cq.opcode = 0x05; // Create I/O Completion Queue
            create_cq.command_id = self.getNewCmdId();
            create_cq.prp1 = virtToPhys(@intFromPtr(&self.io_cqs[idx]));
            create_cq.cdw10 = ((QueueEntries - 1) << 16) | @as(u32, qid);
            // PC=1. If the OS has configured MSI-X, enable this CQ's
            // interrupt and select its MSI-X table entry in IV[31:16].
            create_cq.cdw11 = 1;
            if (self.msix_enabled) {
                const vector = @as(u32, self.msix_vector_base) + @as(u32, qid - 1);
                if (vector > 0xFFFF) return error.InvalidMsixVectorConfiguration;
                create_cq.cdw11 |= (1 << 1) | (vector << 16); // IEN=1, IV=vector
            } else if (self.cq_irq) {
                create_cq.cdw11 |= 1 << 1; // IEN=1, IV=0
            }
            try self.submitAdminCommand(create_cq);

            var create_sq = NvmeCmd.zero;
            create_sq.opcode = 0x01; // Create I/O Submission Queue
            create_sq.command_id = self.getNewCmdId();
            create_sq.prp1 = virtToPhys(@intFromPtr(&self.io_sqs[idx]));
            create_sq.cdw10 = ((QueueEntries - 1) << 16) | @as(u32, qid);
            create_sq.cdw11 = (@as(u32, qid) << 16) | 1; // CQID = qid, PC = 1 (Contiguous)
            try self.submitAdminCommand(create_sq);
        }
    }

    /// Wait until CSTS.RDY is `ready`, up to `ms` milliseconds;
    /// false on CSTS.CFS (fatal) or timeout.
    fn waitReady(self: *NvmeDriver, ready: bool, ms: u32) bool {
        var t: u32 = 0;
        while (t < ms * 10) : (t += 1) {
            const csts = read32(&self.regs.csts);
            if ((csts & 2) != 0) return false; // controller fatal status
            if (((csts & 1) != 0) == ready) return true;
            delayUsFn(100);
        }
        return false;
    }

    /// Flush: the controller's volatile write
    /// cache to the medium (before power off).
    pub fn flush(self: *NvmeDriver) !void {
        var cmd = NvmeCmd.zero;
        cmd.opcode = 0x00; // Flush
        cmd.command_id = self.getNewCmdId();
        cmd.nsid = self.active_nsid;
        try self.submitIoCommand(1, cmd);
    }

    fn setupPrps(self: *NvmeDriver, virt_addr: usize, byte_len: usize, prp1: *u64, prp2: *u64) !void {
        if ((virt_addr & 3) != 0) return error.MisalignedBuffer; // PRP offset bits 1:0 must be 0
        const page_offset = virt_addr & 0xFFF;
        const first_page_bytes = @min(byte_len, 4096 - page_offset);
        prp1.* = virtToPhys(virt_addr);

        if (byte_len <= first_page_bytes) {
            prp2.* = 0;
            return;
        }

        const remaining_bytes = byte_len - first_page_bytes;
        if (remaining_bytes <= 4096) {
            const second_va = (virt_addr & ~@as(usize, 0xFFF)) + 4096;
            prp2.* = virtToPhys(second_va);
            return;
        }

        // Multi-page transfer requiring a PRP List (> 2 pages)
        var rem = remaining_bytes;
        var cur_va = (virt_addr & ~@as(usize, 0xFFF)) + 4096;
        var idx: usize = 0;
        while (rem > 0 and idx < 512) {
            self.prp_list[idx] = virtToPhys(cur_va);
            idx += 1;
            cur_va += 4096;
            rem = if (rem > 4096) rem - 4096 else 0;
        }

        if (rem > 0) return error.TransferSizeExceedsStaticPrpCapacity;

        prp2.* = virtToPhys(@intFromPtr(&self.prp_list));
    }

    pub fn readBlocks(self: *NvmeDriver, lba: u64, count: u16, destination: []u8) !void {
        if (count == 0) return;
        if (self.configured_io_queues == 0 or self.configured_io_queues > MaxIoQueues) return error.InvalidIoQueueCount;
        const byte_len = std.math.mul(usize, @as(usize, count), self.block_size) catch return error.TransferSizeOverflow;
        if (destination.len < byte_len) return error.BufferTooSmall;
        if (byte_len > self.max_transfer_bytes) return error.TransferTooLarge;
        if (lba >= self.total_blocks or @as(u64, count) > self.total_blocks - lba) return error.LbaOutOfRange;
        const cmd_id = self.getNewCmdId();

        var prp1: u64 = 0;
        var prp2: u64 = 0;
        try self.setupPrps(@intFromPtr(destination.ptr), byte_len, &prp1, &prp2);

        var cmd = NvmeCmd.zero;
        cmd.opcode = 0x02; // Read
        cmd.command_id = cmd_id;
        cmd.nsid = self.active_nsid;
        cmd.prp1 = prp1;
        cmd.prp2 = prp2;

        cmd.cdw10 = @as(u32, @intCast(lba & 0xFFFFFFFF));
        cmd.cdw11 = @as(u32, @intCast((lba >> 32) & 0xFFFFFFFF));
        cmd.cdw12 = @as(u32, @intCast(count - 1)); // 0-based value

        // Round-robin over the I/O queues
        const target_qid = @as(u16, self.io_queue_rr_counter) + 1;
        self.io_queue_rr_counter = @as(u8, @intCast((@as(u16, self.io_queue_rr_counter) + 1) % self.configured_io_queues));

        try self.submitIoCommand(target_qid, cmd);
    }

    pub fn writeBlocks(self: *NvmeDriver, lba: u64, count: u16, source: []const u8) !void {
        if (count == 0) return;
        if (self.configured_io_queues == 0 or self.configured_io_queues > MaxIoQueues) return error.InvalidIoQueueCount;
        const byte_len = std.math.mul(usize, @as(usize, count), self.block_size) catch return error.TransferSizeOverflow;
        if (source.len < byte_len) return error.BufferTooSmall;
        if (byte_len > self.max_transfer_bytes) return error.TransferTooLarge;
        if (lba >= self.total_blocks or @as(u64, count) > self.total_blocks - lba) return error.LbaOutOfRange;
        const cmd_id = self.getNewCmdId();

        var prp1: u64 = 0;
        var prp2: u64 = 0;
        try self.setupPrps(@intFromPtr(source.ptr), byte_len, &prp1, &prp2);

        var cmd = NvmeCmd.zero;
        cmd.opcode = 0x01; // Write
        cmd.command_id = cmd_id;
        cmd.nsid = self.active_nsid;
        cmd.prp1 = prp1;
        cmd.prp2 = prp2;

        cmd.cdw10 = @as(u32, @intCast(lba & 0xFFFFFFFF));
        cmd.cdw11 = @as(u32, @intCast((lba >> 32) & 0xFFFFFFFF));
        cmd.cdw12 = @as(u32, @intCast(count - 1)); // 0-based value

        // Round-robin over the I/O queues
        const target_qid = @as(u16, self.io_queue_rr_counter) + 1;
        self.io_queue_rr_counter = @as(u8, @intCast((@as(u16, self.io_queue_rr_counter) + 1) % self.configured_io_queues));

        try self.submitIoCommand(target_qid, cmd);
    }

    fn submitAdminCommand(self: *NvmeDriver, cmd: NvmeCmd) !void {
        const tail = self.admin_sq_tail;

        // One entry stays empty: full when tail + 1 == head
        const next_tail = (tail + 1) % QueueEntries;
        if (next_tail == self.admin_cq_head) return error.AdminQueueFull;

        self.admin_sq[tail] = cmd;
        self.admin_sq_tail = next_tail;

        memoryBarrier();

        const sq0_doorbell_idx = 0;
        self.doorbells[sq0_doorbell_idx] = self.admin_sq_tail;

        try self.waitForAdminCompletion(cmd.command_id);
    }

    fn waitForAdminCompletion(self: *NvmeDriver, target_id: u16) !void {
        var timeout: u32 = 5_000_000;
        while (timeout > 0) : (timeout -= 1) {
            const head = self.admin_cq_head;
            const cqp: *volatile NvmeCqe = &self.admin_cq[head];
            const status = cqp.status;
            const phase: u1 = @truncate(status & 1);

            if (phase == self.admin_phase) {
                memoryBarrier();
                const cmd_id = cqp.command_id;
                const result = cqp.result;

                // Consume the entry and acknowledge it BEFORE
                // reporting any error; leaving a failed entry
                // unconsumed would make every later command see the
                // same stale completion.
                self.admin_cq_head = (head + 1) % QueueEntries;
                if (self.admin_cq_head == 0) self.admin_phase ^= 1;
                const shift: std.math.Log2Int(usize) = @truncate(self.db_stride);
                self.doorbells[@as(usize, 1) << shift] = self.admin_cq_head;

                if (cmd_id == target_id) {
                    self.last_admin_result = result;
                    if (((status >> 1) & 0x7FFF) != 0) return error.NvmeHardwareCommandError;
                    return;
                }
                continue;
            }
            cpuRelax();
        }
        return error.DeviceTimeout;
    }

    fn submitIoCommand(self: *NvmeDriver, qid: u16, cmd: NvmeCmd) !void {
        if (qid == 0 or qid > self.configured_io_queues or qid > MaxIoQueues) return error.InvalidIoQueueId;
        const q_idx = @as(usize, qid - 1);
        const completion_slot = @as(usize, cmd.command_id) % QueueEntries;
        self.io_completion_ready[q_idx][completion_slot] = false;
        const tail = self.io_sq_tails[q_idx];

        const next_tail = (tail + 1) % QueueEntries;
        if (next_tail == self.io_cq_heads[q_idx]) return error.IoQueueFull;

        self.io_sqs[q_idx][tail] = cmd;
        self.io_sq_tails[q_idx] = next_tail;

        memoryBarrier();

        // SQ Doorbell index = (2 * qid) << db_stride
        const shift: std.math.Log2Int(usize) = @truncate(self.db_stride);
        const sq_db_idx = (@as(usize, 2) * qid) << shift;
        self.doorbells[sq_db_idx] = self.io_sq_tails[q_idx];

        try self.waitForIoCompletion(qid, cmd.command_id);
    }

    fn waitForIoCompletion(self: *NvmeDriver, qid: u16, target_id: u16) !void {
        if (qid == 0 or qid > self.configured_io_queues or qid > MaxIoQueues) return error.InvalidIoQueueId;
        const q_idx = @as(usize, qid - 1);
        if (self.msix_enabled) {
            const slot = @as(usize, target_id) % QueueEntries;
            var interrupt_timeout: u32 = 50_000_000;
            while (interrupt_timeout > 0) : (interrupt_timeout -= 1) {
                memoryBarrier();
                if (self.io_completion_ready[q_idx][slot]) {
                    memoryBarrier();
                    const status = self.io_completion_status[q_idx][slot];
                    self.io_completion_ready[q_idx][slot] = false;
                    if ((status >> 1) != 0) return error.NvmeHardwareCommandError;
                    return;
                }
                if (self.completion_wait_hook) |hook| {
                    if (self.completion_wait_context) |context| {
                        hook(context, qid, target_id);
                    } else if (comptime builtin.cpu.arch.isX86()) {
                        asm volatile ("pause");
                    }
                } else if (comptime builtin.cpu.arch.isX86()) {
                    asm volatile ("pause");
                }
            }
            return error.DeviceTimeout;
        }

        var timeout: u32 = 5_000_000;
        var waited_us: u64 = 0;
        while (timeout > 0) : (timeout -= 1) {
            const head = self.io_cq_heads[q_idx];
            const cqp: *volatile NvmeCqe = &self.io_cqs[q_idx][head];
            const status = cqp.status;
            const phase: u1 = @truncate(status & 1);

            if (phase == self.io_phases[q_idx]) {
                memoryBarrier();
                const cmd_id = cqp.command_id;

                // Consume + acknowledge first, then report errors.
                self.io_cq_heads[q_idx] = (head + 1) % QueueEntries;
                if (self.io_cq_heads[q_idx] == 0) self.io_phases[q_idx] ^= 1;
                // CQ Doorbell index = (2 * qid + 1) << db_stride
                const shift: std.math.Log2Int(usize) = @truncate(self.db_stride);
                const cq_db_idx = ((@as(usize, 2) * qid) + 1) << shift;
                self.doorbells[cq_db_idx] = self.io_cq_heads[q_idx];

                if (cmd_id == target_id) {
                    if (((status >> 1) & 0x7FFF) != 0) return error.NvmeHardwareCommandError;
                    return;
                }
                continue;
            }
            if (self.wait_hook) |hook| {
                waited_us += hook(self.wait_ctx.?);
                if (waited_us > 5_000_000) return error.DeviceTimeout;
                timeout += 1; // time counts here, not turns
            } else cpuRelax();
        }
        return error.DeviceTimeout;
    }

    pub const NamespaceInfo = struct {
        nsid: u32,
        total_blocks: u64,
        block_size: u32,
    };

    /// Queries geometry and capacity for a specific namespace
    /// without changing active state.
    pub fn getNamespaceInfo(self: *NvmeDriver, nsid: u32) !NamespaceInfo {
        if (nsid == 0 or nsid > self.num_namespaces) return error.InvalidNamespaceId;
        var ns_buffer: [4096]u8 align(4096) = [_]u8{0} ** 4096;
        const ns_phys = virtToPhys(@intFromPtr(&ns_buffer));

        var ns_cmd = NvmeCmd.zero;
        ns_cmd.opcode = 0x06; // Identify
        ns_cmd.command_id = self.getNewCmdId();
        ns_cmd.nsid = nsid;
        ns_cmd.prp1 = ns_phys;
        ns_cmd.cdw10 = 0; // CNS = 0 (Identify Namespace)
        try self.submitAdminCommand(ns_cmd);

        const total_blocks = std.mem.readInt(u64, ns_buffer[0..8], .little);
        if (total_blocks == 0) return error.NamespaceInactive;

        const flbas = ns_buffer[26];
        // Format index = FLBAS[3:0], plus FLBAS[6:5]
        // as the upper bits when NLBAF > 16.
        const lba_format_idx: usize = @as(usize, flbas & 0x0F) | (@as(usize, flbas & 0x60) >> 1);
        const lba_format_offset = 128 + (lba_format_idx * 4);
        const ms = std.mem.readInt(u16, ns_buffer[lba_format_offset..][0..2], .little);
        // Per-block metadata would need an MPTR
        // buffer and changes the data layout.
        if (ms != 0) return error.UnsupportedMetadataFormat;
        const lbads = ns_buffer[lba_format_offset + 2];

        const bsize: u32 = if (lbads == 0)
            512
        else
            @as(u32, 1) << @as(std.math.Log2Int(u32), @intCast(lbads));

        return .{
            .nsid = nsid,
            .total_blocks = total_blocks,
            .block_size = bsize,
        };
    }

    /// Switches the active namespace used for
    /// block I/O and updates drive geometry.
    pub fn selectNamespace(self: *NvmeDriver, nsid: u32) !void {
        const info = try self.getNamespaceInfo(nsid);
        self.active_nsid = info.nsid;
        self.total_blocks = info.total_blocks;
        self.block_size = info.block_size;
        const by_size = self.max_transfer_bytes / @as(usize, info.block_size);
        self.max_blocks_per_cmd = @intCast(@max(@as(usize, 1), @min(by_size, @as(usize, 0xFFFF))));
    }

    fn identifyControllerAndNamespaces(self: *NvmeDriver) !void {
        // 1. Identify Controller (CNS = 1) to
        // discover number of namespaces (NN)
        var ctrl_buffer: [4096]u8 align(4096) = [_]u8{0} ** 4096;
        const ctrl_phys = virtToPhys(@intFromPtr(&ctrl_buffer));

        var ctrl_cmd = NvmeCmd.zero;
        ctrl_cmd.opcode = 0x06; // Identify
        ctrl_cmd.command_id = self.getNewCmdId();
        ctrl_cmd.prp1 = ctrl_phys;
        ctrl_cmd.cdw10 = 1; // CNS = 1 (Identify Controller)
        try self.submitAdminCommand(ctrl_cmd);

        // Number of Namespaces (NN) is located at bytes 516-519 (u32)
        self.num_namespaces = std.mem.readInt(u32, ctrl_buffer[516..520], .little);
        if (self.num_namespaces == 0) self.num_namespaces = 1;

        // Maximum data transfer size (MDTS, byte 77): 2^MDTS minimum
        // pages (4 KB); 0 = no limit.
        // Our static PRP list covers ~1 MiB, so cap there.
        const mdts = ctrl_buffer[77];
        const cap_bytes: usize = 1024 * 1024;
        self.max_transfer_bytes = if (mdts == 0 or mdts > 8) cap_bytes else @min(cap_bytes, @as(usize, 4096) << @as(u5, @intCast(mdts)));

        // 2. The first active namespace: NSID 1 can be inactive on
        //    multi-namespace controllers, so the active list (CNS 2)
        //    is asked, NSID 1 the fallback:
        var nsid: u32 = 1;
        {
            var list: [4096]u8 align(4096) = [_]u8{0} ** 4096;
            var lc = NvmeCmd.zero;
            lc.opcode = 0x06; // Identify
            lc.command_id = self.getNewCmdId();
            lc.nsid = 0;
            lc.prp1 = virtToPhys(@intFromPtr(&list));
            lc.cdw10 = 2; // CNS = 2: active namespace ID list
            if (self.submitAdminCommand(lc)) |_| {
                const first = std.mem.readInt(u32, list[0..4], .little);
                if (first != 0) nsid = first;
            } else |_| {}
        }
        try self.selectNamespace(nsid);
    }

    // ZDOS adapter
    pub fn zdosRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) !void {
        const self: *NvmeDriver = @ptrCast(@alignCast(@constCast(ctx)));
        if (buf.len < count * self.block_size) return error.BufferTooSmall;
        var remaining = count;
        var cur_lba = lba;
        var offset: usize = 0;

        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, self.max_blocks_per_cmd));
            const byte_len = @as(usize, chunk) * self.block_size;
            try self.readBlocks(cur_lba, chunk, buf[offset .. offset + byte_len]);
            remaining -= chunk;
            cur_lba += chunk;
            offset += byte_len;
        }
    }

    pub fn zdosWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) !void {
        const self: *NvmeDriver = @ptrCast(@alignCast(@constCast(ctx)));
        if (data.len < count * self.block_size) return error.BufferTooSmall;
        var remaining = count;
        var cur_lba = lba;
        var offset: usize = 0;

        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, self.max_blocks_per_cmd));
            const byte_len = @as(usize, chunk) * self.block_size;
            try self.writeBlocks(cur_lba, chunk, data[offset .. offset + byte_len]);
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

    pub fn asZdosDevice(self: *NvmeDriver) ZdosBlockDevice {
        return .{
            .ctx = self,
            .read = zdosRead,
            .write = zdosWrite,
        };
    }
};
