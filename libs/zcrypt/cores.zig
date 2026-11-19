// Work on a free CPU core, else here.
// It calls no ZDOS function; its context is prepared first.
const zdos = @import("zdos");

pub fn run(comptime T: type, ctx: *T, comptime work: fn (*T) void) void {
    const Job = struct {
        fn job(arg: ?*anyopaque) callconv(zdos.cc) void {
            work(@ptrCast(@alignCast(arg.?)));
        }
    };
    const cores = zdos.table().cores;
    const count = cores.count();
    var core: u32 = 1;
    while (core < count) : (core += 1) {
        if (!cores.start(core, &Job.job, ctx)) continue; // busy: the next one
        while (cores.busy(core)) zdos.table().tasks.yield();
        return;
    }
    work(ctx);
}
