// Builds ZDOS's editions into build/<edition>/.
//   zig build [EDITION] [-Dtest-disks]
//   zig build test-disks | dist [-Dversion=...]
// Editions: x86_64, arm64 (metal), uefi-x86_64, uefi-arm64, x86 (BIOS).
// Needs Zig 0.14, dosfstools and mtools; zip for dist, binutils for x86.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 14)
        @compileError("ZDOS needs Zig 0.14");
}

// EDITIONS

// The entry file (main.zig, main_uefi.zig, main_bios.zig) names the
// platform backend to src/platform.zig.
const Platform = enum { bios, uefi, metal };

const Edition = struct {
    name: []const u8, // zig build <name>
    folder: []const u8, // build/<folder>
    arch: std.Target.Cpu.Arch,
    platform: Platform,
    linker_script: []const u8, // the programs'
};

const editions = [_]Edition{
    .{ .name = "x86", .folder = "bios-x86", .arch = .x86, .platform = .bios, .linker_script = "sdk/linkers/app-x86.ld" },
    .{ .name = "uefi-x86_64", .folder = "uefi-x86_64", .arch = .x86_64, .platform = .uefi, .linker_script = "sdk/linkers/app-x86_64.ld" },
    .{ .name = "uefi-arm64", .folder = "uefi-arm64", .arch = .aarch64, .platform = .uefi, .linker_script = "sdk/linkers/app-arm64.ld" },
    .{ .name = "x86_64", .folder = "metal-x86_64", .arch = .x86_64, .platform = .metal, .linker_script = "sdk/linkers/app-x86_64.ld" },
    .{ .name = "arm64", .folder = "metal-arm64", .arch = .aarch64, .platform = .metal, .linker_script = "sdk/linkers/app-arm64.ld" },
};

// BUILD STEPS

pub fn build(b: *std.Build) void {
    const on_mac = b.graph.host.result.os.tag == .macos;
    const binutils = b.option([]const u8, "binutils-prefix", "Prefix of GNU as, ld and objcopy for the x86 edition (default: none; x86_64-elf- on macOS)") orelse
        if (on_mac) "x86_64-elf-" else "";
    // Without -Dversion: ZDOS's own, its first two numbers (0.2)
    const zdos_version = @import("src/kernel/version.zig").zdos;
    const version = b.option([]const u8, "version", "Version in the names of the release zips (default: src/kernel/version.zig's, as 0.2)") orelse
        b.fmt("{d}.{d}", .{ zdos_version[0], zdos_version[1] });
    const rpi4_firmware = b.option([]const u8, "rpi4-firmware", "The Raspberry Pi 4 UEFI firmware folder, for the release");
    const with_test_disks = b.option(bool, "test-disks", "Build each edition with its test disks") orelse false;
    const disks = hostTool(b, "disks");
    const release = runInSources(b, disks, &.{ "release", version });
    if (rpi4_firmware) |fw| release.addArg(fw);
    b.step("dist", "The release zips in dist/ (-Dversion=...)").dependOn(&release.step);
    const test_disks = b.step("test-disks", "Extra disks for testing in QEMU (the run scripts attach them)");
    // build/host/mkmfs3: Minix volumes on the host (the tests, USB sticks)
    const mkmfs3 = mkmfs3Tool(b);
    b.step("mkmfs3", "The host's Minix formatter (build/host/mkmfs3)").dependOn(mkmfs3);
    b.getInstallStep().dependOn(mkmfs3);
    // build/host/mfsdir: a Minix image holding a folder (tools/disk/mkimage.py)
    const mfsdir = b.addUpdateSourceFiles();
    mfsdir.addCopyFileToSource(hostTool(b, "mfsdir").getEmittedBin(), "build/host/mfsdir");
    b.step("mfsdir", "A Minix image from a folder (build/host/mfsdir)").dependOn(&mfsdir.step);

    for (editions) |e| {
        const images = runInSources(b, disks, &.{ "images", e.folder });
        images.step.dependOn(compile(b, e, binutils));
        const edition = b.step(e.name, b.fmt("The {s} edition (build/{s})", .{ e.name, e.folder }));
        edition.dependOn(&images.step);
        edition.dependOn(mkmfs3);
        b.getInstallStep().dependOn(&images.step);
        release.step.dependOn(&images.step);
        const edition_test_disks = runInSources(b, disks, &.{ "test-disks", e.folder });
        test_disks.dependOn(&edition_test_disks.step);
        if (with_test_disks) {
            edition.dependOn(&edition_test_disks.step);
            b.getInstallStep().dependOn(&edition_test_disks.step);
        }
    }
}

