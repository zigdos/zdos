// What this platform is built with (platform.config); more of
// its choices can join the stacks here
const platform = @import("../../platform.zig");

pub const stacks: platform.Stacks = .{
    .program = 1024 * 1024,
    .thread = 256 * 1024,
    .task = 64 * 1024,
    .thread_max = 16 * 1024 * 1024,
};

// IDE hard disks through ZDOS's own ATA driver
// (drivers/ata.zig) instead of int 13h;
// false: the BIOS for all disks, as before
pub const own_ide = true;

// SATA disks on AHCI controllers through drivers/pcie/ahci.zig
// (sata.zig) instead of int 13h;
// false: the BIOS for them, as before
pub const own_sata = true;

// The scheduler's deadlines on core 0's local APIC timer,
// where the BIOS left the APIC on (else, or false:
// the PIT in one-shot mode)
pub const lapic_timer = true;

// Tasks on the other cores too, as on metal (B4:
// needs lapic_timer); false: tasks on core 0, the others for
// programs' jobs and the network
pub const tasks_on_all_cores = true;
