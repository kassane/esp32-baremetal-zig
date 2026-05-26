// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the ESP32-S3 example. Consumes the workspace root
// (`esp32_hal`) as a local path dependency for the shared modules
// (mmio/dsp/init/panic), the SVD-generated registers, and the linker scripts.
// Requires the zig-espressif-bootstrap fork (esp32s3 CPU model + PIE).

const regs_module = "esp32s3_regs";
const entry_sym = "call_start_cpu0";
const machine = "esp32s3";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-xtensa (default: found on PATH)") orelse
        (b.findProgram(&.{"qemu-system-xtensa"}, &.{}) catch "qemu-system-xtensa");
    const smoke_seconds = b.option(u32, "smoke-seconds", "Seconds to run during `zig build smoke`") orelse 5;

    const core = b.dependency("esp32_hal", .{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .esp32s3, // Espressif fork: xtensa-esp32s3-none selects the CPU
        .abi = .none,
    });

    // Flash firmware: .elf + raw .bin, using the root's flash linker script.
    const hw = firmware(b, core, target, optimize, "esp32s3_baremetal_zig");
    hw.setLinkerScript(core.namedLazyPath("esp32s3.ld"));
    b.installArtifact(hw);
    const bin = b.addObjCopy(hw.getEmittedBin(), .{ .format = .bin, .basename = "esp32s3_baremetal_zig.bin" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "esp32s3_baremetal_zig.bin").step);

    // QEMU firmware: all code in IRAM (root's qemu linker), with run + smoke.
    const qemu_exe = firmware(b, core, target, optimize, "esp32s3_qemu");
    qemu_exe.setLinkerScript(core.namedLazyPath("esp32s3-qemu.ld"));

    const run = b.addSystemCommand(&.{ qemu_bin, "-nographic", "-machine", machine, "-kernel" });
    run.addFileArg(qemu_exe.getEmittedBin());
    run.has_side_effects = true;
    b.step("run", "Build + run the ESP32-S3 example in QEMU").dependOn(&run.step);

    const smoke_tool = b.addExecutable(.{
        .name = "qemu_smoke",
        .root_module = b.createModule(.{
            .root_source_file = core.path("tools/qemu_smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_smoke = b.addRunArtifact(smoke_tool);
    run_smoke.addArg(qemu_bin);
    run_smoke.addArg(machine);
    run_smoke.addFileArg(qemu_exe.getEmittedBin());
    run_smoke.addArg(b.fmt("{d}", .{smoke_seconds}));
    b.step("smoke", "Boot the ESP32-S3 example in QEMU and assert no CPU faults").dependOn(&run_smoke.step);

    // `zig build demo` — same boot, but capture the UART output and print it.
    // (The PIE example drives the LED and prints no UART, so this just shows it
    // boots and runs cleanly.)
    const run_demo = b.addRunArtifact(smoke_tool);
    run_demo.addArg(qemu_bin);
    run_demo.addArg(machine);
    run_demo.addFileArg(qemu_exe.getEmittedBin());
    run_demo.addArg(b.fmt("{d}", .{smoke_seconds}));
    _ = run_demo.addOutputFileArg("esp32s3-uart.txt");
    run_demo.stdio = .inherit;
    b.step("demo", "Run the ESP32-S3 example in QEMU and print its UART output").dependOn(&run_demo.step);
}

fn firmware(
    b: *std.Build,
    core: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("mmio", core.module("mmio"));
    mod.addImport("dsp", core.module("dsp"));
    mod.addImport("init", core.module("init"));
    mod.addImport("panic", core.module("panic"));
    mod.addImport("hal", core.module("hal"));
    mod.addImport("startup", core.module("startup"));
    mod.addImport("regs", core.module(regs_module));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.entry = .{ .symbol_name = entry_sym };
    exe.bundle_compiler_rt = false;
    return exe;
}
