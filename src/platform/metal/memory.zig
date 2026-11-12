// Physical memory for metal: page bitmaps over the RAM free at
// leaveFirmware, with a small-block allocator on top.
// Addresses are physical (identity mapping).
//
// Firmware page tables may forbid executing free memory (edk2
// on ARM64, many PCs), so program code comes from a "loader
// code" pool taken before leaving (allocPages(n, true)).
// With own page tables (paging.zig) the pool and boot services
// memory go back to RAM (ownTables).
const std = @import("std");
const switching = @import("switching.zig");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const paging = @import("paging.zig");

const page_size = 4096;
const Descriptor = uefi.tables.MemoryDescriptor;

// Pages from `first` on, one bit each; set = in use (or not RAM)
const Pages = struct {
    bits: []u32 = &.{},
    first: usize = 0, // the first page's number (address / 4096)
    count: usize = 0,
    free: usize = 0,
    search: usize = 0, // no free page below this index

    fn isUsed(self: *const Pages, i: usize) bool {
        return self.bits[i / 32] & (@as(u32, 1) << @intCast(i % 32)) != 0;
    }

    fn setUsed(self: *Pages, i: usize, used: bool) void {
        const bit = @as(u32, 1) << @intCast(i % 32);
        if (used) self.bits[i / 32] |= bit else self.bits[i / 32] &= ~bit;
    }

    fn countFree(self: *Pages) void {
        self.free = 0;
        for (0..self.count) |i| {
            if (!self.isUsed(i)) self.free += 1;
        }
    }

    fn contains(self: *const Pages, page: usize) bool {
        return page >= self.first and page < self.first + self.count;
    }

    fn alloc(self: *Pages, n: usize) ?[*]align(4096) u8 {
        return self.allocAligned(n, 1);
    }

    // n pages starting at a page number that is a multiple of `alignment`
    fn allocAligned(self: *Pages, n: usize, alignment: usize) ?[*]align(4096) u8 {
        if (n == 0 or n > self.free) return null;
        var i = self.search;
        var steps: usize = 0;
        while (i + n <= self.count) {
            // A long scan lets go of the lock now and then: interrupts and
            // other cores wait a thousand steps at most
            steps += 1;
            if (steps % 1024 == 0) breathe();
            const misaligned = (self.first + i) % alignment;
            if (misaligned != 0) {
                i += alignment - misaligned;
                continue;
            }
            // Skip whole used words quickly
            if (i % 32 == 0 and self.bits[i / 32] == 0xFFFF_FFFF) {
                i += 32;
                continue;
            }
            if (self.isUsed(i)) {
                i += 1;
                continue;
            }
            var run: usize = 1;
            while (run < n and !self.isUsed(i + run)) run += 1;
            if (run == n) {
                for (i..i + n) |j| self.setUsed(j, true);
                self.free -= n;
                if (i == self.search) self.search = i + n;
                return @ptrFromInt((self.first + i) * page_size);
            }
            i += if (alignment == 1) run + 1 else 1;
        }
        return null;
    }

    fn release(self: *Pages, page: usize, n: usize) void {
        const i = page - self.first;
        for (i..i + n) |j| self.setUsed(j, false);
        self.free += n;
        self.search = @min(self.search, i);
    }

    // The longest run of free pages
    fn longest(self: *const Pages) usize {
        var best: usize = 0;
        var run: usize = 0;
        for (0..self.count) |i| {
            if (self.isUsed(i)) {
                run = 0;
            } else {
                run += 1;
                best = @max(best, run);
            }
        }
        return best;
    }
};

var ram: Pages = .{};
var code: Pages = .{}; // the executable pool
var ram_total: u64 = 0; // RAM in the memory map, used or not

// The firmware's memory map as it was when ZDOS left it
var map_buf: [*]align(8) u8 = undefined;
var map_size: usize = 0;
var map_desc_size: usize = 0;

// The pool: a quarter of the free RAM, 4 to 64 MB
const code_min = 1024;
const code_max = 16384;
var code_bits: [code_max / 32]u32 = undefined;

