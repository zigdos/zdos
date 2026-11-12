// Physical memory: a page bitmap over the E820 map,
// with a small-block allocator on top. No paging.
// Only RAM above 1 MiB is used (below: BIOS data,
// stage 2, the BIOS-call buffers);
// RAM above 4 GiB is unreachable.
const std = @import("std");
const platform = @import("../../platform.zig");
const realmode = @import("realmode.zig");

const page_size = 4096;
const first_page = 0x100000 / page_size; // 1 MiB
const max_pages = 1 << 20; // 4 GiB

const E820Entry = extern struct {
    base: u64 align(4),
    length: u64 align(4),
    kind: u32, // 1 = usable RAM
    attributes: u32,
};

extern const __kernel_end: u8;

// One bit per page from first_page on; set = in use (or not RAM)
var bitmap: []u32 = &.{};
var page_count: usize = 0; // pages covered by the bitmap
var free_pages: usize = 0;
var search_start: usize = 0; // no free page below this index
var ram_total: u64 = 0; // usable RAM in the BIOS memory map

pub fn init() void {
    const map: [*]const E820Entry = @ptrFromInt(realmode.info.e820_map);
    const entries = map[0..realmode.info.e820_count];

    // The highest usable page decides the bitmap's size
    var top: u64 = 0;
    for (entries) |e| {
        if (e.kind != 1) continue;
        top = @max(top, @min(e.base + e.length, max_pages * page_size));
        const end = @min(e.base +| e.length, max_pages * page_size);
        if (end > e.base) ram_total += end - e.base;
    }
    if (top <= 0x100000) return;
    page_count = @intCast(top / page_size - first_page);

    // The bitmap goes right after the kernel
    const kernel_end = std.mem.alignForward(usize, @intFromPtr(&__kernel_end), page_size);
    const words = (page_count + 31) / 32;
    const bitmap_ptr: [*]u32 = @ptrFromInt(kernel_end);
    bitmap = bitmap_ptr[0..words];
    @memset(bitmap, 0xFFFF_FFFF);

    // Free the usable RAM, then take back the kernel
    // and the bitmap. Entries may overlap;
    // anything reported as not usable wins.
    for (entries) |e| {
        if (e.kind == 1) markRange(e.base, e.length, false);
    }
    for (entries) |e| {
        if (e.kind != 1) markRange(e.base, e.length, true);
    }
    const reserved_end = std.mem.alignForward(usize, kernel_end + words * 4, page_size);
    markRange(0x100000, reserved_end - 0x100000, true);

    free_pages = 0;
    for (0..page_count) |i| {
        if (!isUsed(i)) free_pages += 1;
    }
}

// Marks the pages of a byte range used or free: free only pages
// fully inside the range, used every page it touches
fn markRange(base: u64, length: u64, used: bool) void {
    const end = @min(base +| length, @as(u64, page_count + first_page) * page_size);
    var start_page: u64 = if (used) base / page_size else (base + page_size - 1) / page_size;
    const end_page: u64 = if (used) (end + page_size - 1) / page_size else end / page_size;
    start_page = @max(start_page, first_page);
    var p = start_page;
    while (p < end_page) : (p += 1) {
        setUsed(@intCast(p - first_page), used);
    }
}

fn isUsed(i: usize) bool {
    return bitmap[i / 32] & (@as(u32, 1) << @intCast(i % 32)) != 0;
}

fn setUsed(i: usize, used: bool) void {
    const bit = @as(u32, 1) << @intCast(i % 32);
    if (used) bitmap[i / 32] |= bit else bitmap[i / 32] &= ~bit;
}

pub fn totalBytes() u64 {
    return @as(u64, page_count) * page_size;
}

pub fn freeBytes() u64 {
    return @as(u64, free_pages) * page_size;
}

pub fn stats() platform.MemoryStats {
    // The longest run of free pages
    var longest: usize = 0;
    var run: usize = 0;
    for (0..page_count) |i| {
        if (isUsed(i)) {
            run = 0;
        } else {
            run += 1;
            longest = @max(longest, run);
        }
    }
    return .{ .total = ram_total, .free = freeBytes(), .largest_free = @as(u64, longest) * page_size };
}

// Tasks are preemptive (ZDOS's code too) and other cores
// run the network: one lock, interrupts off while held.
// A long search lets go now and then (breathe), so
// interrupts and other cores wait a thousand steps at most.
var lock = std.atomic.Value(bool).init(false);
var waiting = std.atomic.Value(u32).init(0); // cores in take()
var held_flags: u32 = 0;

