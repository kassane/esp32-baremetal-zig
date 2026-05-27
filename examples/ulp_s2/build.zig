// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Standalone package for the 'ulp_s2' example — a RISC-V (riscv32imc) program for
// the ESP32-S2 ULP low-power coprocessor. Unlike the other examples (Xtensa main
// core), this targets the ULP core and consumes the workspace root (`esp32_hal`)
// only for `mmio`, the `panic` namespace and the generated ULP registers
// (`esp32s2-ulp_regs`). Build-only: QEMU does not run the ULP.
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
    // The ULP on the ESP32-S2/-S3 is a rv32imc RISC-V core (freestanding).
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv32 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .c }),
    });
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    inline for (.{ "mmio", "hal", "panic", "startup" }) |m| mod.addImport(m, core.module(m));
    mod.addImport("regs", core.module("esp32s2-ulp_regs"));
    mod.strip = true;
    mod.sanitize_c = .off;
    const exe = b.addExecutable(.{ .name = "ulp_s2", .root_module = mod });
    exe.entry = .{ .symbol_name = "reset_vector" };
    exe.bundle_compiler_rt = false;

    // ULP RISC-V layout: 8 KB of RTC slow memory at origin 0, reset vector at 0x0
    // (mirrors esp-lp-hal's link-ulp.x). Generated here — no .ld file on disk.
    const ld = b.addWriteFiles();
    exe.setLinkerScript(ld.add("ulp.ld",
        \\ENTRY(reset_vector)
        \\MEMORY { ram (RWX) : ORIGIN = 0, LENGTH = 8K }
        \\SECTIONS {
        \\  .text : {
        \\    *(.text.vectors)
        \\    *(.text .text.*)
        \\  } > ram
        \\  .rodata ALIGN(8) : { *(.rodata .rodata.*) } > ram
        \\  .data ALIGN(4) : { *(.data .data.* .sdata .sdata.*) } > ram
        \\  .bss ALIGN(4) : { *(.bss .bss.* .sbss .sbss.* COMMON) } > ram
        \\  __stack_top = ORIGIN(ram) + LENGTH(ram);
        \\}
        \\
    ));
    b.installArtifact(exe);
}
