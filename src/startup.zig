// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Shared Xtensa reset vector. The naked `export fn` entry still lives in each
//! example, because its `call8 main` targets that example's own `main` (and
//! `call8` has limited range) — but the windowed-ABI setup and the per-chip
//! stack pointer are identical everywhere, so they're built here once as a
//! comptime asm string. An example's entry is then just:
//!
//!     export fn Reset() callconv(.naked) noreturn {
//!         asm volatile (startup.vector());
//!     }

const std = @import("std");
const builtin = @import("builtin");

const Chip = enum { esp32, esp32s2, esp32s3 };

/// The target chip, resolved from the CPU model the firmware is built for —
/// the model names (`esp32`/`esp32s2`/`esp32s3`) match the `Chip` field names.
const chip: Chip = std.meta.stringToEnum(Chip, builtin.cpu.model.name) orelse .esp32;

// Enable PS.WOE (windowed 'entry') and reset the window: WINDOWBASE=0,
// WINDOWSTART=1. Identical on every Xtensa target here.
const window_init =
    \\ .align 4
    \\ movi a0, 1
    \\ slli a0, a0, 18      // PS.WOE = bit 18
    \\ wsr.ps a0
    \\ rsync
    \\ movi a0, 0
    \\ wsr.windowbase a0
    \\ rsync
    \\ movi a0, 1
    \\ wsr.windowstart a0
    \\ rsync
    \\
;

// Per-chip initial stack pointer = top of internal DRAM, loaded as
// 0x40000000 − offset (a `movi`+`slli` immediate, since Xtensa can't `movi` a
// full 32-bit constant). Each value is within the valid DRAM range on real
// hardware, so the same source works for hardware and QEMU.
const sp_load = switch (chip) {
    .esp32 => "movi a0, 0x23E\n slli a0, a0, 8\n", // 0x40000000 − 0x23E00 = 0x3FFDC200
    .esp32s2 => "movi a0, 0x220\n slli a0, a0, 8\n", // 0x40000000 − 0x22000 = 0x3FFDE000
    .esp32s3 => "movi a0, 0x32D\n slli a0, a0, 12\n", // 0x40000000 − 0x32D000 = 0x3FCD3000
};

/// Reset prologue for the target chip: enable windowed registers, set SP to the
/// top of DRAM, then `call8 main`. Use inside the example's naked entry vector.
/// `main` must call `init.runtimeInit()` first to set up `.bss`/`.data` (a
/// near-callable literal pool for the segment bounds is easier to get right in
/// Zig than in this naked asm).
pub fn vector() []const u8 {
    return window_init ++
        "movi a1, 1\n slli a1, a1, 30\n" ++ // a1 = 0x40000000
        sp_load ++
        "sub a1, a1, a0\n" ++ // SP = 0x40000000 − offset
        "call8 main\n" ++
        "0: j 0b\n";
}

/// Reset prologue for the RISC-V ULP low-power coprocessor (esp32s2/-s3): set
/// the stack pointer to the top of the ULP's RTC RAM (`__stack_top`, from the ULP
/// linker script) and enter `main`. The ULP's naked `reset_vector` is just
/// `asm volatile (startup.ulpVector())`, mirroring `vector()` for the Xtensa cores.
pub fn ulpVector() []const u8 {
    return
    \\ la sp, __stack_top
    \\ call main
    \\ 0: j 0b
    ;
}
