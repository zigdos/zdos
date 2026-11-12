// RTL8169.SYS: Realtek's PCIe 1 and 2.5 gigabit cards. RTL8168/8111 G, GU, EP,
// H, FP, 8411B and 8125A/B are set up as if_re.c (Realtek's FreeBSD driver),
// others named and left alone. 128 receive and 64 transmit descriptors;
// MSI-X or MSI where ZDOS connects them, else polled. QEMU has no such
// card.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("drv");
const phy = @import("rtl8169/phy.zig");

export const zdos_driver_ids = [_]drv.PciId{
    .{ .vendor = 0x10EC, .device = 0x8168 }, // RTL8168/8111 (most onboard LAN)
    .{ .vendor = 0x10EC, .device = 0x8161 }, // RTL8168 add-on cards
    .{ .vendor = 0x10EC, .device = 0x8162 }, // RTL8168KB
    .{ .vendor = 0x10EC, .device = 0x8125 }, // RTL8125 2.5GbE
    .{ .vendor = 0x10EC, .device = 0x3000 }, // Killer E3000 (8125B)
    .{ .vendor = 0x10EC, .device = 0x2600 }, // Killer E2600 (8168)
    .{ .vendor = 0x10EC, .device = 0x2502 }, // Killer E2500 (8168)
    .{ .vendor = 0x10EC, .device = 0x8126 }, // RTL8126 5GbE (named only)
    .{ .vendor = 0x10EC, .device = 0x8127 }, // RTL8127 10GbE (named only)
    .{ .vendor = 0x10EC, .device = 0x8136 }, // RTL8101/8102/8105/8106 (named only)
    .{ .vendor = 0x10EC, .device = 0x8169 }, // RTL8169 PCI (named only)
    .{ .vendor = 0x10EC, .device = 0x8167 }, // RTL8169SC PCI (named only)
    .{ .vendor = 0x10FF, .device = 0x8168 }, // NCube
    .{ .vendor = 0x1186, .device = 0x4300 }, // D-Link DGE-528T (8169)
    .{ .vendor = 0, .device = 0 },
};

var api: *const drv.Api = undefined;
var regs: usize = 0;
var pci: *const drv.Device = undefined;

// REGISTERS: explicit widths, a volatile struct field may be read
// narrower than the device wants

