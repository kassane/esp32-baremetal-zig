// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 (Xtensa LX7). Demonstrates the PIE/SIMD kernels
// whose inline-asm clobbers are generated at comptime by `dsp.qClobbers`:
// saturating-mix two signals (`ee.vadds.s16`), then take the energy Σ x²
// (`ee.vmulas.s16.accx`), and blink GPIO48 at a rate set by the result.
//
// (No UART here: an `ee.*` instruction is an optimization barrier that un-elides
// Debug safety-check panics in surrounding code, and those don't link on this
// backend — so the PIE example stays minimal. The FFT/UART demo lives in esp32.)

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");
const gpio = regs.GPIO;

// Custom panic namespace: UART message + backtrace, no std.fmt (see src/panic.zig).
const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// Route `std.log` through UART0 instead of std.fmt's (unlinkable) default.
pub const std_options = con.options;

// GPIO48 (onboard RGB LED) is in the second bank (pins 32-53) → OUT1/ENABLE1.
const led_mask: u32 = @as(u32, 1) << (48 - 32);
const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const cycles_per_energy: u32 = 50_000; // blink half-period = energy × this (cycles)
const Led = hal.Output(gpio.ENABLE1_W1TS, gpio.OUT1, gpio.OUT1_W1TS, gpio.OUT1_W1TC, led_mask);

// Two 8-lane int16 signals (16-byte aligned = one 128-bit PIE vector).
var sig_a: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var sig_b: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var mixed: [8]i16 align(16) = undefined;

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init(); // GPIO48 as output

    // PIE SIMD pipeline (comptime-generated `q*` clobbers): mixed = sat(a+b) =
    // [2,4,…,16], then energy = Σ mixed² = 816, which sets the blink half-period.
    dsp.addSatS16(&mixed, &sig_a, &sig_b, sig_a.len);
    const energy = dsp.dotProductS16(&mixed, &mixed, mixed.len);

    // Blink at a cycle-accurate rate set by the energy (cycle-counter Delay).
    const delay = hal.Delay(cpu_hz);
    const half = energy *% cycles_per_energy;
    while (true) {
        Led.setHigh();
        delay.cycles(half);
        Led.setLow();
        delay.cycles(half);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (the symbol the second-stage bootloader jumps to). Enables windowed
/// registers and sets SP (top of DRAM) before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
