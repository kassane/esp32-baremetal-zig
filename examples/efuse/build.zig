// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the eFuse example (ESP32). Reads the factory base MAC
// address from eFuse and prints it over UART — the identity Wi-Fi/Bluetooth/
// Ethernet interfaces all derive from. eFuse is one of the blocks the Espressif
// QEMU fork emulates, so this runs under `zig build demo`/`smoke` as well as on
// real hardware. Consumes the workspace root (`esp32_hal`) as a path dependency.

const regs_module = "esp32_regs";
const entry_sym = "Reset";
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
        .@"log-level" = log_level,
        .@"panic-trace" = panic_trace,
    });
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .esp32,
        .abi = .none,
    });

    // Flash firmware: .elf + raw .bin, using the root's flash linker script.
    const hw = firmware(b, core, target, optimize, "efuse");
    hw.setLinkerScript(core.namedLazyPath("esp32.ld"));
    b.installArtifact(hw);
    const bin = b.addObjCopy(hw.getEmittedBin(), .{ .format = .bin, .basename = "efuse.bin" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "efuse.bin").step);

    // QEMU firmware: all code in IRAM (root's qemu linker), with run + smoke.
    const qemu_exe = firmware(b, core, target, optimize, "efuse_qemu");
    qemu_exe.setLinkerScript(core.namedLazyPath("esp32-qemu.ld"));

    const run = b.addSystemCommand(&.{ qemu_bin, "-nographic", "-machine", machine, "-kernel" });
    run.addFileArg(qemu_exe.getEmittedBin());
    run.has_side_effects = true;
    b.step("run", "Build + run the eFuse example in QEMU").dependOn(&run.step);

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
    b.step("smoke", "Boot the eFuse example in QEMU and assert no CPU faults").dependOn(&run_smoke.step);

    // `zig build demo` — same boot, but capture the UART output and print it.
    const run_demo = b.addRunArtifact(smoke_tool);
    run_demo.addArg(qemu_bin);
    run_demo.addArg(machine);
    run_demo.addFileArg(qemu_exe.getEmittedBin());
    run_demo.addArg(b.fmt("{d}", .{smoke_seconds}));
    _ = run_demo.addOutputFileArg("efuse-uart.txt");
    run_demo.stdio = .inherit;
    b.step("demo", "Run the eFuse example in QEMU and print its UART output").dependOn(&run_demo.step);
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
