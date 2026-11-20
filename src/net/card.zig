// Network cards from 0 (NET0= is card 0): those drivers
// registered, then the platform's own. A driver's card is
// polled unless it gave its interrupts (net_interrupts).
const platform = @import("../platform.zig");
const drivers = @import("../kernel/drivers.zig");
const drv = @import("../kernel/drv.zig");

pub const max = 8; // glue.h's ZN_CARDS

pub const Card = struct {
    mac: [6]u8,
    name: []const u8,
    event: ?*platform.IoEvent = null,
    interrupts: bool = false,
    driver: ?*const drv.NetCard = null, // else the platform's card `builtin`
    builtin: usize = 0,
    control: ?drv.NetControl = null, // a driver's, once its interrupts are connected
    promiscuous: ?drv.NetPromiscuous = null, // a driver's switch to every frame
    acked_here: bool = false, // ack from the network's loop (no handler on core 0)
};

// Driver cards' interrupts on core 0 (NET task)
var driver_event: platform.IoEvent = .{};

pub var cards: [max]Card = undefined;
pub var count: usize = 0;

// Metal and BIOS: whether there is a card at all (before start)
pub fn present() bool {
    if (drivers.available and drivers.net_card_count > 0) return true;
    return platform.net.present();
}

// Starts them all
pub fn start(how: platform.NetInterrupt) void {
    count = 0;
    if (drivers.available) {
        for (drivers.net_cards[0..drivers.net_card_count], 0..) |c, i| {
            if (count == max) return;
            cards[count] = .{ .mac = c.mac, .name = c.name[0..@min(c.name_len, c.name.len)], .driver = c, .promiscuous = drivers.net_promiscuous[i] };
            if (drivers.net_controls[i]) |ctl| connect(&cards[count], ctl, drivers.net_devices[i], how);
            count += 1;
        }
    }
    var i: usize = 0;
    while (count < max and i < max) : (i += 1) {
        const c = platform.net.start(i, how) orelse continue;
        cards[count] = .{ .mac = c.mac, .name = c.name, .event = c.event, .interrupts = c.interrupts, .builtin = i };
        count += 1;
    }
}

pub fn send(i: usize, frame: []const u8) bool {
    const c = &cards[i];
    if (c.driver) |d| return d.send(d.ctx, frame.ptr, frame.len);
    return platform.net.send(c.builtin, frame);
}

pub fn receive(i: usize, buf: []u8) ?usize {
    const c = &cards[i];
    if (c.driver) |d| {
        const n = d.receive(d.ctx, buf.ptr, buf.len);
        return if (n < 0) null else @intCast(n);
    }
    return platform.net.receive(c.builtin, buf);
}

pub fn linkUp(i: usize) bool {
    const c = &cards[i];
    if (c.driver) |d| return d.link_up(d.ctx);
    return platform.net.linkUp(c.builtin);
}

// Every frame, not only its own address's: false if the card
// can't (a driver's without net_promiscuous)
pub fn promiscuous(i: usize) bool {
    const c = &cards[i];
    if (c.driver) |d| {
        const on = c.promiscuous orelse return false;
        return on(d.ctx);
    }
    return platform.net.promiscuous(c.builtin);
}

// The cards' interrupts, on the network core after its wake-up
pub fn acknowledge() void {
    platform.net.acknowledge();
    for (cards[0..count]) |*c| {
        if (c.acked_here) _ = c.control.?(c.driver.?.ctx, drv.NetIrq.ack);
    }
}

// Before the network sleeps: drivers' cards may interrupt again
pub fn rearm() void {
    for (cards[0..count]) |*c| {
        if (c.control) |ctl| _ = ctl(c.driver.?.ctx, drv.NetIrq.rearm);
    }
}

// INTERRUPTS OF DRIVERS' CARDS
fn connect(c: *Card, ctl: drv.NetControl, loc: anytype, how: platform.NetInterrupt) void {
    const od = platform.own_drivers;
    if (!@hasDecl(od, "attachInterrupt")) return;
    c.control = ctl;
    const ok = switch (how) {
        .core0 => od.attachInterrupt(loc, &onCore0, c),
        .relay => direct: {
            // Straight to the network core where the platform can:
            if (@hasDecl(od, "attachTo")) {
                if (platform.net_core.coreIndex()) |core| {
                    if (od.attachTo(loc, core)) {
                        c.acked_here = true;
                        break :direct true;
                    }
                }
            }
            break :direct od.attachInterrupt(loc, &onRelay, c);
        },
        .message => |m| @hasDecl(od, "attachMessage") and od.attachMessage(loc, m.address, m.data),
        .none => false,
    };
    if (!ok or !ctl(c.driver.?.ctx, drv.NetIrq.enable)) {
        c.control = null;
        c.acked_here = false;
        return;
    }
    c.interrupts = true;
    if (how == .message) c.acked_here = true;
    if (how == .core0) c.event = &driver_event;
}

fn ack(ctx: ?*anyopaque) bool {
    const c: *Card = @ptrCast(@alignCast(ctx.?));
    const ctl = c.control orelse return false;
    return ctl(c.driver.?.ctx, drv.NetIrq.ack);
}

fn onCore0(ctx: ?*anyopaque) bool {
    if (!ack(ctx)) return false;
    platform.io.signal(&driver_event);
    return true;
}

fn onRelay(ctx: ?*anyopaque) bool {
    if (!ack(ctx)) return false;
    if (platform.has_net_core) platform.net_core.wake();
    return true;
}
