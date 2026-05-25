const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // qemu-system-xtensa location + how long each smoke boot runs.
    // The smoke runner execve()s this directly, so resolve it to an absolute
    // path (PATH lookup) unless an explicit path is given.
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-xtensa (default: found on PATH)") orelse
        (b.findProgram(&.{"qemu-system-xtensa"}, &.{}) catch "qemu-system-xtensa");
    const smoke_seconds = b.option(u32, "smoke-seconds", "Seconds to run each chip during `zig build smoke`") orelse 5;

    // Shared bare-metal helpers, imported by every chip as `@import(\"mmio\")`.
    const mmio = b.createModule(.{ .root_source_file = b.path("src/mmio.zig") });

    // Portable DSP kernels (SIMD on esp32s3, scalar fallback elsewhere),
    // imported as `@import(\"dsp\")`.
    const dsp = b.createModule(.{ .root_source_file = b.path("src/dsp.zig") });

    // All generated linker scripts live in a single WriteFiles step — no *.ld
    // files on disk.
    const ld = b.addWriteFiles();

    // Host tool that boots a firmware in QEMU and checks for CPU faults.
    const smoke_tool = b.addExecutable(.{
        .name = "qemu_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/qemu_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const qemu_step = b.step("qemu", "Build all QEMU firmware images (IRAM-only)");
    const smoke_step = b.step("smoke", "Boot every QEMU-capable chip and assert no CPU faults");
    var prev_smoke: ?*std.Build.Step = null;

    inline for (chips) |chip| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = .xtensa,
            .cpu_model = .{ .explicit = chip.cpu },
            .os_tag = .freestanding,
            .abi = .none,
        });

        // ── Hardware/flash firmware (.elf + raw .bin) ────────────────────────
        const hw_exe = addFirmware(b, mmio, dsp, chip, target, optimize, chip.name ++ "_baremetal_zig");
        hw_exe.setLinkerScript(ld.add(chip.name ++ ".ld", flashLinker(b, chip)));

        const bin = b.addObjCopy(hw_exe.getEmittedBin(), .{
            .format = .bin,
            .basename = chip.name ++ "_baremetal_zig.bin",
        });

        const chip_step = b.step(chip.name, "Build " ++ chip.name ++ " baremetal firmware");
        chip_step.dependOn(&b.addInstallArtifact(hw_exe, .{}).step);
        chip_step.dependOn(&b.addInstallBinFile(bin.getOutput(), chip.name ++ "_baremetal_zig.bin").step);
        b.getInstallStep().dependOn(chip_step);

        // ── QEMU firmware (all code in IRAM, no flash-cache MMU needed) ───────
        if (chip.qemu_machine) |machine| {
            const qemu_exe = addFirmware(b, mmio, dsp, chip, target, optimize, chip.name ++ "_qemu");
            qemu_exe.setLinkerScript(ld.add(chip.name ++ "-qemu.ld", qemuLinker(b, chip)));

            const qemu_chip_step = b.step("qemu-" ++ chip.name, "Build " ++ chip.name ++ " QEMU firmware");
            qemu_chip_step.dependOn(&b.addInstallArtifact(qemu_exe, .{}).step);
            qemu_step.dependOn(qemu_chip_step);

            // `zig build run-<chip>` — launch QEMU interactively.
            const run = b.addSystemCommand(&.{ qemu_bin, "-nographic", "-machine", machine, "-kernel" });
            run.addFileArg(qemu_exe.getEmittedBin());
            run.has_side_effects = true;
            const run_step = b.step("run-" ++ chip.name, "Build + run " ++ chip.name ++ " in QEMU");
            run_step.dependOn(&run.step);

            // `zig build smoke` — non-interactive boot test (chips run in order).
            const run_smoke = b.addRunArtifact(smoke_tool);
            run_smoke.addArg(qemu_bin);
            run_smoke.addArg(machine);
            run_smoke.addFileArg(qemu_exe.getEmittedBin());
            run_smoke.addArg(b.fmt("{d}", .{smoke_seconds}));
            if (prev_smoke) |p| run_smoke.step.dependOn(p);
            prev_smoke = &run_smoke.step;
            smoke_step.dependOn(&run_smoke.step);
        }
    }
}

