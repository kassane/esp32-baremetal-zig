// Minimal bare-metal Zig for ESP32-S3 (Xtensa LX7)
// Blinks GPIO48 (onboard RGB LED on ESP32-S3-DevKitC-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const gpio = regs.GPIO;

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO48 (onboard RGB LED) is in the second bank (pins 32-53), bit 48-32 = 16,
// so it uses the OUT1/ENABLE1 registers. W1TS/W1TC = atomic write-1-to-set/clear.
const led_mask: u32 = @as(u32, 1) << (48 - 32);

// Two 8-lane int16 signals (16-byte aligned = one 128-bit PIE vector).
var sig_a: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var sig_b: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var mixed: [8]i16 align(16) = undefined;

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    mmio.writeReg(gpio.ENABLE1_W1TS, led_mask); // GPIO48 as output

    // A two-stage DSP pipeline on the PIE unit: saturating-mix the signals
    // (mixed = [2,4,…,16]) then take the energy Σ mixed² = 816. The blink
    // half-period is derived from it, keeping the SIMD results live.
    dsp.addSatS16(&mixed, &sig_a, &sig_b, sig_a.len);
    const energy = dsp.dotProductS16(&mixed, &mixed, mixed.len);
    const half_period: u32 = ((energy & 0x3F) +% 8) *% 24_000;

    while (true) {
        mmio.writeReg(gpio.OUT1_W1TS, led_mask); // LED ON
        mmio.delay(half_period);
        mmio.writeReg(gpio.OUT1_W1TC, led_mask); // LED OFF
        mmio.delay(half_period);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). QEMU `-kernel` enters
/// with PS.WOE=0, so windowed registers must be enabled and SP set (top of
/// DRAM) before the first C-ABI call; the ROM already does this on hardware.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (
        \\ .align 4
        \\ // ── PS.WOE = bit 18 (enables windowed 'entry' instructions) ──────
        \\ movi    a0, 1
        \\ slli    a0, a0, 18        // a0 = 0x00040000
        \\ wsr.ps  a0
        \\ rsync
        \\ // ── Windowed register file: WINDOWBASE=0, WINDOWSTART=1 ──────────
        \\ movi    a0, 0
        \\ wsr.windowbase a0
        \\ rsync
        \\ movi    a0, 1
        \\ wsr.windowstart a0
        \\ rsync
        \\ // ── Stack pointer: 0x3FCD3000 = 0x40000000 − 0x32D000 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x32D         // 813
        \\ slli    a0, a0, 12        // a0 = 0x32D000
        \\ sub     a1, a1, a0        // a1 = 0x3FCD3000
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
