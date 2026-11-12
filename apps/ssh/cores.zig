// Work on a free CPU core (key exchange, signatures, password
// hashes), else here. It must call no ZDOS function:
// its context is prepared first.
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");

// Done when this returns. long: the wait sleeps (other tasks of
// any priority run); else it only yields to the same priority.
pub fn run(comptime T: type, ctx: *T, comptime work: fn (*T) void, long: bool) void {
    const Job = struct {
        fn job(arg: ?*anyopaque) callconv(zdos.cc) void {
            work(@ptrCast(@alignCast(arg.?)));
        }
    };
    const count = sys.coreCount();
    var core: u32 = 1;
    while (core < count) : (core += 1) {
        sys.coreStart(core, &Job.job, ctx) catch continue; // busy: the next one
        while (sys.coreBusy(core)) {
            if (long) zdos.sleep(1) else sys.taskYield();
        }
        return;
    }
    work(ctx);
}