fn compile(b: *std.Build, e: Edition, binutils: []const u8) *std.Build.Step {
    const dir = b.fmt("build/{s}", .{e.folder});
    const out = b.addUpdateSourceFiles();
    // A program removed from apps/ goes from APPS/ too:
    out.step.dependOn(&b.addRemoveDirTree(b.path(b.fmt("{s}/APPS", .{dir}))).step);

    // KERNEL
    var query: std.Target.Query = .{ .cpu_arch = e.arch, .os_tag = .freestanding };
    // BIOS edition: no MMX / SSE, runs on every CPU from the Pentium Pro on.
    if (e.arch == .x86) query.cpu_model = .{ .explicit = &std.Target.x86.cpu.i686 };
    const target = b.resolveTargetQuery(query);
    const kernel_options = b.addOptions();

    var boot_code: ?std.Build.LazyPath = null;
    if (e.arch == .x86) {
        const kernel = b.addExecutable(.{
            .name = "kernel",
            .root_module = b.createModule(.{ .root_source_file = b.path("src/main_bios.zig"), .target = target, .optimize = .ReleaseSmall }),
        });
        kernel.setLinkerScript(b.path("src/boot/bios/kernel.ld"));
        kernel.root_module.addOptions("build_options", kernel_options);
        kernel.root_module.addIncludePath(b.path("src/net/port"));
        kernel.root_module.addIncludePath(b.path("src/net/lwip/include"));
        const net_flags: []const []const u8 = &.{ "-ffreestanding", "-fno-stack-protector" };
        kernel.root_module.addCSourceFile(.{ .file = b.path("src/net/glue.c"), .flags = net_flags });
        kernel.root_module.addCSourceFiles(.{ .root = b.path("src/net"), .files = &lan_sources, .flags = net_flags });
        kernel.root_module.addCSourceFiles(.{ .root = b.path("src/net/lwip"), .files = &lwip_sources, .flags = net_flags });
        const run = b.addRunArtifact(hostTool(b, "bios-boot"));
        run.addArg(binutils);
        run.addFileArg(kernel.getEmittedBin());
        run.addDirectoryArg(b.path("src/boot/bios"));
        for ([_][]const u8{ "stage2.s", "mbr.s", "vbr16.s", "vbr32.s" }) |s| run.addFileInput(b.path(b.fmt("src/boot/bios/{s}", .{s})));
        const files = run.addOutputDirectoryArg("bios-boot");
        for ([_][]const u8{ "ZIGDOS.SYS", "mbr.bin", "vbr16.bin", "vbr32.bin" }) |f| out.addCopyFileToSource(files.path(b, f), b.fmt("{s}/{s}", .{ dir, f }));
        boot_code = files;
    } else {
        const name = if (e.arch == .x86_64) "BOOTX64" else "BOOTAA64";
        const kernel = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(if (e.platform == .metal) "src/main.zig" else "src/main_uefi.zig"),
                .target = b.resolveTargetQuery(.{ .cpu_arch = e.arch, .os_tag = .uefi }),
                .optimize = .ReleaseSmall,
                // Metal takes interrupts on the kernel's stack: no red zone.
                .red_zone = if (e.platform == .metal and e.arch == .x86_64) false else null,
            }),
        });
        kernel.root_module.addOptions("build_options", kernel_options);
        if (e.platform == .metal) kernel.root_module.addAnonymousImport("default_font.zfn", .{ .root_source_file = b.path("fonts/terminal/spleen-12x24.zfn") });
        kernel.root_module.addIncludePath(b.path("src/net/port"));
        kernel.root_module.addIncludePath(b.path("src/net/lwip/include"));
        const no_red_zone = e.platform == .metal and e.arch == .x86_64;
        const net_flags: []const []const u8 = if (no_red_zone)
            &.{ "-ffreestanding", "-fno-stack-protector", "-mno-red-zone" }
        else
            &.{ "-ffreestanding", "-fno-stack-protector" };
        kernel.root_module.addCSourceFile(.{ .file = b.path("src/net/glue.c"), .flags = net_flags });
        kernel.root_module.addCSourceFiles(.{ .root = b.path("src/net"), .files = &lan_sources, .flags = net_flags });
        kernel.root_module.addCSourceFiles(.{ .root = b.path("src/net/lwip"), .files = &lwip_sources, .flags = net_flags });
        out.addCopyFileToSource(kernel.getEmittedBin(), b.fmt("{s}/{s}.EFI", .{ dir, name }));
    }


    // ZIG APPS AND GAMES
    const abi = b.createModule(.{ .root_source_file = b.path("src/kernel/abi.zig"), .target = target, .optimize = .ReleaseSmall });
    const zdos = b.createModule(.{ .root_source_file = b.path("apps/zdos/zdos.zig"), .target = target, .optimize = .ReleaseSmall });
    zdos.addImport("abi", abi);
    for ([_][2][]const u8{ .{ "apps", "APPS" }, .{ "games", "GAMES" } }) |folder| {
        for (sourceFiles(b, folder[0])) |source| {
            const stem = std.fs.path.stem(source);
            const is_zig = std.mem.endsWith(u8, source, ".zig");
            const mod = b.createModule(.{
                .root_source_file = if (is_zig) b.path(source) else null,
                .target = target,
                .optimize = .ReleaseSmall,
                .red_zone = if (e.arch == .x86_64) false else null,
                .stack_protector = if (is_zig) null else false,
                .unwind_tables = .none, // the linker scripts keep .eh_frame (C++ exceptions)
                // Argon2's std.Thread has no freestanding version:
                .single_threaded = if (is_zig and usesArgon2(stem)) true else null,
            });
            if (is_zig) {
                // The games get apps/zdos as module "zdos":
                mod.addImport("abi", abi);
                if (std.mem.eql(u8, folder[0], "games")) mod.addImport("zdos", zdos);
                // SYS and FDISK of the BIOS edition embed its boot code:
                if (boot_code) |code| {
                    if (std.mem.eql(u8, stem, "sys")) {
                        mod.addAnonymousImport("vbr16.bin", .{ .root_source_file = code.path(b, "vbr16.bin") });
                        mod.addAnonymousImport("vbr32.bin", .{ .root_source_file = code.path(b, "vbr32.bin") });
                    }
                    if (std.mem.eql(u8, stem, "fdisk")) {
                        mod.addAnonymousImport("mbr.bin", .{ .root_source_file = code.path(b, "mbr.bin") });
                    }
                }
            } else {
                mod.addCSourceFile(.{ .file = b.path(source), .flags = &.{"-ffreestanding"} });
                mod.addIncludePath(b.path("sdk/src"));
            }
            const exe = b.addExecutable(.{ .name = stem, .root_module = mod });
            exe.entry = .{ .symbol_name = "zdos_entry" };
            exe.pie = true;
            exe.setLinkerScript(b.path(e.linker_script));
            const app = b.addObjCopy(exe.getEmittedBin(), .{ .format = .bin });
            const name = std.ascii.allocUpperString(b.allocator, stem) catch @panic("OOM");
            out.addCopyFileToSource(app.getOutput(), b.fmt("{s}/{s}/{s}.APP", .{ dir, folder[1], name }));
        }
    }

    // LIBRARIES (.ZDL) AND DRIVERS (.SYS)
    const drv = b.createModule(.{ .root_source_file = b.path("src/kernel/drv.zig"), .target = target, .optimize = .ReleaseSmall });
    for ([_][3][]const u8{ .{ "libs", "LIBS", "ZDL" }, .{ "sys", "DRIVERS", "SYS" } }) |kind| {
        out.step.dependOn(&b.addRemoveDirTree(b.path(b.fmt("{s}/{s}", .{ dir, kind[1] }))).step);
        for (sourceFiles(b, kind[0])) |source| {
            const stem = std.fs.path.stem(source);
            const is_lib = std.mem.eql(u8, kind[0], "libs");
            const mod = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = .ReleaseSmall,
                .red_zone = if (e.arch == .x86_64) false else null,
                .single_threaded = if (is_lib and std.mem.eql(u8, stem, "zcrypt")) true else null,
            });
            if (is_lib) {
                mod.addImport("abi", abi);
                mod.addImport("zdos", zdos);
            } else mod.addImport("drv", drv);
            const exe = b.addExecutable(.{ .name = stem, .root_module = mod });
            exe.entry = if (is_lib) .disabled else .{ .symbol_name = "zdos_driver_init" };
            exe.pie = true;
            const script = std.mem.replaceOwned(u8, b.allocator, e.linker_script, "app-", if (is_lib) "lib-" else "sys-") catch @panic("OOM");
            exe.setLinkerScript(b.path(script));
            const bin = b.addObjCopy(exe.getEmittedBin(), .{ .format = .bin });
            const name = std.ascii.allocUpperString(b.allocator, stem) catch @panic("OOM");
            out.addCopyFileToSource(bin.getOutput(), b.fmt("{s}/{s}/{s}.{s}", .{ dir, kind[1], name, kind[2] }));
        }
    }

    // C APPS (apps/posix, on the C SDK)
    const sdk_sources = [_][]const u8{ "zdos_crt0.c", "zdos_libc.c", "zdos_fs.c", "zdos_posix.c", "zdos_setjmp.c", "zdos_mathl.c", "zdos_math_x87.c", "zdos_wchar.c", "zdos_unix.c", "zdos_regex.c", "zdos_net.c", "zdos_complex.c", "zdos_fenv.c", "zdos_cxx.c", "zdos_tls.c", "zdos_display.c", "zdos_input.c", "zdos_audio.c", "zdos_linux.c", "zdos_kqueue.c" };
    const libm_sources = sourceFiles(b, "sdk/src/libm");
    // Pre-included headers by full path, so the build cache follows them:
    const libm_flags = &.{ "-ffreestanding", "-fno-builtin", "-D_IEEE_LIBM", "-D__HAVE_LONG_DOUBLE", "-include", b.pathFromRoot("sdk/compat/sys/cdefs.h"), "-include", b.pathFromRoot("sdk/compat/endian.h"), "-w" };
    const libml_sources = sourceFiles(b, "sdk/src/libml");
    for (sourceFiles(b, "apps/posix")) |source| {
        if (!std.mem.endsWith(u8, source, ".c")) continue;
        const stem = std.fs.path.stem(source);
        const mod = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSmall,
            .red_zone = if (e.arch == .x86_64) false else null,
            .stack_protector = false,
            .unwind_tables = .none,
        });
        const flags = &.{ "-ffreestanding", "-fno-builtin" };
        mod.addCSourceFile(.{ .file = b.path(source), .flags = flags });
        for (sdk_sources) |s| mod.addCSourceFile(.{ .file = b.path(b.fmt("sdk/src/{s}", .{s})), .flags = flags });
        for (libm_sources) |s| {
            if (!std.mem.endsWith(u8, s, ".c")) continue;
            if (e.arch == .x86 and x87Replaced(std.fs.path.basename(s))) continue;
            mod.addCSourceFile(.{ .file = b.path(s), .flags = libm_flags });
        }
        for (libml_sources) |s| {
            if (std.mem.endsWith(u8, s, ".c")) mod.addCSourceFile(.{ .file = b.path(s), .flags = flags });
        }
        mod.addIncludePath(b.path("sdk/compat"));
        mod.addIncludePath(b.path("sdk/src"));
        mod.addIncludePath(b.path("sdk/src/libm"));
        const exe = b.addExecutable(.{ .name = stem, .root_module = mod });
        exe.entry = .{ .symbol_name = "zdos_entry" };
        exe.pie = true;
        exe.setLinkerScript(b.path(e.linker_script));
        const app = b.addObjCopy(exe.getEmittedBin(), .{ .format = .bin });
        const name = std.ascii.allocUpperString(b.allocator, stem) catch @panic("OOM");
        out.addCopyFileToSource(app.getOutput(), b.fmt("{s}/APPS/{s}.APP", .{ dir, name }));
    }
    return &out.step;
}

