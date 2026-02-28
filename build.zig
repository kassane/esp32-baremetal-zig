const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Each chip gets its own hardcoded resolved target.
    // Both artifacts are built by default; use `zig build esp32` or
    // `zig build esp32s3` to build a single chip.
    const esp32_target = b.resolveTargetQuery(esp32_query);
    const esp32s3_target = b.resolveTargetQuery(esp32s3_query);

    const esp32_exe = buildEsp32(b, .{ .target = esp32_target, .optimize = optimize });
    const esp32s3_exe = buildEsp32S3(b, .{ .target = esp32s3_target, .optimize = optimize });

    // ELF → raw binary (for esptool.py flashing)
    const esp32_bin = b.addObjCopy(esp32_exe.getEmittedBin(), .{
        .format = .bin,
        .basename = "esp32_baremetal_zig.bin",
    });
    const esp32s3_bin = b.addObjCopy(esp32s3_exe.getEmittedBin(), .{
        .format = .bin,
        .basename = "esp32s3_baremetal_zig.bin",
    });

    // Named steps for single-chip builds (ELF + .bin)
    const esp32_step = b.step("esp32", "Build ESP32 baremetal firmware");
    esp32_step.dependOn(&b.addInstallArtifact(esp32_exe, .{}).step);
    esp32_step.dependOn(&b.addInstallBinFile(esp32_bin.getOutput(), "esp32_baremetal_zig.bin").step);

    const esp32s3_step = b.step("esp32s3", "Build ESP32-S3 baremetal firmware");
    esp32s3_step.dependOn(&b.addInstallArtifact(esp32s3_exe, .{}).step);
    esp32s3_step.dependOn(&b.addInstallBinFile(esp32s3_bin.getOutput(), "esp32s3_baremetal_zig.bin").step);

    // Default `zig build` builds both
    b.getInstallStep().dependOn(esp32_step);
    b.getInstallStep().dependOn(esp32s3_step);

    // ── QEMU targets (code in IRAM, no flash-cache MMU needed) ───────────────
    // Use a separate linker script that places all code in IRAM so that
    // qemu-system-xtensa -machine esp32/esp32s3 -kernel <elf> works without
    // the ROM bootloader initialising the flash cache.
    const qemu_esp32_exe = buildQemu(b, .{
        .name = "esp32_qemu",
        .src = "esp32/main.zig",
        .target = esp32_target,
        .optimize = optimize,
        .linker_script = "esp32/qemu.ld",
        .entry = .disabled,
    });
    const qemu_esp32s3_exe = buildQemu(b, .{
        .name = "esp32s3_qemu",
        .src = "esp32s3/main.zig",
        .target = esp32s3_target,
        .optimize = optimize,
        .linker_script = "esp32s3/qemu.ld",
        .entry = .{ .symbol_name = "call_start_cpu0" },
    });

    const qemu_esp32_step = b.step("qemu-esp32", "Build ESP32 QEMU firmware (IRAM-only)");
    qemu_esp32_step.dependOn(&b.addInstallArtifact(qemu_esp32_exe, .{}).step);

    const qemu_esp32s3_step = b.step("qemu-esp32s3", "Build ESP32-S3 QEMU firmware (IRAM-only)");
    qemu_esp32s3_step.dependOn(&b.addInstallArtifact(qemu_esp32s3_exe, .{}).step);

    const qemu_step = b.step("qemu", "Build both QEMU firmware images");
    qemu_step.dependOn(qemu_esp32_step);
    qemu_step.dependOn(qemu_esp32s3_step);
}

fn buildQemu(b: *std.Build, opt: struct {
    name: []const u8,
    src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linker_script: []const u8,
    entry: std.Build.Step.Compile.Entry,
}) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = opt.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(opt.src),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });
    exe.root_module.strip = true;
    exe.bundle_compiler_rt = true;
    exe.entry = opt.entry;
    exe.setLinkerScript(b.path(opt.linker_script));
    return exe;
}

fn buildEsp32(b: *std.Build, opt: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
}) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "esp32_baremetal_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("esp32/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });
    exe.root_module.strip = true;
    // compiler-rt provides memset/memcpy/memmove/__umoddi3 for freestanding
    exe.bundle_compiler_rt = true;
    exe.entry = .disabled;
    exe.setLinkerScript(b.path("esp32/xtensa.x"));
    return exe;
}

fn buildEsp32S3(b: *std.Build, opt: struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
}) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "esp32s3_baremetal_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("esp32s3/main.zig"),
            .target = opt.target,
            .optimize = opt.optimize,
        }),
    });
    exe.root_module.strip = true;
    exe.bundle_compiler_rt = true;
    exe.entry = .{ .symbol_name = "call_start_cpu0" };
    exe.setLinkerScript(b.path("esp32s3/linker.ld"));
    return exe;
}

// ── Target queries ────────────────────────────────────────────────────────────
// Requires the zig-espressif-bootstrap fork; upstream zig lacks esp32 CPU models.

const esp32_query = std.Target.Query{
    .cpu_arch = .xtensa,
    .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32 },
    .os_tag = .freestanding,
    .abi = .none,
};

const esp32s2_query = std.Target.Query{
    .cpu_arch = .xtensa,
    .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s2 },
    .os_tag = .freestanding,
    .abi = .none,
};

const esp32s3_query = std.Target.Query{
    .cpu_arch = .xtensa,
    .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 },
    .os_tag = .freestanding,
    .abi = .none,
};
