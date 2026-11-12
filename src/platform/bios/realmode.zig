// BIOS calls from protected mode through bios_call in stage2.s,
// which drops to real mode, runs "int n" with these registers
// and returns the results. The BIOS only reaches the first MiB:
// data goes through stage 2's bounce buffer
// (64 KiB) or scratch area (512 bytes).
const pic = @import("pic.zig");

// Must match the register block in stage2.s
pub const Regs = extern struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    ebp: u32 = 0,
    ds: u32 = 0,
    es: u32 = 0,
    eflags: u32 = 0, // after the call

    pub fn carry(self: *const Regs) bool {
        return self.eflags & 1 != 0;
    }

    pub fn ah(self: *const Regs) u8 {
        return @truncate(self.eax >> 8);
    }
};

// Must match boot_info in stage2.s
pub const BootInfo = extern struct {
    magic: u32, // "ZDOS"
    bios_call: *const fn (int_no: u32, regs: *Regs) callconv(.c) void,
    e820_count: u32,
    e820_map: u32, // address of the memory map entries
    bounce: u32,
    bounce_size: u32,
    scratch: u32,
    boot_drive: u32, // BIOS drive number ZDOS was started from (0x80 = first hard disk)
    boot_lba: u32, // first sector of the FAT volume ZDOS was started from
};

pub const boot_info_magic = 0x534F445A;
pub const scratch_size = 512;

pub var info: *const BootInfo = undefined;

// The PICs and the PIT as the BIOS expects them, for the call.
// Interrupts off throughout: no task switch while the PICs are
// the BIOS's or in real mode (the
// BIOS's own handlers run there).
pub fn call(int_no: u8, regs: *Regs) void {
    // On core 0 (tasks run on every core: B4)
    const saved = if (@import("../../platform.zig").core0_enter) |f| f() else 0;
    defer if (@import("../../platform.zig").core0_leave) |f| f(saved);
    // switching.zig's hooks: the local APIC's timer off
    // for the call (its vector means nothing to the
    // real-mode table), and core 0 sealed against IPIs
    // (interrupts off, none pending; else those taken
    // first, and again):
    var flags: u32 = undefined;
    while (true) {
        if (before_call) |f| f();
        flags = asm volatile ("pushfl; popl %[f]; cli"
            : [f] "=r" (-> u32),
            :
            : "memory"
        );
        const seal = seal_call orelse break;
        if (seal(flags & 0x200 != 0)) break;
        asm volatile ("sti" ::: "memory");
    }
    pic.toBios();
    info.bios_call(int_no, regs);
    pic.toZdos();
    @import("../../arch/x86.zig").reloadThreadPointer(); // the call reset GS
    if (flags & 0x200 != 0) asm volatile ("sti" ::: "memory");
    if (after_call) |f| f();
}

pub var before_call: ?*const fn () void = null;
// Interrupts off: false to try again (IPIs pending)
pub var seal_call: ?*const fn (if_on: bool) bool = null;
pub var after_call: ?*const fn () void = null;

pub fn bounce() []u8 {
    const p: [*]u8 = @ptrFromInt(info.bounce);
    return p[0..info.bounce_size];
}

pub fn scratch() *[scratch_size]u8 {
    return @ptrFromInt(info.scratch);
}

// Real-mode segment:offset of a buffer below 1 MiB
pub fn segment(addr: usize) u32 {
    return @intCast(addr >> 4);
}

pub fn offset(addr: usize) u32 {
    return @intCast(addr & 0xF);
}