// KERNEL C SOURCES

const lan_sources = [_][]const u8{"nat.c"};

const lwip_sources = [_][]const u8{
    "core/def.c",           "core/dns.c",           "core/inet_chksum.c", "core/init.c",      "core/ip.c",
    "core/mem.c",           "core/memp.c",          "core/netif.c",       "core/pbuf.c",      "core/raw.c",
    "core/stats.c",         "core/tcp.c",           "core/tcp_in.c",      "core/tcp_out.c",   "core/timeouts.c",
    "core/udp.c",           "core/ipv4/dhcp.c",     "core/ipv4/etharp.c", "core/ipv4/icmp.c", "core/ipv4/ip4.c",
    "core/ipv4/ip4_addr.c", "core/ipv4/ip4_frag.c", "netif/ethernet.c",
};

// HELPERS

// NetBSD's rint / lrint family, replaced on x86 by zdos_math_x87.c
fn x87Replaced(file: []const u8) bool {
    for ([_][]const u8{ "s_rint.c", "s_rintf.c", "lrint.c", "lrintf.c", "llrint.c", "llrintf.c" }) |name| {
        if (std.mem.eql(u8, file, name)) return true;
    }
    return false;
}

// Programs that use Argon2: std is built single-threaded for them
fn usesArgon2(stem: []const u8) bool {
    for ([_][]const u8{ "login", "passwd", "adduser", "su", "sudo", "sshd", "sshtest" }) |name| {
        if (std.mem.eql(u8, stem, name)) return true;
    }
    return false;
}

