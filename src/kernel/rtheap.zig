// The real-time heap (RTHEAP=): programs' memory comes from
// this pool first, in constant time: TLSF (Masmano et al.).
// When it is full, memory comes from
// the platform's allocator, unbounded.
const std = @import("std");
const platform = @import("../platform.zig");

const alignment = 16;
const sl_log2 = 4; // 16 lists per power of two
const sl_count = 1 << sl_log2;
const fl_shift = sl_log2 + 4; // below 256 bytes: one level, 16-byte steps
const small_block = 1 << fl_shift;
const fl_max = if (@sizeOf(usize) == 8) 38 else 30; // the largest block: 2^fl_max
const fl_count = fl_max - fl_shift + 1;

// Before each block's memory; the next block's header follows its end
const Header = extern struct {
    prev_phys: ?*Header align(alignment), // the block before it in the pool
    size: usize, // of the memory after the header; bit 0: free
    fn bytes(self: *const Header) usize {
        return self.size & ~@as(usize, 1);
    }
    fn isFree(self: *const Header) bool {
        return self.size & 1 != 0;
    }
    fn next(self: *Header) *Header {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Header) + self.bytes());
    }
    fn links(self: *Header) *Links {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Header));
    }
};

// A free block's list links, in its memory
const Links = struct { next: ?*Header, prev: ?*Header };

comptime {
    std.debug.assert(@sizeOf(Header) == alignment);
}
const min_size = @max(@sizeOf(Links), alignment);

var fl_bitmap: u32 = 0;
var sl_bitmap: [fl_count]u32 = @splat(0);
var heads: [fl_count][sl_count]?*Header = @splat(@splat(null));
var pool_start: usize = 0;
var pool_end: usize = 0;
var pool_free: usize = 0;

// Several cores and interrupts: one lock, interrupts off while
// held (every operation is a few list and bitmap steps)
var lock_word = std.atomic.Value(bool).init(false);

fn take() usize {
    while (true) {
        while (lock_word.load(.monotonic)) std.atomic.spinLoopHint();
        const was = if (platform.has_switching) platform.switching.disable() else 0;
        if (lock_word.cmpxchgWeak(false, true, .acquire, .monotonic) == null) return was;
        if (platform.has_switching) platform.switching.restore(was);
    }
}

fn give(was: usize) void {
    lock_word.store(false, .release);
    if (platform.has_switching) platform.switching.restore(was);
}

fn fls(x: usize) u6 {
    return @intCast(@bitSizeOf(usize) - 1 - @clz(x));
}

const Index = struct { fl: usize, sl: usize };

fn mapping(size: usize) Index {
    if (size < small_block) return .{ .fl = 0, .sl = size / (small_block / sl_count) };
    const f = fls(size);
    const sl = (size >> @intCast(f - sl_log2)) ^ sl_count;
    return .{ .fl = f - (fl_shift - 1), .sl = sl };
}

// The list whose every block fits size:
// rounded up to the next list first
fn mappingSearch(size: usize) Index {
    var s = size;
    if (s >= small_block) s += (@as(usize, 1) << @intCast(fls(s) - sl_log2)) - 1;
    return mapping(s);
}

fn insert(b: *Header) void {
    const i = mapping(b.bytes());
    const l = b.links();
    l.prev = null;
    l.next = heads[i.fl][i.sl];
    if (l.next) |n| n.links().prev = b;
    heads[i.fl][i.sl] = b;
    fl_bitmap |= @as(u32, 1) << @intCast(i.fl);
    sl_bitmap[i.fl] |= @as(u32, 1) << @intCast(i.sl);
}

fn remove(b: *Header) void {
    const i = mapping(b.bytes());
    const l = b.links();
    if (l.prev) |p| p.links().next = l.next else heads[i.fl][i.sl] = l.next;
    if (l.next) |n| n.links().prev = l.prev;
    if (heads[i.fl][i.sl] == null) {
        sl_bitmap[i.fl] &= ~(@as(u32, 1) << @intCast(i.sl));
        if (sl_bitmap[i.fl] == 0) fl_bitmap &= ~(@as(u32, 1) << @intCast(i.fl));
    }
}