fn rd(off: usize, comptime T: type) T {
    const a = regs + off;
    const v: u32 = switch (builtin.cpu.arch) {
        .x86_64, .x86 => switch (T) {
            u8 => asm volatile ("movzbl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("movzwl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("movl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
        },
        .aarch64 => switch (T) {
            u8 => asm volatile ("ldrb %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("ldrh %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("ldr %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
        },
        else => @compileError("RTL8169.SYS: x86 and ARM64 only"),
    };
    return @truncate(v);
}

fn wr(off: usize, comptime T: type, v: T) void {
    const a = regs + off;
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => switch (T) {
            u8 => asm volatile ("movb %[v], (%[a])"
                :
                : [v] "q" (v),
                  [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("movw %[v], (%[a])"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("movl %[v], (%[a])"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
        },
        .aarch64 => {
            const w: u32 = v;
            switch (T) {
                u8 => asm volatile ("dsb sy\n strb %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
                u16 => asm volatile ("dsb sy\n strh %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
                else => asm volatile ("dsb sy\n str %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
            }
        },
        else => @compileError("RTL8169.SYS: x86 and ARM64 only"),
    }
}

fn r8(off: usize) u8 {
    return rd(off, u8);
}
fn r16(off: usize) u16 {
    return rd(off, u16);
}
fn r32(off: usize) u32 {
    return rd(off, u32);
}
fn w8(off: usize, v: u8) void {
    wr(off, u8, v);
}
fn w16(off: usize, v: u16) void {
    wr(off, u16, v);
}
fn w32(off: usize, v: u32) void {
    wr(off, u32, v);
}
fn bits8(off: usize, clear: u8, set: u8) void {
    w8(off, (r8(off) & ~clear) | set);
}

// Read card descriptors only after the word that said so; write ours
// before the word that hands them over.
pub fn delayUs(us: u32) void {
    api.delay_us(us);
}

fn readBarrier() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb oshld" ::: "memory"),
        else => asm volatile ("" ::: "memory"),
    }
}
fn writeBarrier() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dmb oshst" ::: "memory"),
        else => asm volatile ("" ::: "memory"),
    }
}

// Until (value & mask != 0) == set, steps of us.
fn wait32(off: usize, mask: u32, set: bool, steps: u32, us: u32) bool {
    for (0..steps) |_| {
        if ((r32(off) & mask != 0) == set) return true;
        api.delay_us(us);
    }
    return false;
}

const IDR0 = 0x00;
const MAR0 = 0x08;
const TX_DESC = 0x20; // 64-bit address
const CR = 0x37;
const TPPOLL = 0x38;
const IMR = 0x3C;
const ISR = 0x3E;
const TXCFG = 0x40;
const RXCFG = 0x44;
const CFG9346 = 0x50;
const CFG1 = 0x52;
const CFG2 = 0x53;
const CFG3 = 0x54;
const CFG5 = 0x56;
const TDFNR = 0x57;
const PHYAR = 0x60;
const PHY_STATUS = 0x6C;
const PMCH = 0x6F;
const ERIDR = 0x70;
const ERIAR = 0x74;
const EPHYAR = 0x80;
const MAC_OCP = 0xB0;
const PHY_OCP = 0xB8;
const MCU_CMD = 0xD3;
const RX_MAX_SIZE = 0xDA;
const CPLUS_CMD = 0xE0;
const INTR_MITIGATE = 0xE2;
const RX_DESC = 0xE4; // 64-bit address
const MTPS = 0xEC;
// 8125:
const INT_CFG0_8125 = 0x34;
const IMR_8125 = 0x38;
const ISR_8125 = 0x3C;
const INT_CFG1_8125 = 0x7A;
const TPPOLL_8125 = 0x90;
const BACKUP_ADDR_8125 = 0x19E0;
const EEE_TXIDLE_8125 = 0x6048;

const cr_reset = 0x10;
const cr_rx = 0x08;
const cr_tx = 0x04;
const cr_stop_req = 0x80;
const rx_accept_own = 0x02;
const rx_accept_broadcast = 0x08;
const rx_accept_bits: u32 = 0x3F; // all, own, multi, broad, runts, errors
const link_ok = 0x02; // PHY_STATUS
const full_duplex = 0x01;
const status_10m = 0x04;
const txcfg_default: u32 = 0x03000780; // standard gap, 2 KiB DMA bursts
// Interrupt causes: receive OK and error, no free receive
// descriptor, link change, FIFO overflow (sends are checked when
// the next goes); the same bits in the 8125's old mapping
const int_causes: u16 = 0x0001 | 0x0002 | 0x0010 | 0x0020 | 0x0040;

// THE CHIP: TxConfig & 0xFCF00000, if_re.c's MACFG number

var mac: u8 = 0;

const Chip = struct { ver: u32, mac: u8, name: []const u8 };
const chips = [_]Chip{
    .{ .ver = 0x00800000, .mac = 3, .name = "8169S" },
    .{ .ver = 0x04000000, .mac = 3, .name = "8169S" },
    .{ .ver = 0x10000000, .mac = 4, .name = "8169SB" },
    .{ .ver = 0x18000000, .mac = 5, .name = "8169SC" },
    .{ .ver = 0x98000000, .mac = 6, .name = "8169SC" },
    .{ .ver = 0x34000000, .mac = 11, .name = "8101E" },
    .{ .ver = 0xB4000000, .mac = 11, .name = "8101E" },
    .{ .ver = 0x34200000, .mac = 12, .name = "8101E" },
    .{ .ver = 0xB4200000, .mac = 12, .name = "8101E" },
    .{ .ver = 0x34300000, .mac = 13, .name = "8101E" },
    .{ .ver = 0xB4300000, .mac = 13, .name = "8101E" },
    .{ .ver = 0x34900000, .mac = 14, .name = "8102E" },
    .{ .ver = 0x24900000, .mac = 14, .name = "8102E" },
    .{ .ver = 0x34A00000, .mac = 15, .name = "8102E" },
    .{ .ver = 0x24A00000, .mac = 15, .name = "8102E" },
    .{ .ver = 0x34B00000, .mac = 16, .name = "8103E" },
    .{ .ver = 0x24B00000, .mac = 16, .name = "8103E" },
    .{ .ver = 0x34C00000, .mac = 17, .name = "8103E" },
    .{ .ver = 0x24C00000, .mac = 17, .name = "8103E" },
    .{ .ver = 0x34D00000, .mac = 18, .name = "8103E" },
    .{ .ver = 0x24D00000, .mac = 18, .name = "8103E" },
    .{ .ver = 0x34E00000, .mac = 19, .name = "8103E" },
    .{ .ver = 0x24E00000, .mac = 19, .name = "8103E" },
    .{ .ver = 0x30000000, .mac = 21, .name = "8168B" },
    .{ .ver = 0x38000000, .mac = 22, .name = "8168B" },
    .{ .ver = 0x38500000, .mac = 23, .name = "8168B" },
    .{ .ver = 0xB8500000, .mac = 23, .name = "8168B" },
    .{ .ver = 0x38700000, .mac = 23, .name = "8168B" },
    .{ .ver = 0xB8700000, .mac = 23, .name = "8168B" },
    .{ .ver = 0x3C000000, .mac = 24, .name = "8168C" },
    .{ .ver = 0x3C200000, .mac = 25, .name = "8168C" },
    .{ .ver = 0x3C400000, .mac = 26, .name = "8168C" },
    .{ .ver = 0x3C900000, .mac = 27, .name = "8168CP" },
    .{ .ver = 0x3CB00000, .mac = 28, .name = "8168CP" },
    .{ .ver = 0x28100000, .mac = 31, .name = "8168D" },
    .{ .ver = 0x28200000, .mac = 32, .name = "8168D" },
    .{ .ver = 0x28300000, .mac = 33, .name = "8168D" },
    .{ .ver = 0x2C100000, .mac = 36, .name = "8168E" },
    .{ .ver = 0x2C200000, .mac = 37, .name = "8168E" },
    .{ .ver = 0x2C800000, .mac = 38, .name = "8168E-VL" },
    .{ .ver = 0x2C900000, .mac = 39, .name = "8168E-VL" },
    .{ .ver = 0x24000000, .mac = 41, .name = "8401" },
    .{ .ver = 0x40900000, .mac = 42, .name = "8105E" },
    .{ .ver = 0x40A00000, .mac = 43, .name = "8105E" },
    .{ .ver = 0x40B00000, .mac = 43, .name = "8105E" },
    .{ .ver = 0x40C00000, .mac = 43, .name = "8105E" },
    .{ .ver = 0x48000000, .mac = 50, .name = "8168F" },
    .{ .ver = 0x48100000, .mac = 51, .name = "8168F" },
    .{ .ver = 0x48800000, .mac = 52, .name = "8411" },
    .{ .ver = 0x44000000, .mac = 53, .name = "8402" },
    .{ .ver = 0x44800000, .mac = 54, .name = "8106E" },
    .{ .ver = 0x44900000, .mac = 55, .name = "8106E" },
    .{ .ver = 0x4C000000, .mac = 56, .name = "8168G" },
    .{ .ver = 0x4C100000, .mac = 57, .name = "8168G" },
    .{ .ver = 0x50800000, .mac = 58, .name = "8168GU" },
    .{ .ver = 0x50900000, .mac = 59, .name = "8168GU" },
    .{ .ver = 0x5C800000, .mac = 60, .name = "8411B" },
    .{ .ver = 0x50000000, .mac = 61, .name = "8168EP" },
    .{ .ver = 0x50100000, .mac = 62, .name = "8168EP" },
    .{ .ver = 0x50200000, .mac = 67, .name = "8168EP" },
    .{ .ver = 0x28800000, .mac = 63, .name = "8168DP" },
    .{ .ver = 0x28900000, .mac = 64, .name = "8168DP" },
    .{ .ver = 0x28A00000, .mac = 65, .name = "8168DP" },
    .{ .ver = 0x28B00000, .mac = 66, .name = "8168DP" },
    .{ .ver = 0x54000000, .mac = 68, .name = "8168H" },
    .{ .ver = 0x54100000, .mac = 69, .name = "8168H" }, // or 74, 75: below
    .{ .ver = 0x6C000000, .mac = 76, .name = "8168M" },
    .{ .ver = 0x54900000, .mac = 70, .name = "8168FP" },
    .{ .ver = 0x54A00000, .mac = 71, .name = "8168FP" },
    .{ .ver = 0x54B00000, .mac = 72, .name = "8168FP" },
    .{ .ver = 0x54C00000, .mac = 73, .name = "8168FP" },
    .{ .ver = 0x60800000, .mac = 80, .name = "8125A" },
    .{ .ver = 0x60900000, .mac = 81, .name = "8125A" },
    .{ .ver = 0x64000000, .mac = 82, .name = "8125B" },
    .{ .ver = 0x64100000, .mac = 83, .name = "8125B" },
    .{ .ver = 0x68000000, .mac = 84, .name = "8125BP" },
    .{ .ver = 0x68100000, .mac = 85, .name = "8125BP" },
    .{ .ver = 0x68800000, .mac = 86, .name = "8125D" },
    .{ .ver = 0x68900000, .mac = 87, .name = "8125D" },
    .{ .ver = 0x68A00000, .mac = 120, .name = "8125D" },
    .{ .ver = 0x68B00000, .mac = 89, .name = "9151A" },
    .{ .ver = 0x70800000, .mac = 88, .name = "8125CP" },
    .{ .ver = 0x64800000, .mac = 90, .name = "8126A" },
    .{ .ver = 0x64900000, .mac = 91, .name = "8126A" },
    .{ .ver = 0x64A00000, .mac = 92, .name = "8126A" },
    .{ .ver = 0x6C800000, .mac = 100, .name = "8127" },
    .{ .ver = 0x6C900000, .mac = 101, .name = "8127" },
};

fn is8125() bool {
    return mac >= 80 and mac <= 83;
}
fn isG() bool { // 8168G, GU and 8411B
    return mac >= 56 and mac <= 60;
}
fn isEP() bool {
    return mac == 61 or mac == 62 or mac == 67;
}
fn isH() bool { // 8168H and its 74/75 revisions, 8168M
    return mac == 68 or mac == 69 or mac == 74 or mac == 75 or mac == 76;
}
fn isFP() bool {
    return mac >= 70 and mac <= 73;
}
fn supported() bool {
    return isG() or isEP() or isH() or isFP() or is8125();
}

// From the chip's fuses and straps (if_re.c's software variables):
pub var adc_bias: ?u16 = null; // 8168H
pub var mdi_swap = false; // 8125A-2
var serdes: u8 = 0; // 8168FP on a SerDes (fibre) port
var pkg: u16 = 0; // 8168FP package
var swr_cnt_1ms: ?u16 = null; // 8168H, FP: UPS link pulse timing

// INDIRECT REGISTERS: PHY (MDIO PAGED, OR OCP), MAC OCP, ERI, PCIE PHY

var phy_page: u16 = 0;

pub fn ocpWrite(addr: u16, v: u16) void {
    w32(PHY_OCP, 0x8000_0000 | @as(u32, addr / 2) << 16 | v);
    _ = wait32(PHY_OCP, 0x8000_0000, false, 100, 1);
}

pub fn ocpRead(addr: u16) u16 {
    w32(PHY_OCP, @as(u32, addr / 2) << 16);
    _ = wait32(PHY_OCP, 0x8000_0000, true, 100, 1);
    return @truncate(r32(PHY_OCP));
}

pub fn ocpBits(addr: u16, clear: u16, set: u16) void {
    ocpWrite(addr, (ocpRead(addr) & ~clear) | set);
}

// reg of the page chosen by writing 0x1F, as an OCP address (page 0:
// the standard registers at 0xA400).
fn ocpOf(reg: u16) u16 {
    var page = phy_page;
    var r = reg;
    if (page == 0) {
        page = 0x0A40 + reg / 8;
        r = 0x10 + reg % 8;
    }
    if (r < 16) return 0;
    return (page << 4) + (r - 16) * 2;
}

pub fn mdioWrite(reg: u16, v: u16) void {
    if (reg == 0x1F) {
        phy_page = v;
        return;
    }
    ocpWrite(ocpOf(reg), v);
}

pub fn mdioRead(reg: u16) u16 {
    return ocpRead(ocpOf(reg));
}

pub fn phyBits(reg: u16, clear: u16, set: u16) void {
    mdioWrite(reg, (mdioRead(reg) & ~clear) | set);
}

fn macOcpWrite(addr: u16, v: u16) void {
    w32(MAC_OCP, 0x8000_0000 | @as(u32, addr / 2) << 16 | v);
}

fn macOcpRead(addr: u16) u16 {
    w32(MAC_OCP, @as(u32, addr / 2) << 16);
    return @truncate(r32(MAC_OCP));
}

fn macOcpBits(addr: u16, clear: u16, set: u16) void {
    macOcpWrite(addr, (macOcpRead(addr) & ~clear) | set);
}

// Extended GMAC registers: len bytes within one 32-bit word.
fn eriRead(addr: u16, len: u5) u32 {
    const shift: u5 = @intCast((addr & 3) * 8);
    w32(ERIAR, 0xF000 | @as(u32, addr & ~@as(u16, 3)));
    _ = wait32(ERIAR, 0x8000_0000, true, 10, 100);
    const v = r32(ERIDR) >> shift;
    return if (len == 4) v else v & ((@as(u32, 1) << (len * 8)) - 1);
}

fn eriWrite(addr: u16, len: u5, v: u32) void {
    const shift: u5 = @intCast((addr & 3) * 8);
    const mask: u32 = if (len == 4) 0xFFFF_FFFF else ((@as(u32, 1) << (len * 8)) - 1) << shift;
    const word = (eriRead(addr & ~@as(u16, 3), 4) & ~mask) | ((v << shift) & mask);
    w32(ERIDR, word);
    w32(ERIAR, 0x8000_F000 | @as(u32, addr & ~@as(u16, 3)));
    _ = wait32(ERIAR, 0x8000_0000, false, 10, 100);
}

fn eriBits(addr: u16, len: u5, clear: u32, set: u32) void {
    eriWrite(addr, len, (eriRead(addr, len) & ~clear) | set);
}

fn ephyAddr(addr: u16) u16 {
    // 74, 75: registers above 0x1F through a window:
    if (mac == 74 or mac == 75) {
        macOcpBits(0xDE28, 0x03, (addr >> 5) & 0x03);
        return addr & 0x1F;
    }
    return addr;
}

pub fn ephyWrite(addr: u16, v: u16) void {
    w32(EPHYAR, 0x8000_0000 | @as(u32, ephyAddr(addr)) << 16 | v);
    _ = wait32(EPHYAR, 0x8000_0000, false, 500, 10);
}

fn ephyRead(addr: u16) u16 {
    w32(EPHYAR, @as(u32, ephyAddr(addr)) << 16);
    _ = wait32(EPHYAR, 0x8000_0000, true, 500, 10);
    return @truncate(r32(EPHYAR));
}

pub fn ephyBits(addr: u16, clear: u16, set: u16) void {
    ephyWrite(addr, (ephyRead(addr) & ~clear) | set);
}

// Set while the PHY microcontroller's registers change.
pub fn patchRequest(on: bool) void {
    if (is8125()) {
        ocpBits(0xB820, 0x0010, if (on) 0x0010 else 0);
        for (0..1000) |_| {
            if ((ocpRead(0xB800) & 0x0040 != 0) == on) break;
            api.delay_us(100);
        }
    } else {
        mdioWrite(0x1F, 0x0B82);
        phyBits(0x10, 0x0010, if (on) 0x0010 else 0);
        mdioWrite(0x1F, 0x0B80);
        for (0..1000) |_| {
            if ((mdioRead(0x10) & 0x0040 != 0) == on) break;
            api.delay_us(100);
        }
        mdioWrite(0x1F, 0);
    }
}

fn unlockConfig() void {
    w8(CFG9346, r8(CFG9346) | 0xC0);
}
fn lockConfig() void {
    w8(CFG9346, r8(CFG9346) & ~@as(u8, 0xC0));
}

// ASPM and clock request off (if_re.c's default); config unlocked.
fn noAspm() void {
    bits8(CFG5, 0x01, 0);
    bits8(CFG2, 0x80, 0);
    bits8(0xF1, 0x80, 0); // forced clock request
}

fn phyStatus() u32 {
    return if (is8125()) r32(PHY_STATUS) else r8(PHY_STATUS);
}

// BRING-UP (if_re.c's re_exit_oob, re_hw_init, re_hw_common)

// The chip's out of band management firmware lets go of it.
fn exitOob() void {
    lockConfig();
    if (serdes == 1) { // SGMII
        macOcpWrite(0xEB00, 0x2);
        macOcpBits(0xEB16, 0, 0x0002);
    }
    if (isEP()) { // DASH's own transmit and receive off (CMAC registers)
        bits8(0xF9, 0x01, 0);
        for (0..2000) |_| {
            if (r8(0xFB) & 0x20 != 0) break;
            api.delay_us(50);
        }
        w8(0xFB, r8(0xFB) | 0x20);
        bits8(0xF8, 0x01, 0);
    }

    bits8(0xF2, 0, 0x08);
    api.delay_us(2000);
    if (!is8125()) _ = wait32(TXCFG, 1 << 11, true, 3000, 50);
    if (r8(CR) & (cr_rx | cr_tx) != 0) {
        api.delay_us(100);
        bits8(CR, cr_rx | cr_tx, 0);
    }
    if (mac == 82 or mac == 83) bits8(CR, 0, cr_stop_req);
    fifosEmpty();
    if (mac == 82 or mac == 83) {
        for (0..3000) |_| {
            if (r16(INTR_MITIGATE) & 0x0103 == 0x0103) break;
            api.delay_us(50);
        }
    }

    // The MAC microcontroller's packet filter reset:
    if (is8125()) {
        macOcpBits(0xC0B4, 0x0001, 0);
        macOcpBits(0xC0B4, 0, 0x0001);
    } else {
        eriBits(0xDC, 4, 0x01, 0);
        eriBits(0xDC, 4, 0, 0x01);
    }

    // Wake on LAN's own processing off:
    if (mac == 56 or mac == 57) {
        w32(MAC_OCP, 0x605E0000);
        w32(MAC_OCP, (0xE05E << 16) | (r32(MAC_OCP) & 0xFFFE));
        w32(MAC_OCP, 0xE9720000);
        w32(MAC_OCP, 0xF2140010);
    } else if (mac == 60) {
        w32(MAC_OCP, 0xE05E00FF);
        w32(MAC_OCP, 0xE9720000);
        macOcpWrite(0xE428, 0x0010);
    }

    bits8(MCU_CMD, 0x80, 0); // now is OOB: no

    macOcpBits(0xE8DE, 0x4000, 0);
    linkListReady();
    if (is8125()) {
        macOcpWrite(0xC0AA, 0x07D0);
        macOcpWrite(0xC0A6, 0x01B5);
        macOcpWrite(0xC01E, 0x5555);
    } else {
        macOcpBits(0xE8DE, 0, 0x8000);
    }
    linkListReady();

    // Back from UPS (the PHY's own power state): wait until ready:
    if (is8125() or isH() and mac != 76 or isFP()) {
        if (upsResume()) {
            waitPhyState(2);
            if (is8125()) macOcpBits(0xD42C, 0x0100, 0) else macOcpBits(0xD408, 0x0001, 0);
            if (mac == 82 or mac == 83) ocpBits(0xA466, 0x0001, 0);
            if (is8125()) ocpBits(0xA468, 0x000A, 0);
        }
    }
}

fn fifosEmpty() void {
    for (0..3000) |_| {
        if (r8(MCU_CMD) & 0x30 == 0x30) break;
        api.delay_us(50);
    }
}

fn linkListReady() void {
    for (0..10) |_| {
        api.delay_us(100);
        if (r16(0xD2) & 0x0200 != 0) break;
    }
}

fn upsResume() bool {
    return if (is8125()) macOcpRead(0xD42C) & 0x0100 != 0 else macOcpRead(0xD408) & 0x0001 != 0;
}

fn waitPhyState(state: u16) void {
    for (0..100) |_| {
        if (ocpRead(0xA420) & 0x7 == state) return;
        api.delay_us(1000);
    }
}

// Receiving off, interrupts masked and acknowledged, the chip reset.
fn stop() void {
    w32(RXCFG, r32(RXCFG) & ~rx_accept_bits);
    if (is8125()) {
        w32(IMR_8125, 0);
        w32(ISR_8125, 0xFFFF_FFFF);
        if (mac >= 82) { // new mapping, if the firmware chose it
            w32(0x0D00, 0xFFFF_FFFF);
            w32(0x0D04, 0xFFFF_FFFF);
        }
    } else {
        w16(IMR, 0);
        w16(ISR, 0xFFFF);
    }
    api.delay_us(2200);
    w8(CR, cr_reset);
    for (0..1000) |_| {
        if (r8(CR) & cr_reset == 0) break;
        api.delay_us(10);
    }
    if (mac == 74 or mac == 75) {
        macOcpBits(0xD438, 0, 0x0008);
        macOcpBits(0xD438, 0, 0x0004);
        macOcpBits(0xDE28, 0x0003, 0);
        macOcpBits(0xD438, 0, 0x0003);
    }
}

// The MAC's part of Energy Efficient Ethernet.
fn eeePlus(on: bool) void {
    if (is8125()) {
        macOcpBits(0xE080, 0x0002, if (on) 0x0002 else 0);
    } else {
        eriBits(0x1D0, 1, 0x02, if (on) 0x02 else 0);
    }
}

fn phyPowerUp() void {
    if (mac != 76) bits8(PMCH, 0, 0xC0);
    mdioWrite(0x1F, 0);
    if (mac == 56 or mac == 57 or mac == 58 or mac == 61) eriBits(0x1AB, 1, 0, 0xFC);
    mdioWrite(0x00, 0x1000); // BMCR: autonegotiation on, powered
    if (isEP()) api.delay_us(10_000);
    if (isH() and mac != 76 or isFP() or is8125()) waitPhyState(3);
}

// if_re.c's re_hw_phy_config without its firmware.
fn phyConfig() void {
    // Its power saving off (the setting the firmware is told):
    if (mac == 59 or mac == 60 or mac == 62 or mac >= 67 and mac <= 76 or mac == 80 or mac == 81) {
        if (ocpRead(0xC416) != 0x0500) {
            patchRequest(true);
            ocpWrite(0xC416, 0);
            ocpWrite(0xC416, 0x0500);
            patchRequest(false);
        }
    }
    if (isFP() and pkg == 0x06) return; // a SerDes port: no copper PHY
    phy.before(mac);
    mdioWrite(0x1F, 0);
    phy.config(mac);

    if (isG()) { // EthPhyPPSW off
        mdioWrite(0x1F, 0x0BCD);
        mdioWrite(0x14, 0x5065);
        mdioWrite(0x14, 0xD065);
        mdioWrite(0x1F, 0x0BC8);
        mdioWrite(0x12, 0x00ED);
        mdioWrite(0x1F, 0x0BCD);
        mdioWrite(0x14, 0x1065);
        mdioWrite(0x14, 0x9065);
        mdioWrite(0x14, 0x1065);
        mdioWrite(0x1F, 0);
    } else if (mac == 68 or mac == 69 or mac == 74 or mac == 75) { // on
        mdioWrite(0x1F, 0x0A44);
        phyBits(0x11, 0, 0x0080);
        mdioWrite(0x1F, 0);
    }
    if (is8125()) {
        ocpBits(0xA5B4, 0x8000, 0); // legacy forced mode off
    } else { // automatic MDI / MDI-X
        mdioWrite(0x1F, 0x0A43);
        phyBits(0x10, 0x0300, 0);
        mdioWrite(0x1F, 0);
    }
    eeeOff();
    mdioWrite(0x1F, 0);
}

// Energy Efficient Ethernet off (if_re.c's default).
fn eeeOff() void {
    if (is8125()) {
        macOcpBits(0xE040, 0x0003, 0);
        if (mac == 80 or mac == 81) {
            macOcpBits(0xEB62, 0x0006, 0);
            ocpBits(0xA432, 0x0010, 0);
        } else {
            ocpBits(0xA432, 0, 0x0010);
        }
        ocpBits(0xA5D0, 0x0006, 0);
        ocpBits(0xA6D4, 0x0001, 0);
        ocpBits(0xA6D8, 0x0010, 0);
        ocpBits(0xA428, 0x0080, 0);
        ocpBits(0xA4A2, 0x0200, 0);
    } else if (mac != 76) {
        eriBits(0x1B0, 4, 0x03, 0);
        mdioWrite(0x1F, 0x0A43);
        if (mac == 75) phyBits(0x11, 0, 0x0010) else phyBits(0x11, 0x0010, 0);
        mdioWrite(0x1F, 0x0A5D);
        mdioWrite(0x10, 0);
        mdioWrite(0x1F, 0);
    }
    if (mac == 68 or mac == 69 or mac == 74 or mac == 75) {
        mdioWrite(0x1F, 0x0A42);
        phyBits(0x14, 0x0080, 0);
        mdioWrite(0x1F, 0x0A4A);
        phyBits(0x11, 0x0200, 0);
        mdioWrite(0x1F, 0);
    }

    // Advanced EEE: changed under the PHY's patch request if it is on:
    if (mac == 56 or mac == 57 or mac == 76) return;
    const lock = ocpRead(0xA430) & 0x8000 != 0;
    if (lock) patchRequest(true);
    if (is8125()) {
        macOcpBits(0xE052, 0x0001, 0);
        ocpBits(0xA442, 0x3000, 0);
        ocpBits(0xA430, 0x8000, 0);
    } else if (mac == 59 or mac == 60) {
        if (mac == 59) eriWrite(0x1EA, 1, 0) else macOcpBits(0xE052, 0x0001, 0);
        mdioWrite(0x1F, 0x0A42);
        phyBits(0x16, 0x0002, 0);
        mdioWrite(0x1F, 0);
    } else if (isEP() or isFP()) {
        macOcpBits(0xE052, 0x0001, 0);
    } else if (isH()) {
        macOcpBits(0xE052, 0x0001, 0);
        mdioWrite(0x1F, 0x0A43);
        phyBits(0x10, 0x8000, 0);
        mdioWrite(0x1F, 0x0A44);
        phyBits(0x11, 0x7000, 0);
        mdioWrite(0x1F, 0);
    }
    if (lock) patchRequest(false);
}

// PME off, the wake events and magic packets off.
fn wolOff() void {
    if (findCap(0x01)) |pm| {
        const ctl = api.pci_read(pci, pm + 4);
        api.pci_write(pci, pm + 4, (ctl & ~@as(u32, 0x0100)) | 0x8000); // PME_En off, PME_Status clear
    }
    unlockConfig();
    bits8(CFG3, 0x10, 0);
    magicPacketOff();
    bits8(CFG5, 0x72, 0);
    lockConfig();
}

fn magicPacketOff() void {
    if (is8125()) macOcpBits(0xC0B6, 0x0001, 0) else eriBits(0xDC, 4, 0x0001_0000, 0);
}

// For 8168G and later (re_hw_common).
fn macCommon8168() void {
    unlockConfig();
    noAspm();
    w16(CPLUS_CMD, 0x2060);
    w16(INTR_MITIGATE, 0);
    w32(TXCFG, txcfg_default);

    if (isG() or isH()) {
        bits8(CFG2, 0, 0x20);
        if (mac == 59) {
            macOcpWrite(0xD3C0, 0x0B00);
            macOcpWrite(0xD3C2, 0x0000);
        }
        if (isH()) {
            macOcpBits(0xD400, 0x0001, 0);
            var v = macOcpRead(0xE63E) & ~@as(u16, 0x000E);
            macOcpWrite(0xE63E, v);
            v |= 0x0001;
            macOcpWrite(0xE63E, v);
            v &= ~@as(u16, 0x0001);
            macOcpWrite(0xE63E, v);
            macOcpWrite(0xC094, 0);
            macOcpWrite(0xC09E, 0);
            macOcpWrite(0xE098, 0x0AA2);
        }
        w8(TDFNR, 0x4);
        eriBits(0xD4, 4, 0, 0x1F80);
        if (isH()) eriBits(0xDC, 4, 0, 0x1C);
        eriWrite(0xC8, 4, 0x00080002);
        eriWrite(0xCC, 2, 0x38);
        eriWrite(0xD0, 2, 0x48);
        eriWrite(0xE8, 4, 0x00100006);
        if (isH()) {
            macOcpWrite(0xE054, 0);
            eriBits(0x5F0, 4, 0x0F0F, 0);
        } else {
            eriWrite(0x5F0, 2, 0x4F87);
        }
        if (mac == 74 or mac == 75) macOcpBits(0xD438, 0, 0x0003);
        eriBits(0x2FC, 4, 0x07, 0x01);
        eriBits(0x1B0, 4, 0x1000, 0);
        w32(TXCFG, r32(TXCFG) | 0x80);
        bits8(0xD3, 0x80, 0);
        bits8(0x1B, 0x07, 0);
        if (mac == 74 or mac == 75) {
            macOcpBits(0xD438, 0x0004, 0);
            macOcpBits(0xDE28, 0x0003, 0);
            macOcpBits(0xD438, 0, 0x0004);
        }
        if (mac == 60) {
            macOcpWrite(0xD3C0, (macOcpRead(0xD3C0) & 0xF000) | 0x0FFF);
            macOcpWrite(0xD3C2, macOcpRead(0xD3C2) & 0xFF00);
            macOcpBits(0xD3C4, 0, 0x0001);
        } else if (mac == 68 or mac == 69 or mac == 76) {
            if (swr_cnt_1ms) |c| macOcpBits(0xD412, 0x0FFF, c);
            macOcpBits(0xE056, 0x00F0, 0);
            macOcpBits(0xE052, 0xE008, 0x8000);
            macOcpBits(0xD420, 0x0FFF, 0x045F);
            macOcpBits(0xE0D6, 0x01FF, 0x017F);
        }
        bits8(CFG3, 0x01, 0);
        bits8(0xD0, 0, 0x40);
        bits8(0xF2, 0, 0x40);
        bits8(0xF2, 0x08, 0);
        if (mac != 60) macOcpWrite(0xC140, 0xFFFF);
        if (isH()) macOcpWrite(0xC142, 0xFFFF);
    } else if (isEP()) {
        eriBits(0xD4, 4, 0, 0x1F80);
        eriWrite(0xC8, 4, 0x00080002);
        eriWrite(0xCC, 2, 0x2F);
        eriWrite(0xD0, 2, 0x5F);
        eriWrite(0xE8, 4, 0x00100006);
        if (mac != 61) eriWrite(0x5F0, 4, 0x4F87);
        eriBits(0x2FC, 4, 0x07, 0x03);
        eriBits(0x1B0, 4, 0x1000, 0);
        w32(TXCFG, r32(TXCFG) | 0x80);
        bits8(0xD3, 0x80, 0);
        bits8(0x1B, 0x07, 0);
        bits8(CFG3, 0x01, 0);
        bits8(0xD0, 0, 0x40);
        bits8(0xF2, 0, 0x40);
        bits8(0xD0, 0, 0x80);
        bits8(0xF2, 0x08, 0);
        if (mac == 67) {
            macOcpWrite(0xD3E2, (macOcpRead(0xD3E2) & 0xF000) | 0x0AFD);
            macOcpWrite(0xD3E4, macOcpRead(0xD3E4) & 0xFF00);
            macOcpBits(0xE860, 0, 0x0080);
        }
        macOcpWrite(0xC140, 0xFFFF);
        macOcpWrite(0xC142, 0xFFFF);
    } else if (isFP()) {
        macOcpWrite(0xE098, 0xC302);
        macOcpBits(0xD400, 0x0001, 0);
        if (swr_cnt_1ms) |c| macOcpBits(0xD412, 0x0FFF, c);
        macOcpBits(0xE056, 0x00F0, if (pkg == 0x0F) 0x0070 else 0);
        macOcpWrite(0xEA80, if (serdes == 0) 0x0003 else 0);
        macOcpBits(0xE052, 0x0009, if (pkg == 0x0F) 0x0001 else 0);
        macOcpBits(0xD420, 0x0FFF, 0x045F);
        w8(TDFNR, 0x4);
        var v = macOcpRead(0xE63E) & ~@as(u16, 0x000E);
        macOcpWrite(0xE63E, v);
        v |= 0x0001;
        macOcpWrite(0xE63E, v);
        v &= ~@as(u16, 0x0001);
        macOcpWrite(0xE63E, v);
        macOcpWrite(0xC094, 0);
        macOcpWrite(0xC09E, 0);
        eriBits(0xD4, 4, 0, if (mac == 70) 0x1F80 else 0x1F90);
        eriBits(0xDC, 4, 0, 0x0C);
        eriWrite(0xC8, 4, 0x00080002);
        eriWrite(0xCC, 2, 0x2F);
        eriWrite(0xD0, 2, 0x5F);
        eriWrite(0xE8, 4, 0x00100006);
        eriWrite(0x5F0, 2, if (pkg == 0x0F) 0x4F00 else 0x4000);
        eriBits(0x2FC, 4, 0x03, 0x01);
        eriBits(0x1B0, 4, 0x1000, 0);
        eriWrite(0xC0, 2, 0);
        eriWrite(0xB8, 4, 0);
        w32(TXCFG, r32(TXCFG) | 0x80);
        bits8(0xD3, 0x80, 0);
        bits8(0x1B, 0x07, 0);
        bits8(CFG3, 0x01, 0);
        if (serdes != 0) {
            bits8(0xD0, 0x40, 0);
            bits8(0xF2, 0x40, 0);
            bits8(0xD0, 0x80, 0);
        } else {
            bits8(0xD0, 0, 0x40);
            bits8(0xF2, 0, 0x40);
            bits8(0xD0, 0, 0x80);
        }
        bits8(0xF2, 0x08, 0);
        macOcpWrite(0xC140, 0xFFFF);
        macOcpWrite(0xC142, 0xFFFF);
    }
    bits8(CFG3, 0x02, 0); // io_rdy_l23 cleared
    noAspm();
    lockConfig();
    wolOff();
}

// re_hw_common_8125
fn macCommon8125() void {
    unlockConfig();
    noAspm();
    w16(CPLUS_CMD, 0x2060);
    w32(TXCFG, txcfg_default);
    bits8(CFG2, 0, 0x20);
    macOcpWrite(0xE098, 0xC302);
    w16(0x382, 0x221B);
    w8(0x4500, 0);
    w16(0x4800, 0);
    bits8(CFG1, 0x10, 0);
    bits8(0xF2, 0x08, 0);
    w8(TDFNR, 0x10);
    macOcpWrite(0xC140, 0xFFFF);
    macOcpWrite(0xC142, 0xFFFF);
    macOcpBits(0xEB58, 0x0001, 0); // the old transmit descriptor format
    macOcpBits(0xE614, 0x0700, if (mac == 82 or mac == 83) 2 << 8 else 3 << 8);
    macOcpBits(0xE63E, 0x0C00, 0);
    macOcpBits(0xE63E, 0x0030, 0x02 << 4);
    macOcpBits(0xC0B4, 0, 0x000C);
    macOcpBits(0xEB6A, 0x00FF, 0x0033);
    macOcpBits(0xEB50, 0x03E0, 0x0040);
    macOcpBits(0xE056, 0x00F0, 0);
    macOcpBits(0xE040, 0x1000, 0);
    macOcpBits(0xEA1C, 0x0003, 0x0001);
    macOcpWrite(0xE0C0, 0x4400);
    macOcpBits(0xE052, 0, 0x0060);
    macOcpBits(0xE052, 0x0088, 0);
    if (mac == 80 or mac == 81) macOcpBits(0xC0AC, 0x0080, 0x1F00) else macOcpBits(0xC0AC, 0, 0x1F80);
    macOcpBits(0xD430, 0x0FFF, 0x045F);
    bits8(0xD0, 0, 0x40);
    bits8(0xF2, 0, 0x40);
    bits8(0xD0, 0, 0x80);
    if (mac == 80 or mac == 81) bits8(0xD3, 0, 0x01);
    macOcpBits(0xEA1C, 0x0004, 0);
    macOcpBits(0xEB54, 0, 0x0001);
    api.delay_us(1);
    macOcpBits(0xEB54, 0x0001, 0);
    w16(0x1880, r16(0x1880) & ~@as(u16, 0x0030));
    var a: usize = 0xA00;
    while (a < (if (mac == 80 or mac == 81) @as(usize, 0xB00) else 0xA80)) : (a += 4) w32(a, 0);
    if (mac == 82 or mac == 83) {
        // The old interrupt mapping (IMR_8125 / ISR_8125), no bypasses:
        bits8(INT_CFG0_8125, 0x07, 0);
        w16(INT_CFG1_8125, 0);
    }
    noAspm();
    lockConfig();
    wolOff();
    w32(0x0A00, 0x00630063); // interrupt mitigation
}

// Every speed the chip has, with pause frames.
fn advertise() void {
    if (is8125()) {
        ocpBits(0xA428, 0x0200, 0); // Giga Lite off
        ocpBits(0xA5EA, 0x0001, 0);
        const cr2500 = (ocpRead(0xA5D4) & ~@as(u16, 0x1180)) | 0x0080;
        const gbcr = (mdioRead(0x09) & ~@as(u16, 0x0300)) | 0x0200;
        const anar = (mdioRead(0x04) & ~@as(u16, 0x0DE0)) | 0x0DE0;
        mdioWrite(0x1F, 0);
        ocpWrite(0xA5D4, cr2500);
        mdioWrite(0x04, anar);
        mdioWrite(0x09, gbcr);
    } else {
        if (mac == 68 or mac == 69 or mac == 74 or mac == 75 or isFP()) {
            mdioWrite(0x1F, 0x0A42);
            phyBits(0x14, if (isFP()) 0x0280 else 0x0200, 0); // Giga Lite off
            mdioWrite(0x1F, 0x0A40);
        }
        mdioWrite(0x1F, 0);
        mdioWrite(0x04, 0x0DE0); // 10/100 half and full, pause
        mdioWrite(0x09, 0x0300); // 1000 half and full
    }
    mdioWrite(0x00, 0x9200); // reset, autonegotiation on and restarted
}

// RINGS

const Desc = extern struct {
    opts1: u32,
    opts2: u32,
    addr: u64,
};

const own: u32 = 1 << 31;
const end_of_ring: u32 = 1 << 30;
const first: u32 = 1 << 29;
const last: u32 = 1 << 28;
const rx_error: u32 = 1 << 21;

const rx_count = 128;
const tx_count = 64;
const buf_size = 2048;
const max_frame = 1514;
const pages = 1 + (rx_count + tx_count) * buf_size / 4096;

var rx: [*]volatile Desc = undefined;
var tx: [*]volatile Desc = undefined;
var rx_bufs: [*]u8 = undefined;
var tx_bufs: [*]u8 = undefined;
var rx_next: u32 = 0;
var tx_next: u32 = 0;
var rx_size: u32 = 0; // RxMaxSize, with VLAN tag and CRC
var running = false;

// re_hw_start
fn start() void {
    for (0..rx_count) |i| {
        rx[i].addr = @intFromPtr(rx_bufs + i * buf_size);
        rx[i].opts2 = 0;
        rx[i].opts1 = own | rx_size | if (i == rx_count - 1) end_of_ring else 0;
    }
    for (0..tx_count) |i| {
        tx[i].addr = @intFromPtr(tx_bufs + i * buf_size);
        tx[i].opts2 = 0;
        tx[i].opts1 = if (i == tx_count - 1) end_of_ring else 0;
    }
    rx_next = 0;
    tx_next = 0;
    writeBarrier();
    const ta: u64 = @intFromPtr(tx);
    const ra: u64 = @intFromPtr(rx);
    w32(TX_DESC, @truncate(ta));
    w32(TX_DESC + 4, @truncate(ta >> 32));
    w32(RX_DESC, @truncate(ra));
    w32(RX_DESC + 4, @truncate(ra >> 32));
    w16(RX_MAX_SIZE, @intCast(rx_size));

    unlockConfig();
    noAspm();
    if (is8125()) {
        w16(EEE_TXIDLE_8125, max_frame + 0x20);
        w32(RXCFG, r32(RXCFG) & ~@as(u32, 0x00C0_0000)); // no VLAN tag stripping
        w16(CPLUS_CMD, r16(CPLUS_CMD) | 0x0020); // receive checksums
    } else {
        if (isH()) macOcpWrite(0xE048, max_frame + 0x20); // EEE transmit idle timer
        w8(MTPS, 0x3F);
        w16(CPLUS_CMD, (r16(CPLUS_CMD) & ~@as(u16, 0x0040)) | 0x0020);
    }
    lockConfig();

    w32(MAR0, 0);
    w32(MAR0 + 4, 0);
    w32(RXCFG, (r32(RXCFG) & ~rx_accept_bits) | rx_accept_own | rx_accept_broadcast);
    w8(CR, cr_rx | cr_tx);
    running = true;
}

// Duplex into TxConfig, the rings anew.
fn linkOn(status: u32) void {
    const ifg: u32 = if (status & full_duplex != 0) 0x0300_0000 else 0x0200_0000;
    w32(TXCFG, (r32(TXCFG) & ~@as(u32, 0x0308_0000)) | ifg);
    if (is8125()) eeePlus(status & status_10m != 0);
    if ((mac == 56 or mac == 57 or mac == 61 or mac == 62) and status & full_duplex == 0) {
        mdioWrite(0x1F, 0);
        phyBits(0x04, 0x0C00, 0); // half duplex: no pause frames
    }
    stop();
    setAddress();
    start();
}

fn linkOff() void {
    if (is8125()) eeePlus(false);
    running = false;
    stop();
}

fn setAddress() void {
    const m = card.mac;
    unlockConfig();
    w32(IDR0, @as(u32, m[0]) | @as(u32, m[1]) << 8 | @as(u32, m[2]) << 16 | @as(u32, m[3]) << 24);
    w16(IDR0 + 4, @as(u16, m[4]) | @as(u16, m[5]) << 8);
    lockConfig();
}

fn linkUp(_: ?*anyopaque) callconv(drv.cc) bool {
    const status = phyStatus();
    const up = status & link_ok != 0;
    if (up and !running) linkOn(status) else if (!up and running) linkOff();
    return up;
}

// 8125A/B erratum (as if_re.c): short UDP frames padded to 121 bytes
// (IPv4) or 147 (IPv6).
fn padTo(frame: []const u8) usize {
    if (!is8125() or frame.len < 24) return 60;
    const ether_type = @as(u16, frame[12]) << 8 | frame[13];
    if (ether_type == 0x0800 and frame[23] == 17) return 121;
    if (ether_type == 0x86DD and frame[20] == 17) return 147;
    return 60;
}

fn send(_: ?*anyopaque, frame: [*]const u8, len: usize) callconv(drv.cc) bool {
    if (!running or len == 0 or len > max_frame) return false;
    const i = tx_next;
    const d = &tx[i];
    if (d.opts1 & own != 0) return false; // the ring is full
    const buf = tx_bufs + i * buf_size;
    @memcpy(buf[0..len], frame[0..len]);
    const n = @max(len, padTo(frame[0..len]));
    if (n > len) @memset(buf[len..n], 0);
    d.opts2 = 0;
    writeBarrier();
    d.opts1 = own | first | last | @as(u32, @intCast(n)) | if (i == tx_count - 1) end_of_ring else 0;
    tx_next = (i + 1) % tx_count;
    if (is8125()) w16(TPPOLL_8125, 0x01) else w8(TPPOLL, 0x40);
    return true;
}

fn receive(_: ?*anyopaque, buf: [*]u8, max: usize) callconv(drv.cc) isize {
    if (!running) return -1;
    while (true) {
        const i = rx_next;
        const d = &rx[i];
        const status = d.opts1;
        if (status & own != 0) return -1;
        readBarrier();
        const size: usize = status & 0x3FFF;
        const good = status & rx_error == 0 and status & (first | last) == first | last and size > 4;
        const len = size -| 4; // without the CRC
        const fits = good and len <= max;
        if (fits) @memcpy(buf[0..len], (rx_bufs + i * buf_size)[0..len]);
        d.opts2 = 0;
        writeBarrier();
        d.opts1 = own | rx_size | if (i == rx_count - 1) end_of_ring else 0;
        rx_next = (i + 1) % rx_count;
        if (fits) return @intCast(len);
    }
}

var card: drv.NetCard = .{
    .mac = undefined,
    .name_len = 0,
    .name = @splat(0),
    .send = send,
    .receive = receive,
    .link_up = linkUp,
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch return;
    api.log(text.ptr, text.len);
}

fn findCap(id: u8) ?u16 {
    if (api.pci_read(pci, 0x04) & (1 << 20) == 0) return null;
    var at: u16 = @intCast(api.pci_read(pci, 0x34) & 0xFC);
    var n: u32 = 0;
    while (at >= 0x40 and n < 48) : (n += 1) {
        const v = api.pci_read(pci, at);
        if (v & 0xFF == id) return at;
        at = @intCast((v >> 8) & 0xFC);
    }
    return null;
}

// if_re.c's re_init_software_variable
fn readStraps() void {
    if (isFP()) {
        pkg = (macOcpRead(0xDC00) >> 3) & 0x0F;
        if (mac != 70 and pkg == 0x06) {
            const t = eriRead(0xE6, 1);
            serdes = if (t == 0x02) 1 else if (t == 0x00) 2 else 0;
        }
    }
    if (mac == 69 or mac == 76) {
        macOcpWrite(0xDD02, 0x807D);
        var t = macOcpRead(0xDD02);
        var p3: u16 = ((t & 0x0080) >> 7) << 3;
        t = macOcpRead(0xDD00);
        p3 |= (t & 0xE000) >> 13;
        const p2 = (t & 0x1E00) >> 9;
        const p1 = (t & 0x01E0) >> 5;
        const p0 = (((t & 0x0010) >> 4) << 3) | (t & 0x0007);
        if (!(p3 == 0x0F and p2 == 0x0F and p1 == 0x0F and p0 == 0x0F)) adc_bias = p3 << 12 | p2 << 8 | p1 << 4 | p0;
    }
    if (mac == 68 or mac == 69 or isFP() or mac == 75 or mac == 76) {
        mdioWrite(0x1F, 0x0C42);
        const saw = mdioRead(0x13) & ~@as(u16, 0xC000);
        mdioWrite(0x1F, 0);
        if (saw > 0) swr_cnt_1ms = @intCast((16_000_000 / @as(u32, saw)) & 0x0FFF);
    }
    if (mac == 81 and macOcpRead(0xD442) & 0x0020 != 0 and ocpRead(0xD068) & 0x0002 != 0) mdi_swap = true;
}

// The one the firmware loaded, else the chip's backup.
fn readAddress() void {
    var m: [6]u8 = undefined;
    if (is8125()) {
        const lo = r32(BACKUP_ADDR_8125);
        const hi = r16(BACKUP_ADDR_8125 + 4);
        m = .{ @truncate(lo), @truncate(lo >> 8), @truncate(lo >> 16), @truncate(lo >> 24), @truncate(hi), @truncate(hi >> 8) };
    } else {
        const lo = eriRead(0xE0, 4);
        const hi = eriRead(0xE4, 2);
        m = .{ @truncate(lo), @truncate(lo >> 8), @truncate(lo >> 16), @truncate(lo >> 24), @truncate(hi), @truncate(hi >> 8) };
    }
    if (!validAddress(m)) {
        for (0..6) |i| m[i] = r8(IDR0 + i);
    }
    if (!validAddress(m)) {
        // A locally administered one from the clock:
        const t = api.millis() *% 0x9E37_79B9_7F4A_7C15;
        m = .{ 0x02, 0xE0, 0x4C, @truncate(t >> 40), @truncate(t >> 48), @truncate(t >> 56) };
        log("RTL8169: no address in the chip, using a made-up one\n", .{});
    }
    card.mac = m;
}

fn validAddress(m: [6]u8) bool {
    if (m[0] & 1 != 0) return false; // multicast
    for (m) |b| {
        if (b != 0) return true;
    }
    return false;
}

export fn zdos_driver_init(a: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    api = a;
    pci = dev;

    // The registers: the first memory BAR after BAR0 (ports):
    var phys: u64 = 0;
    for (1..3) |i| {
        const raw = api.pci_read(dev, @intCast(0x10 + i * 4));
        if (raw & 1 == 0 and dev.bars[i] != 0) {
            phys = dev.bars[i] & ~@as(u64, 0xF);
            break;
        }
    }
    if (phys == 0 or phys > std.math.maxInt(usize) or !api.map_device(phys, 0x1000)) {
        log("RTL8169: registers not reachable\n", .{});
        return false;
    }
    regs = @intCast(phys);
    api.pci_enable(dev);
    if (findCap(0x01)) |pm| { // to D0, if the firmware left it asleep
        const ctl = api.pci_read(dev, pm + 4);
        if (ctl & 0x3 != 0) {
            api.pci_write(dev, pm + 4, ctl & ~@as(u32, 0x8003));
            api.delay_us(10_000);
        }
    }

    // Which chip:
    const txcfg = r32(TXCFG);
    if (txcfg == 0xFFFF_FFFF) return false;
    const ver = txcfg & 0xFCF0_0000;
    var name: []const u8 = "";
    for (chips) |c| {
        if (c.ver == ver) {
            mac = c.mac;
            name = c.name;
            break;
        }
    }
    if (mac == 69) {
        const v = macOcpRead(0xD006) & 0xFF00;
        if (v == 0x0100) mac = 74 else if (v == 0x0300) mac = 75;
    }
    if (mac == 0) {
        log("RTL8169: unknown chip (TxConfig {X:0>8})\n", .{txcfg});
        return false;
    }
    if (!supported()) {
        log("RTL8169: RTL{s} (MAC version {d}) not supported\n", .{ name, mac });
        return false;
    }
    if (is8125() and !api.map_device(phys, 0x10000)) return false;

    // PCIe ASPM off, as if_re.c does by default:
    if (findCap(0x10)) |cap| {
        const ctl = api.pci_read(dev, cap + 0x10);
        if (ctl & 0x0103 != 0) api.pci_write(dev, cap + 0x10, ctl & ~@as(u32, 0x0103));
    }

    // RxConfig's base (FIFO thresholds, DMA burst), then the chip's values:
    w32(RXCFG, if (is8125()) (if (mac >= 82) @as(u32, 0x40C00C00) else 0x40C00400) else 0x8F00);
    readStraps();
    readAddress();
    setAddress();
    rx_size = max_frame + 4 + 4 + @as(u32, if (isG()) 1 else 0);

    // re_hw_init:
    exitOob();
    stop();
    eeePlus(false);
    unlockConfig();
    magicPacketOff();
    noAspm();
    bits8(CFG2, 0, 0x20);
    lockConfig();
    // if_re.c now clears the MAC microcontroller's
    // breakpoints and loads its patches; without those, the
    // firmware's patches are kept:
    phyPowerUp();
    phyConfig();
    phy.ephy(mac);
    if (is8125()) macCommon8125() else macCommon8168();

    const mem = api.alloc_pages(pages) orelse return false;
    rx = @ptrCast(@alignCast(mem));
    tx = @ptrCast(@alignCast(mem + rx_count * @sizeOf(Desc)));
    rx_bufs = mem + 4096;
    tx_bufs = rx_bufs + rx_count * buf_size;

    advertise();

    const label = std.fmt.bufPrint(&card.name, "Realtek RTL{s} {X:0>4}:{X:0>4}", .{ name, dev.vendor, dev.device }) catch "Realtek";
    card.name_len = @intCast(label.len);
    const m = card.mac;
    log("RTL8169: RTL{s} (MAC version {d}), {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}\n", .{ name, mac, m[0], m[1], m[2], m[3], m[4], m[5] });
    if (!api.register_net(&card)) return false;
    // A ZDOS without net_interrupts polls:
    if (api.slots * @sizeOf(usize) >= @offsetOf(drv.Api, "net_interrupts")) _ = api.net_interrupts(&card, dev, &control);
    return true;
}

fn setMask(v: u16) void {
    if (is8125()) w32(IMR_8125, v) else w16(IMR, v);
}

fn control(_: ?*anyopaque, op: u32) callconv(drv.cc) bool {
    switch (op) {
        drv.NetIrq.enable, drv.NetIrq.rearm => setMask(int_causes),
        drv.NetIrq.disable => setMask(0),
        drv.NetIrq.ack => {
            const isr: u32 = if (is8125()) r32(ISR_8125) else r16(ISR);
            // All ones: the card is gone; 0: not its interrupt:
            if (isr == 0 or isr == 0xFFFF or isr == 0xFFFF_FFFF) return false;
            setMask(0);
            if (is8125()) w32(ISR_8125, isr) else w16(ISR, @truncate(isr));
        },
        else => return false,
    }
    return true;
}
