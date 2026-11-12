// Own identity-mapped page tables for the metal editions.
// PAGING= in SYSTEM.CFG gives the page size
// (4096 ARM64 also 16384, 65536), anything else keeps
// the firmware's; default 4096, or 16384 on ARM64 if available.
// Switched in configure, before the first program.
// RAM becomes cached and executable everywhere, devices uncached,
// and the firmware's boot-time memory free (memory.ownTables).
// Uses the largest block entries possible. RW_NX=true (x86_64):
// RAM is never executed, except ZDOS's code, the firmware's
// runtime code, the cores' startup page and the code
// of loaded images (protectCode: read and execute only).
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const console = @import("console.zig");
const framebuffer = @import("framebuffer.zig");
const switching = @import("switching.zig");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("paging_x86_64.zig"),
    .aarch64 => @import("paging_arm64.zig"),
    else => @compileError("metal: x86_64 and aarch64 only"),
};

// code: read and execute; ram_exec: read, write and execute
// (RAM without RW_NX); ram never executes with RW_NX
pub const Kind = enum { ram, device, screen, code, ram_exec, guard }; // guard: not mapped

// RW_NX= from SYSTEM.CFG, before configure (x86_64 for now)
const has_nx = @hasField(impl.Layout, "nx");
var nx_wanted = false;
var nx = false; // in use

pub fn setRwNx(value: ?[]const u8) void {
    const v = std.mem.trim(u8, value orelse return, " \t");
    nx_wanted = std.ascii.eqlIgnoreCase(v, "true");
}

// PAGING= from SYSTEM.CFG (null: not set)
pub fn configure(value: ?[]const u8) void {
    defer if (nx_wanted and !nx) report("RW_NX=true needs own page tables on x86_64 with NX: off\n", .{});
    const text = std.mem.trim(u8, value orelse return build(defaultSize()) catch |err| {
        report("Own page tables failed ({s}); the firmware's stay\n", .{@errorName(err)});
        return;
    }, " \t");
    const wanted = std.fmt.parseInt(usize, text, 10) catch return; // not a number: the firmware's tables
    var size = wanted;
    if (!impl.supports(size)) {
        size = 4096;
        report("PAGING={d} is not available on this CPU: using {d}\n", .{ wanted, size });
    }
    build(size) catch |err| {
        report("PAGING={d}: own page tables failed ({s}); the firmware's stay\n", .{ size, @errorName(err) });
        return;
    };
}

// The page size configure will use for PAGING=
// (before tables exist: the allocator's granule);
// the firmware's tables count as 4 KiB
pub fn sizeFor(value: ?[]const u8) usize {
    const text = std.mem.trim(u8, value orelse return defaultSize(), " \t");
    const wanted = std.fmt.parseInt(usize, text, 10) catch return 4096;
    return if (impl.supports(wanted)) wanted else 4096;
}

