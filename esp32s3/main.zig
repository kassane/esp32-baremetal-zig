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
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const gpio = regs.GPIO;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO48 (onboard RGB LED) is in the second bank (pins 32-53) → OUT1/ENABLE1.
const led_mask: u32 = @as(u32, 1) << (48 - 32);

// Two 8-lane int16 signals (16-byte aligned = one 128-bit PIE vector).
var sig_a: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var sig_b: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var mixed: [8]i16 align(16) = undefined;

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    mmio.writeReg(gpio.ENABLE1_W1TS, led_mask); // GPIO48 as output

    // PIE SIMD pipeline (comptime-generated `q*` clobbers): mixed = sat(a+b) =
    // [2,4,…,16], then energy = Σ mixed² = 816, which sets the blink half-period.
    dsp.addSatS16(&mixed, &sig_a, &sig_b, sig_a.len);
    const half_period = dsp.dotProductS16(&mixed, &mixed, mixed.len);

    mmio.blink(gpio.OUT1_W1TS, gpio.OUT1_W1TC, led_mask, half_period);
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). Enables windowed
/// registers and sets SP (top of DRAM) before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (
        \\ .align 4
        \\ movi    a0, 1
        \\ slli    a0, a0, 18        // PS.WOE = bit 18
        \\ wsr.ps  a0
        \\ rsync
        \\ movi    a0, 0
        \\ wsr.windowbase a0
        \\ rsync
        \\ movi    a0, 1
        \\ wsr.windowstart a0
        \\ rsync
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x32D
        \\ slli    a0, a0, 12        // a0 = 0x32D000
        \\ sub     a1, a1, a0        // SP = 0x3FCD3000 (top of DRAM)
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
