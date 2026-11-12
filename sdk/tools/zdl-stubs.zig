// Import stubs for C programs calling a .ZDL's functions by name
// (run by bin/zdos-stubs):
//   zdl-stubs <x86_64 | x86 | arm64> <NAME> <functions.txt> <out.s>
// Each stub jumps through the table; an entry in .zdos_imports makes
// the program's start-up load NAME.ZDL and fill the table in.
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len != 5) {
        std.debug.print("usage: zdl-stubs <x86_64 | x86 | arm64> <NAME> <functions.txt> <out.s>\n", .{});
        std.process.exit(1);
    }
    const arch = args[1];
    const name = args[2];
    const list = try std.fs.cwd().readFileAlloc(alloc, args[3], 1 << 20);
    var out: std.ArrayListUnmanaged(u8) = .{};
    const w = out.writer(alloc);

    const ptr: usize = if (std.mem.eql(u8, arch, "x86")) 4 else 8;
    const word = if (ptr == 4) ".long" else ".quad";
    try w.print("# Import stubs for {s}.ZDL (sdk/tools/zdl-stubs.zig)\n", .{name});
    try w.print(".section .rodata\nzdos_{s}_name:\n    .asciz \"{s}\"\n", .{ name, name });
    try w.print(".section .bss\n.balign {d}\nzdos_{s}_table:\n    .zero {d}\n", .{ ptr, name, ptr });
    try w.print(".section .zdos_imports,\"aw\"\n.balign {d}\n    {s} zdos_{s}_name\n    {s} zdos_{s}_table\n", .{ ptr, word, name, word, name });
    // The C runtime the program offers its libraries: an entry with
    // an empty name; the reference also links it in:
    try w.print("    {s} zdos_{s}_runtime_name\n    {s} zdos_runtime_offer\n", .{ word, name, word });
    try w.print(".section .rodata\nzdos_{s}_runtime_name:\n    .byte 0\n", .{name});
    try w.print(".text\n", .{});

    var slot: usize = 1;
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        const off = slot * ptr;
        var names = std.mem.tokenizeAny(u8, line, " \t");
        while (names.next()) |fname| try stub(w, arch, name, fname, off);
        slot += 1;
    }
    try std.fs.cwd().writeFile(.{ .sub_path = args[4], .data = out.items });
}

fn stub(w: anytype, arch: []const u8, name: []const u8, line: []const u8, off: usize) !void {
    {
        try w.print(".global {s}\n.type {s}, @function\n{s}:\n", .{ line, line, line });
        if (std.mem.eql(u8, arch, "x86_64")) {
            // r11: scratch in both conventions (rax: a variadic call's count):
            try w.print("    movq zdos_{s}_table(%rip), %r11\n    jmp *{d}(%r11)\n", .{ name, off });
        } else if (std.mem.eql(u8, arch, "x86")) {
            // No pc-relative loads in 32-bit code: the return address finds it:
            try w.print("    call 1f\n1:  popl %eax\n    movl zdos_{s}_table-1b(%eax), %eax\n    jmp *{d}(%eax)\n", .{ name, off });
        } else if (std.mem.eql(u8, arch, "arm64")) {
            try w.print("    adrp x16, zdos_{s}_table\n    ldr x16, [x16, :lo12:zdos_{s}_table]\n    ldr x16, [x16, #{d}]\n    br x16\n", .{ name, name, off });
        } else {
            std.debug.print("unknown CPU {s}\n", .{arch});
            std.process.exit(1);
        }
    }
}
