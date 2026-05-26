// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'i2s' example (ESP32) — I2S master TX (single-data
// mode, no DMA). Build-only: QEMU models no I2S, and BCK/WS/DATA need routing
// to pads via the GPIO matrix. Consumes the workspace root (`esp32_hal`).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
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
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    inline for (.{ "mmio", "hal", "init", "panic", "startup" }) |m| mod.addImport(m, core.module(m));
    mod.addImport("regs", core.module("esp32_regs"));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = "i2s", .root_module = mod });
    exe.entry = .{ .symbol_name = "Reset" };
    exe.bundle_compiler_rt = false;
    exe.setLinkerScript(core.namedLazyPath("esp32.ld"));
    b.installArtifact(exe);
}
