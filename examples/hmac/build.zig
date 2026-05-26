// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'hmac' example (ESP32-S3) — HMAC-SHA256 accelerator.
// Build-only: the key comes from eFuse, which QEMU leaves blank. Consumes the
// workspace root (`esp32_hal`).
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
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
        .os_tag = .esp32s3,
        .abi = .none,
    });
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    inline for (.{ "mmio", "hal", "init", "panic", "startup" }) |m| mod.addImport(m, core.module(m));
    mod.addImport("regs", core.module("esp32s3_regs"));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = "hmac", .root_module = mod });
    exe.entry = .{ .symbol_name = "call_start_cpu0" };
    exe.bundle_compiler_rt = false;
    exe.setLinkerScript(core.namedLazyPath("esp32s3.ld"));
    b.installArtifact(exe);
}