fn addFirmware(
    b: *std.Build,
    mmio: *std.Build.Module,
    dsp: *std.Build.Module,
    comptime chip: Chip,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(chip.name ++ "/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("mmio", mmio);
    mod.addImport("dsp", dsp);
    mod.strip = true;
    // No UBSan runtime on bare metal; Debug safety still traps via our panic.
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.entry = .{ .symbol_name = chip.entry };
    // The blink firmware uses no compiler-rt builtins; skip bundling it (the
    // freestanding-xtensa compiler-rt in the prebuilt fork fails to link).
    exe.bundle_compiler_rt = false;
    return exe;
}

// ── Linker script generators (emitted via b.addWriteFiles) ──────────────────

/// Flash layout: code in IROM, rodata in DROM, data/bss in DRAM. Mirrors the
/// IDF app image; the entry runs from flash after the ROM enables the cache.
fn flashLinker(b: *std.Build, comptime chip: Chip) []const u8 {
    return b.fmt(
        \\ENTRY({s})
        \\MEMORY {{
        \\  iram_seg (RX) : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\  dram_seg (RW) : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\  irom_seg (RX) : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\  drom_seg (R)  : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\}}
        \\SECTIONS {{
        \\  .text : ALIGN(4) {{
        \\    _stext = .;
        \\    *(.literal .text .literal.* .text.*)
        \\    _etext = .;
        \\  }} > irom_seg
        \\  .rodata : ALIGN(4) {{
        \\    _rodata_start = ABSOLUTE(.);
        \\    *(.rodata .rodata.*)
        \\    _rodata_end = ABSOLUTE(.);
        \\  }} > drom_seg
        \\  .data : ALIGN(4) {{
        \\    _data_start = ABSOLUTE(.);
        \\    *(.data .data.*)
        \\    _data_end = ABSOLUTE(.);
        \\  }} > dram_seg AT > drom_seg
        \\  _sidata = LOADADDR(.data);
        \\  .bss (NOLOAD) : ALIGN(4) {{
        \\    _bss_start = ABSOLUTE(.);
        \\    *(.bss .bss.* COMMON)
        \\    _bss_end = ABSOLUTE(.);
        \\  }} > dram_seg
        \\  .rwtext : ALIGN(4) {{
        \\    *(.rwtext .rwtext.* .rwtext.literal .rwtext.literal.*)
        \\  }} > iram_seg
        \\}}
        \\
    , .{
        chip.entry,
        chip.iram_org, chip.iram_len,
        chip.dram_org, chip.dram_len,
        chip.irom_org, chip.irom_len,
        chip.drom_org, chip.drom_len,
    });
}

/// QEMU layout: ALL code in IRAM so `qemu -kernel <elf>` runs without the ROM
/// bootloader initialising the flash cache. IRAM is oversized for Debug builds.
fn qemuLinker(b: *std.Build, comptime chip: Chip) []const u8 {
    return b.fmt(
        \\ENTRY({s})
        \\MEMORY {{
        \\  iram_seg (RX) : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\  dram_seg (RW) : ORIGIN = 0x{X}, LENGTH = 0x{X}
        \\}}
        \\SECTIONS {{
        \\  .text : ALIGN(4) {{
        \\    _stext = .;
        \\    *(.iram1 .iram1.*)
        \\    *(.literal .text .literal.* .text.*)
        \\    _etext = .;
        \\  }} > iram_seg
        \\  .rodata : ALIGN(4) {{
        \\    _rodata_start = ABSOLUTE(.);
        \\    *(.rodata .rodata.*)
        \\    _rodata_end = ABSOLUTE(.);
        \\  }} > dram_seg
        \\  .data : ALIGN(4) {{
        \\    _data_start = ABSOLUTE(.);
        \\    *(.data .data.*)
        \\    _data_end = ABSOLUTE(.);
        \\  }} > dram_seg
        \\  .bss (NOLOAD) : ALIGN(4) {{
        \\    _bss_start = ABSOLUTE(.);
        \\    *(.bss .bss.* COMMON)
        \\    _bss_end = ABSOLUTE(.);
        \\  }} > dram_seg
        \\}}
        \\
    , .{
        chip.entry,
        chip.qemu_iram_org, chip.qemu_iram_len,
        chip.qemu_dram_org, chip.qemu_dram_len,
    });
}

// ── Chip definitions ────────────────────────────────────────────────────────
// Requires the zig-espressif-bootstrap fork; upstream zig lacks esp32 CPU models.
// Addresses verified against ESP-IDF components/esp_system/ld/<chip>/memory.ld.in.

const Chip = struct {
    name: []const u8,
    cpu: *const std.Target.Cpu.Model,
    entry: []const u8,
    // Hardware/flash regions.
    iram_org: u64,
    iram_len: u64,
    dram_org: u64,
    dram_len: u64,
    irom_org: u64,
    irom_len: u64,
    drom_org: u64,
    drom_len: u64,
    // QEMU IRAM-only regions; qemu_machine == null means no QEMU support.
    qemu_machine: ?[]const u8 = null,
    qemu_iram_org: u64 = 0,
    qemu_iram_len: u64 = 0,
    qemu_dram_org: u64 = 0,
    qemu_dram_len: u64 = 0,
};

const chips = [_]Chip{
    .{
        .name = "esp32",
        .cpu = &std.Target.xtensa.cpu.esp32,
        .entry = "Reset",
        .iram_org = 0x40080000, .iram_len = 0x20000,
        .dram_org = 0x3FFB0000, .dram_len = 0x2C200,
        .irom_org = 0x400D0020, .irom_len = 0x330000 - 0x20,
        .drom_org = 0x3F400020, .drom_len = 0x400000 - 0x20,
        .qemu_machine = "esp32",
        .qemu_iram_org = 0x40080000, .qemu_iram_len = 0x100000,
        .qemu_dram_org = 0x3FFB0000, .qemu_dram_len = 0x2C200,
    },
    .{
        // ESP32-S2 has no QEMU machine in the Espressif build, so it is
        // build-only (flash image); no qemu/run/smoke targets are generated.
        .name = "esp32s2",
        .cpu = &std.Target.xtensa.cpu.esp32s2,
        .entry = "call_start_cpu0",
        .iram_org = 0x40024000, .iram_len = 0x2A000,
        .dram_org = 0x3FFB4000, .dram_len = 0x2A000,
        .irom_org = 0x40080020, .irom_len = 0x780000 - 0x20,
        .drom_org = 0x3F000020, .drom_len = 0x3F0000 - 0x20,
    },
    .{
        .name = "esp32s3",
        .cpu = &std.Target.xtensa.cpu.esp32s3,
        .entry = "call_start_cpu0",
        .iram_org = 0x40370000, .iram_len = 0x10000,
        .dram_org = 0x3FC88000, .dram_len = 0x78000,
        .irom_org = 0x42000020, .irom_len = 0x400000 - 0x20,
        .drom_org = 0x3C000020, .drom_len = 0x400000 - 0x20,
        .qemu_machine = "esp32s3",
        .qemu_iram_org = 0x40370000, .qemu_iram_len = 0x100000,
        .qemu_dram_org = 0x3FC88000, .qemu_dram_len = 0x4B000,
    },
};
