// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'critical' example (ESP32) — critical section. The
// mask/restore instructions run under QEMU, so this wires `run` / `smoke` / `demo`
// on top of the workspace root (`esp32_hal`).
const machine = "esp32";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const qemu_bin = b.option([]const u8, "qemu", "Path to qemu-system-xtensa (default: found on PATH)") orelse
        (b.findProgram(&.{"qemu-system-xtensa"}, &.{}) catch "qemu-system-xtensa");
    const smoke_seconds = b.option(u32, "smoke-seconds", "Seconds to run during `zig build smoke`") orelse 5;

    // Forward the workspace config knobs so `-Dlog-level` / `-Dpanic-trace` work
    // from this example dir (they reconfigure the prebuilt mmio/hal in the dep).
    const log_level = b.option(std.log.Level, "log-level", "Minimum std.log level compiled in (err|warn|info|debug)") orelse .info;
    const panic_trace = b.option(bool, "panic-trace", "Print a UART stack backtrace from the panic handler") orelse true;
    const core = b.dependency("esp32_hal", .{
        .optimize = optimize,
        .@"log-level" = log_level,
        .@"panic-trace" = panic_trace,
    });
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .esp32,
        .abi = .none,
    });

    const hw = firmware(b, core, target, optimize, "critical");
    hw.setLinkerScript(core.namedLazyPath("esp32.ld"));
    b.installArtifact(hw);
    const bin = b.addObjCopy(hw.getEmittedBin(), .{ .format = .bin, .basename = "critical.bin" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "critical.bin").step);

    const qemu_exe = firmware(b, core, target, optimize, "critical_qemu");
    qemu_exe.setLinkerScript(core.namedLazyPath("esp32-qemu.ld"));

    const run = b.addSystemCommand(&.{ qemu_bin, "-nographic", "-machine", machine, "-kernel" });
    run.addFileArg(qemu_exe.getEmittedBin());
    run.has_side_effects = true;
    b.step("run", "Build + run the critical example in QEMU").dependOn(&run.step);

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
    b.step("smoke", "Boot the critical example in QEMU and assert no CPU faults").dependOn(&run_smoke.step);

    const run_demo = b.addRunArtifact(smoke_tool);
    run_demo.addArg(qemu_bin);
    run_demo.addArg(machine);
    run_demo.addFileArg(qemu_exe.getEmittedBin());
    run_demo.addArg(b.fmt("{d}", .{smoke_seconds}));
    _ = run_demo.addOutputFileArg("esp32-uart.txt");
    run_demo.stdio = .inherit;
    b.step("demo", "Run the critical example in QEMU and print its UART output").dependOn(&run_demo.step);
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
    mod.addImport("regs", core.module("esp32_regs"));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    exe.entry = .{ .symbol_name = "Reset" };
    exe.bundle_compiler_rt = false;
    return exe;
}