fn take() void {
    _ = waiting.fetchAdd(1, .monotonic);
    defer _ = waiting.fetchSub(1, .monotonic);
    while (true) {
        while (lock.load(.monotonic)) std.atomic.spinLoopHint(); // wait with interrupts as they were
        const f = asm volatile ("pushfl; cli; popl %[f]"
            : [f] "=r" (-> u32),
            :
            : "memory"
        );
        if (lock.cmpxchgWeak(false, true, .acquire, .monotonic) == null) {
            held_flags = f;
            return;
        }
        // Lost the race: interrupts back as they were, then wait again
        if (f & 0x200 != 0) asm volatile ("sti" ::: "memory");
    }
}

fn give() void {
    const f = held_flags;
    lock.store(false, .release);
    if (f & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

// A moment off: a core waiting for the lock gets it first
fn breathe() void {
    give();
    var n: u32 = 0;
    while (waiting.load(.monotonic) != 0 and !lock.load(.monotonic) and n < 1000) : (n += 1) std.atomic.spinLoopHint();
    take();
}

// executable is ignored: no paging
pub fn allocPages(count: usize, executable: bool) ?[*]align(4096) u8 {
    _ = executable;
    take();
    defer give();
    return pagesAlloc(count);
}

fn pagesAlloc(count: usize) ?[*]align(4096) u8 {
    if (count == 0 or count > free_pages) return null;
    var i = search_start;
    var steps: usize = 0;
    while (i + count <= page_count) {
        steps += 1;
        if (steps % 1024 == 0) breathe();
        // Skip whole used words quickly
        if (i % 32 == 0 and bitmap[i / 32] == 0xFFFF_FFFF) {
            i += 32;
            continue;
        }
        if (isUsed(i)) {
            i += 1;
            continue;
        }
        var run: usize = 1;
        while (run < count and !isUsed(i + run)) run += 1;
        if (run == count) {
            for (i..i + count) |j| setUsed(j, true);
            free_pages -= count;
            if (i == search_start) search_start = i + count;
            return @ptrFromInt((first_page + i) * page_size);
        }
        i += run + 1;
    }
    return null;
}

// count pages (at most 16) below 16
// MiB inside one 64 KiB block: ISA DMA
pub fn allocIsaDma(count: usize) ?[*]align(4096) u8 {
    take();
    defer give();
    const limit = (16 << 20) / page_size;
    var i: usize = 0;
    outer: while (i + count <= page_count and first_page + i + count <= limit) : (i += 16 - (first_page + i) % 16) {
        if ((first_page + i) % 16 + count > 16) continue;
        for (i..i + count) |j| {
            if (isUsed(j)) continue :outer;
        }
        for (i..i + count) |j| setUsed(j, true);
        free_pages -= count;
        return @ptrFromInt((first_page + i) * page_size);
    }
    return null;
}

pub fn freePages(ptr: [*]align(4096) u8, count: usize) void {
    take();
    defer give();
    pagesFree(ptr, count);
}

fn pagesFree(ptr: [*]align(4096) u8, count: usize) void {
    const i = @intFromPtr(ptr) / page_size - first_page;
    for (i..i + count) |j| setUsed(j, false);
    free_pages += count;
    search_start = @min(search_start, i);
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
    take();
    defer give();
    const total = size + @sizeOf(Header);
    var class: usize = 0;
    while (class < class_count and (@as(usize, 1) << @intCast(min_shift + class)) < total) class += 1;

    if (class == class_count) {
        const pages = (total + page_size - 1) / page_size;
        const mem = pagesAlloc(pages) orelse return null;
        const h: *Header = @ptrCast(mem);
        h.* = .{ .tag = big_tag, .pages = @intCast(pages) };
        return @ptrCast(@alignCast(mem + @sizeOf(Header)));
    }

    if (free_lists[class] == null) {
        // Cut a new page into blocks of this class
        const mem = pagesAlloc(1) orelse return null;
        const block_size = @as(usize, 1) << @intCast(min_shift + class);
        var off: usize = 0;
        while (off + block_size <= page_size) : (off += block_size) {
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
    take();
    defer give();
    const h: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    if (h.tag == big_tag) {
        pagesFree(@ptrCast(@alignCast(h)), h.pages);
        return;
    }
    if (h.tag >= class_count) return; // not ours; better leak than corrupt
    const class = h.tag;
    const b: *FreeBlock = @ptrCast(h);
    b.next = free_lists[class];
    free_lists[class] = b;
}
