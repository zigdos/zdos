// What this platform is built with (platform.config); more of
// its choices can join the stacks here
const platform = @import("../../platform.zig");

pub const stacks: platform.Stacks = .{
    .program = 1024 * 1024,
    .thread = 256 * 1024,
    .task = 64 * 1024,
    .thread_max = 16 * 1024 * 1024,
};
