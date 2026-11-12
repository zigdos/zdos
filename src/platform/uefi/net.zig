// The network card through the firmware's Simple Network
// Protocol, polled (platform.net; one card: number 0).
// Opened exclusively, so the firmware's own network stack lets
// go of it and doesn't take its frames.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");

const Snp = uefi.protocol.SimpleNetwork;

var snp: *const Snp = undefined;

// Frames handed to Transmit stay the
// firmware's until GetStatus gives them back
const tx_count = 32;
var tx_bufs: [tx_count][1536]u8 align(8) = undefined;
var tx_busy = [_]bool{false} ** tx_count;

pub fn start(i: usize, how: platform.NetInterrupt) ?platform.NetCard {
    _ = how;
    if (i != 0) return null;
    const s = find() orelse {
        // Fast boot may leave network drivers unconnected:
        // connect everything once
        connectAll();
        return startWith(find() orelse return null);
    };
    return startWith(s);
}

fn startWith(s: *const Snp) ?platform.NetCard {
    snp = s;
    if (s.mode.state == .stopped and s.start() != .success) return null;
    if (s.mode.state == .started and s.initialize(0, 0) != .success) return null;
    if (s.mode.state != .initialized) return null;
    const want: Snp.ReceiveFilter = .{ .receive_unicast = true, .receive_multicast = false, .receive_broadcast = true, .receive_promiscuous = false, .receive_promiscuous_multicast = false };
    const mask = s.mode.receive_filter_mask;
    const enable: Snp.ReceiveFilter = .{
        .receive_unicast = want.receive_unicast and mask.receive_unicast,
        .receive_multicast = false,
        .receive_broadcast = want.receive_broadcast and mask.receive_broadcast,
        .receive_promiscuous = false,
        .receive_promiscuous_multicast = false,
    };
    _ = s.receiveFilters(enable, .{ .receive_unicast = false, .receive_multicast = false, .receive_broadcast = false, .receive_promiscuous = false, .receive_promiscuous_multicast = false }, false, 0, null);
    var mac: [6]u8 = undefined;
    @memcpy(&mac, s.mode.current_address[0..6]);
    return .{ .mac = mac, .name = "UEFI network", .event = null };
}

// Polled: nothing to acknowledge
pub fn acknowledge() void {}

// The first card with an Ethernet address, opened exclusively
// if the firmware lets go of it, else shared
fn find() ?*const Snp {
    const bs = uefi.system_table.boot_services.?;
    var count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.by_protocol, @constCast(&Snp.guid), null, &count, &handles) != .success) return null;
    defer _ = bs.freePool(@ptrCast(@alignCast(handles)));
    for (handles[0..count]) |h| {
        var ptr: ?*anyopaque = null;
        if (bs.openProtocol(h, @constCast(&Snp.guid), &ptr, uefi.handle, null, .{ .exclusive = true }) != .success) {
            if (bs.handleProtocol(h, @constCast(&Snp.guid), &ptr) != .success) continue;
        }
        const s: *const Snp = @ptrCast(@alignCast(ptr orelse continue));
        if (s.mode.hw_address_size != 6 or s.mode.media_header_size != 14) continue; // not Ethernet
        return s;
    }
    return null;
}

fn connectAll() void {
    const bs = uefi.system_table.boot_services.?;
    var count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.all_handles, null, null, &count, &handles) != .success) return;
    defer _ = bs.freePool(@ptrCast(@alignCast(handles)));
    for (handles[0..count]) |h| _ = bs.connectController(h, null, null, true);
}

// The transmit buffers the firmware is done with
fn reclaim() void {
    while (true) {
        var status: Snp.InterruptStatus = undefined;
        var done: ?[*]u8 = null;
        if (snp.getStatus(&status, &done) != .success) return;
        const p = done orelse return;
        for (&tx_bufs, 0..) |*b, i| {
            if (@intFromPtr(b) == @intFromPtr(p)) tx_busy[i] = false;
        }
    }
}

pub fn send(_: usize, frame: []const u8) bool {
    if (frame.len > tx_bufs[0].len) return false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        reclaim();
        const i = std.mem.indexOfScalar(bool, &tx_busy, false) orelse {
            _ = uefi.system_table.boot_services.?.stall(10);
            continue;
        };
        @memcpy(tx_bufs[i][0..frame.len], frame);
        switch (snp.transmit(0, frame.len, &tx_bufs[i], null, null, null)) {
            .success => {
                tx_busy[i] = true;
                return true;
            },
            .not_ready => _ = uefi.system_table.boot_services.?.stall(10), // its queue is full
            else => return false,
        }
    }
    return false;
}

pub fn receive(_: usize, buf: []u8) ?usize {
    var len: usize = buf.len;
    return switch (snp.receive(null, &len, buf.ptr, null, null, null)) {
        .success => len,
        else => null, // not_ready: nothing; buffer_too_small: a giant frame, dropped
    };
}

pub fn linkUp(_: usize) bool {
    reclaim(); // GetStatus also refreshes media_present
    return !snp.mode.media_present_supported or snp.mode.media_present;
}

// Every frame, not only its own address's
// (a bridge's port), if the firmware can
pub fn promiscuous(_: usize) bool {
    if (!snp.mode.receive_filter_mask.receive_promiscuous) return false;
    const on: Snp.ReceiveFilter = .{ .receive_unicast = false, .receive_multicast = false, .receive_broadcast = false, .receive_promiscuous = true, .receive_promiscuous_multicast = false };
    const none: Snp.ReceiveFilter = .{ .receive_unicast = false, .receive_multicast = false, .receive_broadcast = false, .receive_promiscuous = false, .receive_promiscuous_multicast = false };
    return snp.receiveFilters(on, none, false, 0, null) == .success;
}