// Reads the firmware's memory map, takes the bitmap's pages and
// the code pool from it and calls ExitBootServices. false:
// ZDOS can't go on (the caller halts).
pub fn leaveFirmware() bool {
    const bs = uefi.system_table.boot_services.?;
    var size: usize = 0;
    var key: usize = 0;
    var desc_size: usize = 0;
    var version: u32 = 0;
    _ = bs.getMemoryMap(&size, null, &key, &desc_size, &version);
    if (desc_size == 0) return false;
    // Room for more entries: the allocations below split some
    const capacity = size + 16 * desc_size;
    var buf: [*]align(8) u8 = undefined;
    if (bs.allocatePool(.loader_data, capacity, &buf) != .success) return false;
    const map: [*]Descriptor = @ptrCast(buf);

    // The bitmap spans the free RAM, from its lowest page to its highest
    size = capacity;
    if (bs.getMemoryMap(&size, map, &key, &desc_size, &version) != .success) return false;
    var low: u64 = std.math.maxInt(u64);
    var high: u64 = 0;
    var free_total: u64 = 0;
    var off: usize = 0;
    while (off + desc_size <= size) : (off += desc_size) {
        const d = entry(buf, off);
        if (d.type != .conventional_memory) continue;
        low = @min(low, d.physical_start / page_size);
        high = @max(high, d.physical_start / page_size + d.number_of_pages);
        free_total += d.number_of_pages;
    }
    if (high <= low) return false;
    ram.first = @intCast(low);
    ram.count = @intCast(high - low);
    const words = (ram.count + 31) / 32;
    var mem: [*]align(4096) u8 = undefined;
    if (bs.allocatePages(.allocate_any_pages, .loader_data, (words * 4 + page_size - 1) / page_size, &mem) != .success) return false;
    ram.bits = @as([*]u32, @ptrCast(mem))[0..words];

    // The code pool, as big as the firmware can give, down to the minimum
    var want: usize = std.math.clamp(@as(usize, @intCast(free_total / 4)), code_min, code_max);
    while (want >= code_min) : (want /= 2) {
        if (bs.allocatePages(.allocate_any_pages, .loader_code, want, &mem) == .success) {
            code = .{ .bits = code_bits[0 .. (want + 31) / 32], .first = @intFromPtr(mem) / page_size, .count = want };
            @memset(code.bits, 0xFFFF_FFFF);
            for (0..want) |i| code.setUsed(i, false);
            code.countFree();
            break;
        }
    }

    // The final map, then out. ExitBootServices fails if
    // the map changed in between (the firmware's timer
    // events may allocate); then only GetMemoryMap may be
    // called before trying again.
    var tries: usize = 0;
    while (true) : (tries += 1) {
        size = capacity;
        if (bs.getMemoryMap(&size, map, &key, &desc_size, &version) != .success) return false;
        if (bs.exitBootServices(uefi.handle, key) == .success) break;
        if (tries == 3) return false;
    }

    // Free what the map calls free; the rest (the kernel, the
    // bitmap, this map, the code pool, the firmware's runtime
    // memory, ACPI, MMIO) stays used
    @memset(ram.bits, 0xFFFF_FFFF);
    off = 0;
    while (off + desc_size <= size) : (off += desc_size) {
        const d = entry(buf, off);
        switch (d.type) {
            .conventional_memory => {
                ram_total += d.number_of_pages * page_size;
                const start: usize = @intCast(d.physical_start / page_size - ram.first);
                for (start..start + @as(usize, @intCast(d.number_of_pages))) |i| ram.setUsed(i, false);
            },
            .loader_code, .loader_data, .boot_services_code, .boot_services_data, .runtime_services_code, .runtime_services_data, .acpi_reclaim_memory, .acpi_memory_nvs => ram_total += d.number_of_pages * page_size,
            else => {},
        }
    }
    // Never hand out the first 64 KiB: own page tables leave the
    // first page (up to 64 KiB on ARM64)
    // unmapped, so that a null pointer faults
    var low_page: usize = ram.first;
    while (low_page < null_guard / page_size) : (low_page += 1) {
        if (low_page - ram.first < ram.count) ram.setUsed(low_page - ram.first, true);
    }
    ram.countFree();
    map_buf = buf;
    map_size = size;
    map_desc_size = desc_size;
    return true;
}

