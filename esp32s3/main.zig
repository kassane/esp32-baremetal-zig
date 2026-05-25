// Minimal bare-metal Zig for ESP32-S3 (Xtensa LX7)
// Blinks GPIO48 (onboard RGB LED on ESP32-S3-DevKitC-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// ── Peripheral register addresses (ESP32-S3) ─────────────────────────────────
//
// GPIO pins 0-31  → GPIO_OUT_REG    / GPIO_ENABLE_REG
// GPIO pins 32-53 → GPIO_OUT1_REG   / GPIO_ENABLE1_REG
//
// GPIO48 is in the second bank: bit (48 - 32) = 16.

const GPIO_BASE: u32 = 0x6000_4000;
/// GPIO output register – GPIO 32-53
const GPIO_OUT1_REG: u32 = GPIO_BASE + 0x0008;
/// GPIO output enable – GPIO 32-53
const GPIO_ENABLE1_REG: u32 = GPIO_BASE + 0x0024;

// ── ESP32-S3 SIMD (PIE) demo input ────────────────────────────────────────────
//
// Two 8-lane int16 vectors (16-byte aligned = one 128-bit PIE vector). Their
// dot product Σ i² over 1..8 = 204 is computed by `dsp.dotProductS16`, which
// uses the LX7 Processor Instruction Extensions here and a scalar fallback on
// chips without them.
var vec_a: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
var vec_b: [8]i16 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8 };

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    // GPIO48 = onboard RGB LED on ESP32-S3-DevKitC-1
    // Pin >= 32 → second bank; bit position = pin - 32
    const led_mask: u32 = @as(u32, 1) << (48 - 32);

    // Enable GPIO48 as output (second bank)
    mmio.setBits(GPIO_ENABLE1_REG, led_mask);

    // Drive the blink half-period from a real SIMD dot product (= 204), so the
    // vector result stays live: (204 & 0x3F = 12) + 8 = 20, ×60_000 = 1.2M.
    const dot = dsp.dotProductS16(&vec_a, &vec_b, vec_a.len);
    const half_period: u32 = ((dot & 0x3F) +% 8) *% 60_000;

    while (true) {
        mmio.setBits(GPIO_OUT1_REG, led_mask); // LED ON
        mmio.delay(half_period);
        mmio.clearBits(GPIO_OUT1_REG, led_mask); // LED OFF
        mmio.delay(half_period);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// ROM bootloader jumps here (symbol expected by the IDF boot flow).
///
/// Hardware: ROM has already set PS.WOE=1 and configured the register file.
/// Re-initialising is idempotent and safe.
///
/// QEMU (-kernel): jumps here with PS.WOE=0, making every windowed 'entry'
/// instruction illegal.  We must set WOE and init the register window before
/// any Zig C-ABI function (which begins with 'entry a1,N') runs.
///
/// PS.WOE = bit 18 = 0x40000 (too large for movi; built with movi+slli).
/// Stack pointer: top of DRAM = 0x3FCD3000 (0x3FC88000 + 300 K for QEMU).
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