fn findSuitable(start: Index) ?*Header {
    var fl = start.fl;
    if (fl >= fl_count) return null;
    var sl_map = sl_bitmap[fl] & (~@as(u32, 0) << @intCast(start.sl));
    if (sl_map == 0) {
        if (fl + 1 >= 32) return null;
        const fl_map = fl_bitmap & (~@as(u32, 0) << @intCast(fl + 1));
        if (fl_map == 0) return null;
        fl = @ctz(fl_map);
        sl_map = sl_bitmap[fl];
    }
    return heads[fl][@ctz(sl_map)];
}

// The pool: `bytes` taken from the
// platform at startup; false if it can't be
pub fn init(bytes: usize) bool {
    if (pool_end != 0 or bytes < 64 * 1024) return false;
    const pages = std.mem.alignForward(usize, bytes, 4096) / 4096;
    const mem = platform.memory.allocPages(pages, false) orelse return false;
    pool_start = @intFromPtr(mem);
    pool_end = pool_start + pages * 4096;
    // One free block, then a used one of size 0 that ends merging
    const first: *Header = @ptrFromInt(pool_start);
    const size = pages * 4096 - 2 * @sizeOf(Header);
    first.* = .{ .prev_phys = null, .size = size | 1 };
    const sentinel = first.next();
    sentinel.* = .{ .prev_phys = first, .size = 0 };
    const was = take();
    insert(first);
    pool_free = size;
    give(was);
    return true;
}

pub fn active() bool {
    return pool_end != 0;
}

// Size and free bytes of the pool (0: no pool)
pub fn stats() struct { size: usize, free: usize } {
    return .{ .size = pool_end - pool_start, .free = pool_free };
}

pub fn alloc(n: usize) ?[*]align(alignment) u8 {
    if (pool_end == 0 or n == 0 or n > (@as(usize, 1) << fl_max)) return null;
    const size = @max(std.mem.alignForward(usize, n, alignment), min_size);
    const was = take();
    defer give(was);
    const b = findSuitable(mappingSearch(size)) orelse return null;
    remove(b);
    // The rest a block of its own, if it holds one
    if (b.bytes() >= size + @sizeOf(Header) + min_size) {
        const rest: *Header = @ptrFromInt(@intFromPtr(b) + @sizeOf(Header) + size);
        rest.* = .{ .prev_phys = b, .size = (b.bytes() - size - @sizeOf(Header)) | 1 };
        rest.next().prev_phys = rest;
        b.size = size;
        insert(rest);
        pool_free -= size + @sizeOf(Header);
    } else {
        pool_free -= b.bytes();
        b.size = b.bytes();
    }
    return @ptrFromInt(@intFromPtr(b) + @sizeOf(Header));
}

pub fn owns(ptr: *const anyopaque) bool {
    const a = @intFromPtr(ptr);
    return a >= pool_start and a < pool_end;
}

// false: not from the pool (the caller frees it elsewhere)
pub fn free(ptr: *anyopaque) bool {
    if (!owns(ptr)) return false;
    const was = take();
    defer give(was);
    var b: *Header = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(Header));
    if (b.isFree()) return true; // twice: better ignored than a broken list
    pool_free += b.bytes();
    b.size |= 1;
    if (b.prev_phys) |p| {
        if (p.isFree()) {
            remove(p);
            p.size = (p.bytes() + @sizeOf(Header) + b.bytes()) | 1;
            pool_free += @sizeOf(Header);
            b = p;
            b.next().prev_phys = b;
        }
    }
    const n = b.next();
    if (n.isFree()) {
        remove(n);
        b.size = (b.bytes() + @sizeOf(Header) + n.bytes()) | 1;
        pool_free += @sizeOf(Header);
        b.next().prev_phys = b;
    }
    insert(b);
    return true;
}

// Parses "16M", "512K", "1G" or bytes; null if it isn't a size
pub fn parseSize(text: []const u8) ?usize {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    const unit: usize = switch (std.ascii.toUpper(t[t.len - 1])) {
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        else => 1,
    };
    const digits = if (unit == 1) t else t[0 .. t.len - 1];
    const v = std.fmt.parseInt(usize, std.mem.trimRight(u8, digits, "B b"), 10) catch return null;
    return std.math.mul(usize, v, unit) catch null;
}