// FOR OWN PAGE TABLES (paging.zig)
// The memory below this is never handed out, and own page
// tables don't map its first page: a null
// pointer's use faults (SIGSEGV for a program)
pub const null_guard = 64 * 1024;

pub const Kind = enum { ram, boot_services, other };

// Each range of the firmware's memory map: RAM (anything ZDOS,
// the firmware or ACPI keeps data in), the firmware's boot-time
// memory (RAM too), or something else (devices, reserved)
pub fn forEachRange(context: anytype, callback: fn (@TypeOf(context), start: u64, end: u64, kind: Kind) void) void {
    var off: usize = 0;
    while (off + map_desc_size <= map_size) : (off += map_desc_size) {
        const d = entry(map_buf, off);
        const kind: Kind = switch (d.type) {
            .conventional_memory, .loader_code, .loader_data, .runtime_services_code, .runtime_services_data, .acpi_reclaim_memory, .acpi_memory_nvs => .ram,
            .boot_services_code, .boot_services_data => .boot_services,
            else => .other,
        };
        callback(context, d.physical_start, d.physical_start + d.number_of_pages * page_size, kind);
    }
}

// The firmware's runtime code (time, power off): executable with RW_NX
pub fn forEachRuntimeCode(context: anytype, callback: fn (@TypeOf(context), start: u64, end: u64) void) void {
    var off: usize = 0;
    while (off + map_desc_size <= map_size) : (off += map_desc_size) {
        const d = entry(map_buf, off);
        if (d.type == .runtime_services_code) callback(context, d.physical_start, d.physical_start + d.number_of_pages * page_size);
    }
}

// Devices' register ranges the drivers found (PCI BARs, PCIe
// configuration space, the framebuffer):
// own page tables map them uncached
pub const Device = struct { start: u64, end: u64 };
pub var devices: [32]Device = undefined;
pub var device_count: usize = 0;

pub fn addDevice(start: u64, len: u64) void {
    if (device_count == devices.len or len == 0) return;
    devices[device_count] = .{ .start = start, .end = start + len };
    device_count += 1;
}

// A page that ends below `limit` (an address): the x86 cores'
// startup stub must lie below 1 MiB
pub fn allocBelow(limit: u64) ?[*]align(4096) u8 {
    const was = take();
    defer give(was);
    var i: usize = 0;
    while (i < ram.count and (@as(u64, ram.first + i) + 1) * page_size <= limit) : (i += 1) {
        if (ram.isUsed(i)) continue;
        ram.setUsed(i, true);
        ram.free -= 1;
        return @ptrFromInt((ram.first + i) * page_size);
    }
    return null;
}

// Zeroed pages for page tables, aligned to `bytes` (4, 16 or 64 KiB)
pub fn allocTable(bytes: usize) ?[*]align(4096) u8 {
    const was = take();
    defer give(was);
    const pages = bytes / page_size;
    const p = ram.allocAligned(pages, pages) orelse return null;
    @memset(p[0..bytes], 0);
    return p;
}

// Own page tables are in use: the code pool becomes plain RAM;
// with reclaim, the firmware's boot-time memory too, except
// `keep` (the screen). Nothing of the firmware's (page tables,
// GDT, vectors, stack) may be in use any more.
pub fn ownTables(reclaim: bool, keep: Device) void {
    if (code.count != 0 and code.free == code.count) {
        ram.release(code.first, code.count);
        code = .{};
    }
    if (!reclaim) return;
    const Reclaim = struct {
        fn range(k: Device, start: u64, end: u64, kind: Kind) void {
            if (kind != .boot_services) return;
            var page: usize = @intCast(start / page_size);
            while (page < end / page_size) : (page += 1) {
                const at = @as(u64, page) * page_size;
                if (at + page_size > k.start and at < k.end) continue;
                if (at < null_guard) continue;
                if (page < ram.first or page >= ram.first + ram.count or !ram.isUsed(page - ram.first)) continue;
                ram.setUsed(page - ram.first, false);
                ram.free += 1;
                if (page - ram.first < ram.search) ram.search = page - ram.first;
            }
        }
    };
    forEachRange(keep, Reclaim.range);
}

