// CPUID identification for 32- and 64-bit x86
const std = @import("std");

pub fn cpuid(leaf: u32, sub: u32) [4]u32 {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ a, b, c, d };
}

// "Intel(R) Pentium(R) 4 CPU 2.40GHz
// (family 15, model 2, stepping 7)"
pub fn name(buf: []u8) []const u8 {
    const v = cpuid(0, 0);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], v[1], .little);
    std.mem.writeInt(u32, vendor[4..8], v[3], .little);
    std.mem.writeInt(u32, vendor[8..12], v[2], .little);

    var family: u32 = 0;
    var model: u32 = 0;
    var stepping: u32 = 0;
    if (v[0] >= 1) {
        const sig = cpuid(1, 0)[0];
        stepping = sig & 0xF;
        model = (sig >> 4) & 0xF;
        family = (sig >> 8) & 0xF;
        if (family == 0xF) family += (sig >> 20) & 0xFF;
        if (family == 0x6 or family >= 0xF) model += ((sig >> 16) & 0xF) << 4;
    }

    // The name string (Pentium 4 / Athlon and later):
    var brand_buf: [48]u8 = undefined;
    var brand: []const u8 = "";
    if (cpuid(0x8000_0000, 0)[0] >= 0x8000_0004) {
        for (0..3) |i| {
            const r = cpuid(0x8000_0002 + @as(u32, @intCast(i)), 0);
            for (r, 0..) |reg, j| std.mem.writeInt(u32, brand_buf[i * 16 + j * 4 ..][0..4], reg, .little);
        }
        brand = std.mem.trim(u8, std.mem.sliceTo(&brand_buf, 0), " ");
    }

    if (brand.len > 0) {
        return std.fmt.bufPrint(buf, "{s} (family {d}, model {d}, stepping {d})", .{ brand, family, model, stepping }) catch buf[0..0];
    }
    const known = if (std.mem.eql(u8, &vendor, "GenuineIntel")) intelName(family, model) else null;
    return std.fmt.bufPrint(buf, "{s}{s}{s} (family {d}, model {d}, stepping {d})", .{
        &vendor, if (known != null) " " else "", known orelse "", family, model, stepping,
    }) catch buf[0..0];
}

// Intel CPUs from before the name string.
fn intelName(family: u32, model: u32) ?[]const u8 {
    return switch (family) {
        4 => "486",
        5 => if (model == 4 or model == 8) "Pentium MMX" else "Pentium",
        6 => switch (model) {
            1 => "Pentium Pro",
            3, 5 => "Pentium II",
            6 => "Celeron",
            7, 8, 0xB => "Pentium III",
            0xA => "Pentium III Xeon",
            else => null,
        },
        else => null,
    };
}
