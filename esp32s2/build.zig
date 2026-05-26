// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the ESP32-S2 example. Consumes the workspace root
// (`esp32_baremetal_zig`) as a local path dependency for the shared modules
// (mmio/dsp/init/panic), the SVD-generated registers, and the linker script.
// Build-only: the Espressif QEMU fork has no esp32s2 machine, so there is no
// run/smoke step. Requires the zig-espressif-bootstrap fork (esp32s2 CPU model).

const regs_module = "esp32s2_regs";
const entry_sym = "call_start_cpu0";

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("esp32_baremetal_zig", .{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s2 },
        .os_tag = .freestanding,
        .abi = .none,
    });

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
    mod.addImport("regs", core.module(regs_module));
    mod.strip = true;
    mod.sanitize_c = .off;

    const hw = b.addExecutable(.{ .name = "esp32s2_baremetal_zig", .root_module = mod });
    hw.entry = .{ .symbol_name = entry_sym };
    hw.bundle_compiler_rt = false;
    hw.setLinkerScript(core.namedLazyPath("esp32s2.ld"));
    b.installArtifact(hw);

    const bin = b.addObjCopy(hw.getEmittedBin(), .{ .format = .bin, .basename = "esp32s2_baremetal_zig.bin" });
    b.getInstallStep().dependOn(&b.addInstallBinFile(bin.getOutput(), "esp32s2_baremetal_zig.bin").step);
}