fn entry(buf: [*]align(8) u8, off: usize) *const Descriptor {
    return @ptrCast(@alignCast(buf + off));
}

pub fn stats() platform.MemoryStats {
    return .{
        .total = ram_total,
        .free = @as(u64, ram.free + code.free) * page_size,
        .largest_free = @as(u64, @max(ram.longest(), code.longest())) * page_size,
    };
}

// Several cores allocate (tasks on all cores, a task's stack
// freed in the scheduler): one lock, interrupts off while held
var lock = std.atomic.Value(bool).init(false);
var waiting = std.atomic.Value(u32).init(0); // cores in take()

var held_was: usize = 0;

fn take() usize {
    _ = waiting.fetchAdd(1, .monotonic);
    defer _ = waiting.fetchSub(1, .monotonic);
    while (true) {
        while (lock.load(.monotonic)) std.atomic.spinLoopHint();
        const was = switching.disable();
        if (lock.cmpxchgWeak(false, true, .acquire, .monotonic) == null) {
            held_was = was;
            return was;
        }
        switching.restore(was);
    }
}

fn give(was: usize) void {
    lock.store(false, .release);
    switching.restore(was);
}

// A moment off: a core waiting for the lock gets it first (else it
// would wait for the whole search)
fn breathe() void {
    give(held_was);
    var n: u32 = 0;
    while (waiting.load(.monotonic) != 0 and !lock.load(.monotonic) and n < 1000) : (n += 1) std.atomic.spinLoopHint();
    _ = take();
}

// executable: from the code pool (plain RAM when it is full)
pub fn allocPages(count: usize, executable: bool) ?[*]align(4096) u8 {
    const was = take();
    defer give(was);
    return pagesAlloc(count, executable);
}

pub fn freePages(ptr: [*]align(4096) u8, count: usize) void {
    const was = take();
    defer give(was);
    pagesFree(ptr, count);
}

// Allocations in whole pages of the
// MMU's size (ARM64: 16 KiB by default):
// a page's protection (a guard, RW_NX)
// never touches a neighbour's memory.
// Counts stay in 4 KiB pages; set before
// the first allocation (metal.init).
var unit: usize = 1; // in 4 KiB pages

pub fn setGranule(bytes: usize) void {
    unit = @max(1, bytes / page_size);
}

pub fn granule() usize {
    return unit * page_size;
}

fn units(count: usize) usize {
    return std.mem.alignForward(usize, count, unit);
}

fn pagesAlloc(count: usize, executable: bool) ?[*]align(4096) u8 {
    const n = units(count);
    if (executable) {
        if (code.allocAligned(n, unit)) |p| return p;
    }
    return ram.allocAligned(n, unit);
}

fn pagesFree(ptr: [*]align(4096) u8, count: usize) void {
    const page = @intFromPtr(ptr) / page_size;
    const n = units(count);
    if (code.count != 0 and code.contains(page)) code.release(page, n) else ram.release(page, n);
}

// 32 B .. 2 KiB in power-of-two classes carved from pages, with
// a free list per class; bigger blocks get whole pages.
// An 8-byte header says which.

const Header = extern struct {
    tag: u32, // size class index, or big_tag
    pages: u32, // for big blocks: page count
};
const big_tag = 0xB16B10C;
const min_shift = 5; // 32 bytes
const class_count = 7; // 32 .. 2048
const FreeBlock = struct { next: ?*FreeBlock };

var free_lists = [_]?*FreeBlock{null} ** class_count;

