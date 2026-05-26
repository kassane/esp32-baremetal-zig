// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'rmt' example (ESP32) — IR remote (NEC-style)
// transmit over the RMT peripheral. Build-only: the Espressif QEMU machines
// don't model RMT, so this compiles and links (and runs on real hardware, once
// the channel is routed to an IR LED pad with a 38 kHz carrier) but has no
// emulator target. Consumes the workspace root (`esp32_hal`) as a path dependency.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("esp32_hal", .{});
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
    const exe = b.addExecutable(.{ .name = "rmt", .root_module = mod });
    exe.entry = .{ .symbol_name = "Reset" };
    exe.bundle_compiler_rt = false;
    exe.setLinkerScript(core.namedLazyPath("esp32.ld"));
    b.installArtifact(exe);
}
