// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'systimer' example (ESP32-S3) — reads the SoC system
// timer and logs it over UART. The Espressif QEMU esp32s3 machine emulates
// SYSTIMER, so this is QEMU-runnable: it wires `run` / `smoke` / `demo` (like the
// per-chip examples) on top of the workspace root (`esp32_hal`).
const machine = "esp32s3";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-xtensa (default: found on PATH)") orelse
        (b.findProgram(&.{"qemu-system-xtensa"}, &.{}) catch "qemu-system-xtensa");
    const smoke_seconds = b.option(u32, "smoke-seconds", "Seconds to run during `zig build smoke`") orelse 5;

    const core = b.dependency("esp32_hal", .{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .esp32s3,
        .abi = .none,
    });

    // Flash firmware: .elf + raw .bin, using the root's flash linker script.
    const hw = firmware(b, core, target, optimize, "systimer");
    hw.setLinkerScript(core.namedLazyPath("esp32s3.ld"));
    b.installArtifact(hw);
    const bin = b.addObjCopy(hw.getEmittedBin(), .{ .format = .bin, .basename = "systimer.bin" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "systimer.bin").step);

    // QEMU firmware: all code in IRAM (root's qemu linker), with run + smoke + demo.
    const qemu_exe = firmware(b, core, target, optimize, "systimer_qemu");
    qemu_exe.setLinkerScript(core.namedLazyPath("esp32s3-qemu.ld"));

    const run = b.addSystemCommand(&.{ qemu_bin, "-nographic", "-machine", machine, "-kernel" });
    run.addFileArg(qemu_exe.getEmittedBin());
    run.has_side_effects = true;
    b.step("run", "Build + run the systimer example in QEMU").dependOn(&run.step);

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
    b.step("smoke", "Boot the systimer example in QEMU and assert no CPU faults").dependOn(&run_smoke.step);

    const run_demo = b.addRunArtifact(smoke_tool);
    run_demo.addArg(qemu_bin);
    run_demo.addArg(machine);
    run_demo.addFileArg(qemu_exe.getEmittedBin());
    run_demo.addArg(b.fmt("{d}", .{smoke_seconds}));
    _ = run_demo.addOutputFileArg("esp32s3-uart.txt");
    run_demo.stdio = .inherit;
    b.step("demo", "Run the systimer example in QEMU and print its UART output").dependOn(&run_demo.step);
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
    inline for (.{ "mmio", "hal", "init", "panic", "startup" }) |m| mod.addImport(m, core.module(m));
    mod.addImport("regs", core.module("esp32s3_regs"));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.entry = .{ .symbol_name = "call_start_cpu0" };
    exe.bundle_compiler_rt = false;
    return exe;
}