pub fn alloc(size: usize) ?[*]align(8) u8 {
    const was = take();
    defer give(was);
    const total = size + @sizeOf(Header);
    var class: usize = 0;
    while (class < class_count and (@as(usize, 1) << @intCast(min_shift + class)) < total) class += 1;

    if (class == class_count) {
        const pages = (total + page_size - 1) / page_size;
        const mem = pagesAlloc(pages, false) orelse return null;
        const h: *Header = @ptrCast(mem);
        h.* = .{ .tag = big_tag, .pages = @intCast(pages) };
        return @ptrCast(@alignCast(mem + @sizeOf(Header)));
    }

    if (free_lists[class] == null) {
        // Cut a new page (a whole MMU page) into blocks of this class
        const mem = pagesAlloc(1, false) orelse return null;
        const block_size = @as(usize, 1) << @intCast(min_shift + class);
        var off: usize = 0;
        while (off + block_size <= granule()) : (off += block_size) {
            const b: *FreeBlock = @ptrCast(@alignCast(mem + off));
            b.next = free_lists[class];
            free_lists[class] = b;
        }
    }
    const b = free_lists[class].?;
    free_lists[class] = b.next;
    const h: *Header = @ptrCast(b);
    h.* = .{ .tag = @intCast(class), .pages = 0 };
    const p: [*]u8 = @ptrCast(b);
    return @alignCast(p + @sizeOf(Header));
}

pub fn free(ptr: [*]align(8) u8) void {
    const was = take();
    defer give(was);
    const h: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    if (h.tag == big_tag) {
        pagesFree(@ptrCast(@alignCast(h)), h.pages);
        return;
    }
    if (h.tag >= class_count) return; // not ours; better leak than corrupt
    const class = h.tag;
    const b: *FreeBlock = @ptrCast(@alignCast(h));
    b.next = free_lists[class];
    free_lists[class] = b;
}

// [spare][guard][stack]: running off the stack's end faults
// in the guard (unmapped, paging.zig); the fault goes on on
// the spare (cpu_x86_64.zig). Without guards (no own tables,
// ARM64 for now, the list full): plain pages.

// STACKS WITH A GUARD
const spare_bytes = @import("config.zig").stack_spare;
const max_guards = 256;
// The guards' first addresses; 1: being set up; read by fault handlers
var guards = [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** max_guards;

fn spareSize() usize {
    return @max(spare_bytes, granule());
}

fn claimGuard() ?usize {
    const was = take();
    defer give(was);
    for (&guards, 0..) |*g, i| {
        if (g.load(.monotonic) == 0) {
            g.store(1, .monotonic);
            return i;
        }
    }
    return null;
}

pub fn allocStack(bytes: usize) ?[*]align(4096) u8 {
    if (!paging.guardsAvailable()) return allocPages(bytes / page_size, false);
    const slot = claimGuard() orelse return allocPages(bytes / page_size, false);
    const extra = spareSize() + granule();
    const base = allocPages((extra + bytes) / page_size, false) orelse {
        guards[slot].store(0, .release);
        return null;
    };
    const guard = @intFromPtr(base) + spareSize();
    if (!paging.setGuard(guard, granule(), true)) {
        freePages(base, (extra + bytes) / page_size);
        guards[slot].store(0, .release);
        return null;
    }
    guards[slot].store(guard, .release);
    return @ptrFromInt(guard + granule());
}

pub fn freeStack(stack: [*]align(4096) u8, bytes: usize) void {
    const guard = @intFromPtr(stack) - granule();
    for (&guards) |*g| {
        if (g.load(.acquire) != guard) continue;
        _ = paging.setGuard(guard, granule(), false);
        g.store(0, .release);
        freePages(@ptrFromInt(guard - spareSize()), (spareSize() + granule() + bytes) / page_size);
        return;
    }
    freePages(stack, bytes / page_size);
}

// A fault at addr in a guard: the top
// of its spare (where the fault goes on)
pub fn guardAt(addr: usize) ?usize {
    for (&guards) |*g| {
        const start = g.load(.acquire);
        if (start > 1 and addr >= start and addr < start + granule()) return start;
    }
    return null;
}

// A core about to run a task: guards set since are in its TLB too
pub fn syncTlb(core: usize) void {
    paging.syncTlb(core);
}
