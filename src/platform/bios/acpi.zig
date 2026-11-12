// ACPI table lookup for the BIOS edition: RSDP in the BIOS
// area, then the RSDT or XSDT, then a table by signature.
// Used for the FADT's century register.
// No paging, so the addresses are physical.
const std = @import("std");

const rsdp_sig = "RSD PTR ";
const sdt_header = 36; // a system description table's header; the RSDP v2 is 36 bytes too
const max_table = 1 << 20; // no table is this big: a bigger length is garbage

fn bytesAt(addr: usize, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(addr))[0..len];
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

// Every ACPI structure's bytes add up to 0 (mod 256)
fn sumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

// The RSDP: in the first KB of the Extended BIOS Data Area (its
// segment is the word at 0x40E) or on
// a 16-byte boundary in 0xE0000-0xFFFFF
fn findRsdp() ?[]const u8 {
    const ebda = @as(usize, @as(*const u16, @ptrFromInt(0x40E)).*) << 4;
    if (ebda >= 0x80000 and ebda < 0xA0000) {
        if (scanForRsdp(ebda, 1024)) |rsdp| return rsdp;
    }
    return scanForRsdp(0xE0000, 0x20000);
}

fn scanForRsdp(start: usize, len: usize) ?[]const u8 {
    var addr = start;
    while (addr + 20 <= start + len) : (addr += 16) {
        if (!std.mem.eql(u8, bytesAt(addr, 8), rsdp_sig)) continue;
        const head = bytesAt(addr, 24);
        if (!sumOk(head[0..20])) continue; // the ACPI 1.0 part
        if (head[15] < 2) return head[0..20]; // revision 0: no XSDT
        const size = readU32(head, 20);
        if (size < sdt_header or size > 256) continue;
        const full = bytesAt(addr, size);
        if (sumOk(full)) return full;
    }
    return null;
}

// The table at a physical address, if its length is sane and
// its checksum is right.
// Addresses above 4 GB can't be read without paging.
fn tableAt(addr: u64) ?[]const u8 {
    if (addr == 0 or addr > std.math.maxInt(u32)) return null;
    const at: usize = @intCast(addr);
    const size = readU32(bytesAt(at, 8), 4);
    if (size < sdt_header or size > max_table) return null;
    const table = bytesAt(at, size);
    return if (sumOk(table)) table else null;
}

// The table with the signature among the root table's entries
// (4-byte addresses in the RSDT, 8-byte ones in the XSDT)
fn findInRoot(root: []const u8, entry_size: usize, sig: *const [4]u8) ?[]const u8 {
    var off: usize = sdt_header;
    while (off + entry_size <= root.len) : (off += entry_size) {
        const addr: u64 = if (entry_size == 8) readU64(root, off) else readU32(root, off);
        const table = tableAt(addr) orelse continue;
        if (std.mem.eql(u8, table[0..4], sig)) return table;
    }
    return null;
}

// The ACPI table with the 4-letter signature, e.g. "FACP" for the FADT
pub fn findTable(sig: *const [4]u8) ?[]const u8 {
    const rsdp = findRsdp() orelse return null;
    if (rsdp.len >= 36) { // ACPI 2.0 and later: the XSDT
        if (tableAt(readU64(rsdp, 24))) |xsdt| {
            if (std.mem.eql(u8, xsdt[0..4], "XSDT")) {
                if (findInRoot(xsdt, 8, sig)) |table| return table;
            }
        }
    }
    const rsdt = tableAt(readU32(rsdp, 16)) orelse return null;
    if (!std.mem.eql(u8, rsdt[0..4], "RSDT")) return null;
    return findInRoot(rsdt, 4, sig);
}

// The CMOS register that holds the century: the FADT's CENTURY
// byte (offset 108). Null if there is none: no ACPI, a FADT too
// short for it, or 0.
// The register is never one of the clock's own (0x00-0x0D).
pub fn centuryRegister() ?u8 {
    const fadt = findTable("FACP") orelse return null;
    // By the table's length, as ACPICA and Linux do:
    // firmware fills the byte in before ACPI 2.0 too
    // (SeaBIOS: revision 1, length 116):
    if (fadt.len < 109) return null;
    const reg = fadt[108];
    if (reg < 0x0E or reg > 0x7F) return null;
    return reg;
}