fn hostTool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    // libc: localtime_r for the Minix drives' file times (minix.zig)
    const module = b.createModule(.{ .root_source_file = b.path(b.fmt("tools/build/{s}.zig", .{name})), .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    module.addImport("zdos_fs", b.createModule(.{ .root_source_file = b.path("src/host_fs.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    module.addImport("mkmfs3", b.createModule(.{ .root_source_file = b.path("tools/disk/mkmfs3-host.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }));
    return b.addExecutable(.{ .name = name, .root_module = module });
}

fn mkmfs3Tool(b: *std.Build) *std.Build.Step {
    const module = b.createModule(.{ .root_source_file = b.path("tools/disk/mkmfs3-host.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const exe = b.addExecutable(.{ .name = "mkmfs3", .root_module = module });
    const copy = b.addUpdateSourceFiles();
    copy.addCopyFileToSource(exe.getEmittedBin(), "build/host/mkmfs3");
    return &copy.step;
}

// Runs every time: it works on build/ directly.
fn runInSources(b: *std.Build, tool: *std.Build.Step.Compile, args: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(tool);
    run.addArgs(args);
    run.setCwd(b.path("."));
    run.has_side_effects = true;
    return run;
}

fn sourceFiles(b: *std.Build, folder: []const u8) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var dir = b.build_root.handle.openDir(folder, .{ .iterate = true }) catch @panic("no source folder");
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch @panic("can't read a source folder")) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".zig") or std.mem.endsWith(u8, entry.name, ".c")) {
            list.append(b.allocator, b.pathJoin(&.{ folder, entry.name })) catch @panic("OOM");
        }
    }
    return list.items;
}