fn defaultSize() usize {
    return if (builtin.cpu.arch == .aarch64 and impl.supports(16384)) 16384 else 4096;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    console.write(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

var layout: impl.Layout = undefined;
var root: [*]u64 = undefined;
var active = false; // own tables in use

// A device's registers for a driver
// loaded late (kernel/drivers.zig):
// mapped uncached now if own tables are
// in use (else registered for them, or
// the firmware's map them)
pub fn mapDevice(start: u64, len: u64) bool {
    if (!active) {
        memory.addDevice(start, len);
        return true;
    }
    const was = take();
    defer give(was);
    map(start, start + len, .device) catch return false;
    impl.flush(layout);
    return true;
}

fn build(page_size: usize) !void {
    layout = try impl.prepare(page_size);
    if (comptime has_nx) layout.nx = nx_wanted and impl.hasNx();
    root = try newTable();

    // Everything up to the highest address of RAM and devices:
    // devices (x86_64: only below 4 GiB, the rest as listed), then
    // RAM over it, then the devices the
    // drivers found, then the screen
    var top: u64 = 1 << 32;
    memory.forEachRange(&top, struct {
        fn f(t: *u64, _: u64, end: u64, _: memory.Kind) void {
            t.* = @max(t.*, end);
        }
    }.f);
    for (memory.devices[0..memory.device_count]) |d| top = @max(top, d.end);
    if (top > layout.address_space) return error.AddressesTooHigh;

    try map(0, impl.deviceDefaultTop(top), .device);
    var failed: ?anyerror = null;
    memory.forEachRange(&failed, struct {
        fn f(err: *?anyerror, start: u64, end: u64, kind: memory.Kind) void {
            if (err.* != null) return;
            map(start, end, if (kind == .other) .device else .ram) catch |e| {
                err.* = e;
            };
        }
    }.f);
    if (failed) |err| return err;
    for (memory.devices[0..memory.device_count]) |d| try map(d.start, d.end, .device);
    const screen = framebuffer.range();
    if (screen.end > screen.start and !inRam(screen)) try map(screen.start, screen.end, .screen);
    if (comptime has_nx) {
        if (layout.nx) try executable();
    }

    // Switch, then drop the firmware's GDT / vectors. Its boot-time
    // memory is reclaimed only if ZDOS no
    // longer runs on the firmware's stack.
    impl.activate(root, layout);
    active = true;
    if (comptime has_nx) nx = layout.nx;
    const reclaim = impl.ownCpuState() and !onBootServicesStack();
    memory.ownTables(reclaim, screen);
}

var image_start: usize = 0;
var image_size: usize = 0;
var stub_page: usize = 0;

// ZDOS's own image (a PE file as loaded)
// and the x86 cores' startup page
pub fn setImage(start: usize, size: usize) void {
    image_start = start;
    image_size = size;
}

pub fn setStubPage(page: usize) void {
    stub_page = page;
}

// What stays executable with RW_NX: ZDOS's code sections
// (read and execute; with a writable one, all three), the
// firmware's runtime code, the startup page (written
// before each core starts)
fn executable() !void {
    if (image_size >= 0x40) {
        const b: [*]const u8 = @ptrFromInt(image_start);
        const pe = std.mem.readInt(u32, b[0x3C..0x40], .little);
        if (pe + 24 <= image_size and std.mem.eql(u8, b[pe..][0..4], "PE\x00\x00")) {
            const count = std.mem.readInt(u16, b[pe + 6 ..][0..2], .little);
            const optional = std.mem.readInt(u16, b[pe + 20 ..][0..2], .little);
            var at: usize = pe + 24 + optional;
            for (0..count) |_| {
                if (at + 40 > image_size) break;
                const size = std.mem.readInt(u32, b[at + 8 ..][0..4], .little);
                const addr = std.mem.readInt(u32, b[at + 12 ..][0..4], .little);
                const flags = std.mem.readInt(u32, b[at + 36 ..][0..4], .little);
                if (flags & 0x2000_0000 != 0) { // IMAGE_SCN_MEM_EXECUTE
                    const kind: Kind = if (flags & 0x8000_0000 != 0) .ram_exec else .code;
                    try map(image_start + addr, image_start + addr + size, kind);
                }
                at += 40;
            }
        } else try map(image_start, image_start + image_size, .ram_exec);
    }
    var failed: ?anyerror = null;
    memory.forEachRuntimeCode(&failed, struct {
        fn f(err: *?anyerror, start: u64, end: u64) void {
            if (err.* == null) map(start, end, .ram_exec) catch |e| {
                err.* = e;
            };
        }
    }.f);
    if (failed) |err| return err;
    if (stub_page != 0) try map(stub_page, stub_page + 4096, .ram_exec);
}

// A loaded image's code (loader.zig): read and execute only, or
// also writable (an image without separate code pages).
// False if the tables can't be split (no memory).
// Without RW_NX nothing changes.
pub fn protectCode(start: usize, end: usize, read_only: bool) bool {
    if (!nx) return true;
    const was = take();
    defer give(was);
    map(start, end, if (read_only) .code else .ram_exec) catch return false;
    impl.flush(layout);
    return true;
}

// The image's memory goes back: plain RAM again. Its entries
// are pages already (protectCode split
// them), so nothing is allocated.
pub fn releaseCode(start: usize, end: usize) void {
    if (!nx) return;
    const was = take();
    defer give(was);
    map(start, end, .ram) catch {};
    impl.flush(layout);
}

// x86_64: page faults run on a stack of their own (a TSS's
// IST); ARM64: the exception entry checks
// its stack first (switch_arm64.zig).

// STACK GUARDS (memory.allocStack)
pub const guards_supported = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64;

pub fn guardsAvailable() bool {
    return guards_supported and active and fault_stacks;
}

var fault_stacks = false; // every core takes page faults on a stack of its own

pub fn setFaultStacks(on: bool) void {
    fault_stacks = on;
}

// [start, start + len) unmapped (on) or RAM again.
// Other cores drop their cached translations at their next
// task switch (syncTlb): x86_64 has no broadcast flush.
pub fn setGuard(start: usize, len: usize, on: bool) bool {
    const was = take();
    defer give(was);
    map(start, start + len, if (on) .guard else .ram) catch return false;
    impl.flush(layout);
    _ = tlb_generation.fetchAdd(1, .release);
    return true;
}

var tlb_generation = std.atomic.Value(u32).init(0);
var tlb_seen = [_]u32{0} ** 64;

// A core about to run a task: its TLB
// without guards set since it last looked
pub fn syncTlb(core: usize) void {
    if (!guards_supported or !active or core >= tlb_seen.len) return;
    const g = tlb_generation.load(.acquire);
    if (tlb_seen[core] == g) return;
    tlb_seen[core] = g;
    impl.flush(layout);
}

// Table changes from any core (a stack freed in the scheduler,
// a program's code protected): one at a time, interrupts off
var lock = std.atomic.Value(bool).init(false);

fn take() usize {
    const was = switching.disable();
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    return was;
}

fn give(was: usize) void {
    lock.store(false, .release);
    switching.restore(was);
}

// A page fault the tables allow: another core changed the entry
// (code made executable, freed code writable) and this core's
// TLB still has the old one
pub fn allows(addr: usize, write: bool, exec: bool) bool {
    if (!active) return false;
    var t = root;
    var level: u3 = 0;
    while (true) : (level += 1) {
        const last = level == layout.levels - 1;
        const index: usize = @intCast((addr >> @intCast(layout.page_shift + (layout.levels - 1 - level) * layout.index_bits)) & (layout.entries - 1));
        const e = t[index];
        if (!impl.isValid(e)) return false;
        if (impl.isTable(e, last)) {
            t = impl.tableOf(e);
            continue;
        }
        return impl.leafAllows(e, write, exec);
    }
}

fn newTable() error{OutOfMemory}![*]u64 {
    const t = memory.allocTable(layout.table_bytes) orelse return error.OutOfMemory;
    return @ptrCast(t);
}

// Whether a range lies inside RAM (the firmware's ramfb screen
// in QEMU does): it stays mapped as RAM
fn inRam(r: memory.Device) bool {
    var found = false;
    const Ctx = struct { r: memory.Device, found: *bool };
    memory.forEachRange(Ctx{ .r = r, .found = &found }, struct {
        fn f(c: Ctx, start: u64, end: u64, kind: memory.Kind) void {
            if (kind != .other and c.r.start >= start and c.r.end <= end) c.found.* = true;
        }
    }.f);
    return found;
}

fn onBootServicesStack() bool {
    const sp = impl.stackPointer();
    var on = false;
    const Ctx = struct { sp: u64, on: *bool };
    memory.forEachRange(Ctx{ .sp = sp, .on = &on }, struct {
        fn f(c: Ctx, start: u64, end: u64, kind: memory.Kind) void {
            if (kind == .boot_services and c.sp >= start and c.sp < end) c.on.* = true;
        }
    }.f);
    return on;
}

// Maps [start, end) (rounded out to pages) as kind; later calls
// win over earlier ones where they overlap The first page is
// never mapped (memory.null_guard): null pointers fault
fn map(start: u64, end: u64, kind: Kind) error{OutOfMemory}!void {
    const page = @as(u64, 1) << layout.page_shift;
    const s = @max(start & ~(page - 1), page);
    const e = (end + page - 1) & ~(page - 1);
    if (e > s) try mapIn(root, 0, 0, s, e, kind);
}

// An entry of table level `level` (0: the top) covers this many bytes
fn span(level: u3) u64 {
    const below: u6 = @intCast(layout.levels - 1 - level);
    return @as(u64, 1) << (layout.page_shift + below * layout.index_bits);
}

fn mapIn(table: [*]u64, level: u3, base: u64, start: u64, end: u64, kind: Kind) error{OutOfMemory}!void {
    const size = span(level);
    const last = level == layout.levels - 1;
    var a = start;
    while (a < end) {
        const index: usize = @intCast((a - base) / size);
        const entry_start = base + index * size;
        const entry_end = entry_start + size;
        const to = @min(end, entry_end);
        if (a == entry_start and to == entry_end and (last or level >= layout.block_from)) {
            // The whole entry: one page or block
            table[index] = impl.leaf(entry_start, kind, last, layout);
        } else {
            // Part of it: a table one level down,
            // holding what the entry mapped so far
            const old = table[index];
            const child = if (impl.isTable(old, last)) impl.tableOf(old) else blk: {
                const t = try newTable();
                if (impl.isValid(old)) {
                    const child_size = span(level + 1);
                    const child_last = level + 1 == layout.levels - 1;
                    for (0..layout.entries) |i| t[i] = impl.smaller(old, entry_start + i * child_size, child_last, layout);
                }
                table[index] = impl.table(@intFromPtr(t));
                break :blk t;
            };
            try mapIn(child, level + 1, entry_start, a, to, kind);
        }
        a = to;
    }
}
