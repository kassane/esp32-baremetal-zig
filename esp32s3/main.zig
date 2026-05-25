// Minimal bare-metal Zig for ESP32-S3 (Xtensa LX7)
// Blinks GPIO48 (onboard RGB LED on ESP32-S3-DevKitC-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");

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

// ── ESP32-S3 SIMD (PIE) ──────────────────────────────────────────────────────
//
// The LX7 carries Espressif's Processor Instruction Extensions: eight 128-bit
// vector registers (q0-q7) with integer/DSP ops. `ee.vadds.s8` adds sixteen
// signed 8-bit lanes with saturation; 128-bit loads/stores require 16-byte
// alignment. This whole block is gated by the `esp32s3ops` CPU feature, so the
// same source will not assemble for the LX6 `esp32`.

/// Two 16-lane int8 inputs whose lane-wise sums are all 17 (1+16, 2+15, …).
var simd_lhs: [16]i8 align(16) = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
var simd_rhs: [16]i8 align(16) = .{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };
var simd_sum: [16]i8 align(16) = undefined;

/// `out[i] = saturate(a[i] + b[i])` for sixteen int8 lanes, on the PIE unit.
inline fn vaddS8(a: *align(16) const [16]i8, b: *align(16) const [16]i8, out: *align(16) [16]i8) void {
    asm volatile (
        \\ ee.vld.128.ip q0, %[a], 0
        \\ ee.vld.128.ip q1, %[b], 0
        \\ ee.vadds.s8   q2, q0, q1
        \\ ee.vst.128.ip q2, %[o], 0
        :
        : [a] "r" (a),
          [b] "r" (b),
          [o] "r" (out),
        : .{ .q0 = true, .q1 = true, .q2 = true, .memory = true });
}

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    // GPIO48 = onboard RGB LED on ESP32-S3-DevKitC-1
    // Pin >= 32 → second bank; bit position = pin - 32
    const led_mask: u32 = @as(u32, 1) << (48 - 32);

    // Enable GPIO48 as output (second bank)
    mmio.setBits(GPIO_ENABLE1_REG, led_mask);

    // Compute the blink half-period on the SIMD unit: every lane is 17, so the
    // on/off delay is 17 × 70_000 ≈ 1.19M busy-loops. Driving the timing from
    // simd_sum keeps the vector result live (no dead-code elimination).
    vaddS8(&simd_lhs, &simd_rhs, &simd_sum);
    const half_period: u32 = @as(u32, @as(u8, @bitCast(simd_sum[0]))) *% 70_000;

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
