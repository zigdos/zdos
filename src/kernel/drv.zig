// The driver interface: what zdos_driver_init(api, device) gets
// and what a driver registers. Versioned as the program groups:
// slots first, functions only added at its end.
// Drivers import this as module "drv".
const abi = @import("abi.zig");

pub const cc = abi.cc;

// pub const zdos_file_version = [4]u8{ 1, 2, 0, 0 }; in a
// driver's root file: its header's version; and
// pub const zdos_api_version: u32 = 2; the API it needs (else 1)
comptime {
    if (@hasDecl(@import("root"), "zdos_file_version")) asm (abi.fileVersionAsm(@import("root").zdos_file_version));
    if (@hasDecl(@import("root"), "zdos_api_version")) asm (abi.apiVersionAsm(@import("root").zdos_api_version));
}
pub const slotsOf = abi.slotsOf;

// zdos_driver_ids: the devices a driver
// drives, ending with vendor 0.
// Vendor any_vendor matches a class instead:
// device = class << 8 | subclass.
// probe_vendor: no PCI device (ISA cards,
// BIOS edition only): the start is called
// once with a Device of that vendor, all else
// 0, and looks for its hardware itself.
pub const PciId = extern struct { vendor: u16, device: u16 };
pub const any_vendor = 0xFFFF;
pub const probe_vendor = 0xFFFE;

// The device a driver is started for
pub const Device = extern struct {
    segment: u16,
    bus: u8,
    slot: u8,
    func: u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    pad2: u8 = 0,
    // As the BARs read: memory ones are physical addresses (64-bit
    // ones whole, the next entry then
    // 0), I/O ones ports with bit 0 set
    bars: [6]u64,
};

// A network card a driver registers. Its functions may run on
// any core (the network's own) and must call nothing of the
// interface but millis and delay_us. Polled (ZDOS looks every
// millisecond or two) unless net_interrupts connects its
// interrupts.
pub const NetCard = extern struct {
    ctx: ?*anyopaque = null,
    mac: [6]u8,
    name_len: u8,
    pad: u8 = 0,
    name: [32]u8,
    send: *const fn (ctx: ?*anyopaque, frame: [*]const u8, len: usize) callconv(cc) bool,
    // A received frame into buf: its length, or -1 if none waits
    receive: *const fn (ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(cc) isize,
    link_up: *const fn (ctx: ?*anyopaque) callconv(cc) bool,
};

// A sound card a driver registers: 16-bit signed stereo samples
// out (ZDOS converts what programs give). Called with ZDOS's
// lock held, from programs' calls and from a task that calls
// queued every 10 ms or so.
pub const SoundCard = extern struct {
    ctx: ?*anyopaque = null,
    name_len: u8,
    pad: [7]u8 = @splat(0),
    name: [32]u8,
    // Output at rate Hz: true if the card plays that rate (else
    // ZDOS resamples to 48000, or 44100: a card plays one of them)
    start: *const fn (ctx: ?*anyopaque, rate: u32) callconv(cc) bool,
    // Up to len bytes into the card's buffer: the bytes taken (0: full)
    write: *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(cc) usize,
    // Bytes written and not yet played. Also where the driver
    // silences what has played, so
    // that a pause in writing is quiet.
    queued: *const fn (ctx: ?*anyopaque) callconv(cc) usize,
    stop: *const fn (ctx: ?*anyopaque) callconv(cc) void,
    // 0-100
    set_volume: *const fn (ctx: ?*anyopaque, percent: u32) callconv(cc) void,
};

// An interrupt's handler (attach_interrupt): runs with
// interrupts off, on core 0. It may only look at its device and
// quiet it, then say whether the interrupt was the device's
// (wired lines may be shared).
pub const InterruptHandler = *const fn (ctx: ?*anyopaque) callconv(cc) bool;

// What net_interrupts' control(ctx, op) is asked. ack comes
// from the interrupt (or the network's core after its wake-up):
// the card's causes cleared and its interrupts masked, true if
// there were any; rearm unmasks them once ZDOS has taken what
// the card had. Only enable, ack and rearm are asked while the
// network runs; enable only once ZDOS has connected them.
pub const NetIrq = struct {
    pub const enable: u32 = 1;
    pub const ack: u32 = 2;
    pub const rearm: u32 = 3;
    pub const disable: u32 = 4;
};
pub const NetControl = *const fn (ctx: ?*anyopaque, op: u32) callconv(cc) bool;

pub const Api = extern struct {
    slots: usize,
    // A line for the screen (startup messages)
    log: *const fn (text: [*]const u8, len: usize) callconv(cc) void,
    millis: *const fn () callconv(cc) u64,
    delay_us: *const fn (us: u32) callconv(cc) void,
    // Pages for rings and buffers the device reaches by DMA: their
    // address is their physical one
    alloc_pages: *const fn (count: usize) callconv(cc) ?[*]align(4096) u8,
    free_pages: *const fn (pages: [*]align(4096) u8, count: usize) callconv(cc) void,
    // The device's registers made reachable (uncached) at
    // their physical address; false if they can't be
    map_device: *const fn (phys: u64, len: u64) callconv(cc) bool,
    pci_read: *const fn (dev: *const Device, offset: u16) callconv(cc) u32,
    pci_write: *const fn (dev: *const Device, offset: u16, value: u32) callconv(cc) void,
    // Memory and I/O decoding and bus mastering on
    pci_enable: *const fn (dev: *const Device) callconv(cc) void,
    // \SYSTEM\DRIVERS\name (firmware for the device) into buf: its
    // length, or -1 if there is no such file
    read_file: *const fn (name: [*]const u8, len: usize, buf: [*]u8, max: usize) callconv(cc) i64,
    // A card for the network: each call adds one (up to 8; card 1
    // is the first one registered, the
    // built-in cards come after them)
    register_net: *const fn (card: *const NetCard) callconv(cc) bool,
    // The sound card programs' samples go to (the first one registered)
    register_sound: *const fn (card: *const SoundCard) callconv(cc) bool,
    // count pages (at most 16) below 16 MiB that don't cross a 64
    // KiB boundary, for ISA DMA (zeroed;
    // BIOS edition); null if there are none
    alloc_isa_dma: *const fn (count: usize) callconv(cc) ?[*]align(4096) u8,
    // The device's interrupt: MSI-X or MSI where it has them,
    // else its wired line (BIOS edition). False if there is none.
    attach_interrupt: *const fn (dev: *const Device, handler: InterruptHandler, ctx: ?*anyopaque) callconv(cc) bool,
    // A registered card's interrupts, connected when the network
    // starts; false if this ZDOS can't (the card stays polled).
    // card.ctx is control's ctx.
    net_interrupts: *const fn (card: *const NetCard, dev: *const Device, control: NetControl) callconv(cc) bool,
};

// A driver's start: true if it drives the device
pub const Init = *const fn (api: *const Api, dev: *const Device) callconv(cc) bool;
