// Other CPU cores on UEFI through MP Services
// (StartupThisAP, non-blocking with an event). Jobs must
// call no firmware function. A core takes a new job only
// once the firmware has signalled the last one's end: it
// wakes a core still leaving a job, and loses the new one. The firmware gives each
// core its stack (OVMF: 32 KiB). Without the protocol:
// core 0 only.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");

const Procedure = *const fn (arg: ?*anyopaque) callconv(uefi.cc) void;

const MpServices = extern struct {
    get_number_of_processors: *const fn (self: *const MpServices, total: *usize, enabled: *usize) callconv(uefi.cc) uefi.Status,
    get_processor_info: *const fn (self: *const MpServices, number: usize, info: *ProcessorInfo) callconv(uefi.cc) uefi.Status,
    startup_all_aps: *const anyopaque,
    startup_this_ap: *const fn (self: *const MpServices, procedure: Procedure, number: usize, wait_event: ?uefi.Event, timeout_us: usize, arg: ?*anyopaque, finished: ?*bool) callconv(uefi.cc) uefi.Status,
    switch_bsp: *const anyopaque,
    enable_disable_ap: *const anyopaque,
    who_am_i: *const fn (self: *const MpServices, number: *usize) callconv(uefi.cc) uefi.Status,

    const guid align(8) = uefi.Guid{
        .time_low = 0x3fdda605,
        .time_mid = 0xa76e,
        .time_high_and_version = 0x4f46,
        .clock_seq_high_and_reserved = 0xad,
        .clock_seq_low = 0x29,
        .node = .{ 0x12, 0xf4, 0x53, 0x1b, 0x3d, 0x08 },
    };
};

// EFI_PROCESSOR_INFORMATION: id, status (bit 0 the main core,
// bit 1 enabled), location; with room for
// the extended location some firmware adds
const ProcessorInfo = extern struct {
    processor_id: u64,
    status_flag: u32,
    location: [3]u32,
    extended: [6]u32,
};

const enabled_bit = 2;
const max_cores = 64;

// A core: the firmware's number for it,
// the event its jobs end with, and the job
const Slot = struct {
    number: usize,
    event: uefi.Event,
    running: std.atomic.Value(bool) = .init(false),
    unreported: bool = false, // ended, the firmware hasn't seen it yet
    job: platform.Job = undefined,
    arg: ?*anyopaque = null,
};

var mp: ?*const MpServices = null;
var slots: [max_cores]Slot = undefined; // [0] unused: core 0 is the caller
var core_count: usize = 1;
var looked = false;

// The enabled cores besides the one ZDOS runs on, numbered from 1
fn find() void {
    looked = true;
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    if (bs.locateProtocol(&MpServices.guid, null, &ptr) != .success) return;
    const services: *const MpServices = @ptrCast(@alignCast(ptr orelse return));
    var total: usize = 0;
    var enabled: usize = 0;
    if (services.get_number_of_processors(services, &total, &enabled) != .success) return;
    var self: usize = 0;
    if (services.who_am_i(services, &self) != .success) return;
    for (0..total) |number| {
        if (number == self or core_count == max_cores) continue;
        var info: ProcessorInfo = undefined;
        if (services.get_processor_info(services, number, &info) != .success) continue;
        if (info.status_flag & enabled_bit == 0) continue;
        var event: uefi.Event = undefined;
        if (bs.createEvent(0, 0, null, null, &event) != .success) continue;
        slots[core_count] = .{ .number = number, .event = event };
        core_count += 1;
    }
    mp = services;
}

pub fn count() usize {
    if (!looked) find();
    return core_count;
}

// Runs on the other core: the job, then its end for busy and wait
fn run(arg: ?*anyopaque) callconv(uefi.cc) void {
    const slot: *Slot = @ptrCast(@alignCast(arg.?));
    slot.job(slot.arg);
    slot.running.store(false, .release);
}

pub fn start(core: u32, job: platform.Job, arg: ?*anyopaque) bool {
    if (core == 0 or core >= core_count) return false;
    const services = mp orelse return false;
    const slot = &slots[core];
    if (slot.running.load(.acquire)) return false;
    const bs = uefi.system_table.boot_services.?;
    if (slot.unreported) {
        if (bs.checkEvent(slot.event) != .success) return false;
        slot.unreported = false;
    }
    slot.job = job;
    slot.arg = arg;
    slot.running.store(true, .release);
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        switch (services.startup_this_ap(services, &run, slot.number, slot.event, 0, slot, null)) {
            .success => {
                slot.unreported = true;
                return true;
            },
            .not_ready => _ = bs.stall(1000),
            else => break,
        }
    }
    slot.running.store(false, .release);
    return false;
}

pub fn busy(core: u32) bool {
    if (core == 0 or core >= core_count) return false;
    return slots[core].running.load(.acquire);
}

// Sleeps in the firmware until it signals the core's job done
pub fn wait(core: u32) void {
    if (core == 0 or core >= core_count) return;
    const slot = &slots[core];
    const bs = uefi.system_table.boot_services.?;
    while (slot.running.load(.acquire)) {
        var index: usize = undefined;
        if (bs.waitForEvent(1, @ptrCast(&slot.event), &index) == .success) slot.unreported = false;
    }
}
