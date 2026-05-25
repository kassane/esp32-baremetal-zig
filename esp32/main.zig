// Minimal bare-metal Zig for ESP32 (Xtensa LX6)
// Blinks GPIO2 (onboard LED on ESP32 DevKitC-V4).
// Entry via Reset vector; no std runtime, no OS.

const std = @import("std");
const mmio = @import("mmio");

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// ── Peripheral register addresses (ESP32) ────────────────────────────────────

const GPIO_BASE: u32 = 0x3FF4_4000;
/// GPIO output register – controls GPIO 0-31
const GPIO_OUT_REG: u32 = GPIO_BASE + 0x0004;
/// GPIO output enable register – GPIO 0-31
const GPIO_ENABLE_REG: u32 = GPIO_BASE + 0x0020;

// ── Application entry ─────────────────────────────────────────────────────────

export fn main() callconv(.c) noreturn {
    // GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (active-high)
    const led_mask: u32 = @as(u32, 1) << 2;

    // Enable GPIO2 as output
    mmio.setBits(GPIO_ENABLE_REG, led_mask);

    while (true) {
        mmio.setBits(GPIO_OUT_REG, led_mask); // LED ON
        mmio.delay(1_200_000);
        mmio.clearBits(GPIO_OUT_REG, led_mask); // LED OFF
        mmio.delay(1_200_000);
    }
}

// ── Reset vector ────────────────────────────────────────────────────────────

/// Entry point. QEMU `-kernel` enters with PS.WOE=0, so windowed registers must
/// be enabled and SP set (top of DRAM) before the first C-ABI call. The ROM
/// already does this on hardware, where redoing it is harmless.
export fn Reset() callconv(.naked) noreturn {
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
        \\ // ── Stack pointer: 0x3FFDC200 = 0x40000000 − 0x23E00 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x23E         // 574
        \\ slli    a0, a0, 8         // a0 = 0x0023E00
        \\ sub     a1, a1, a0        // a1 = 0x3FFDC200
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   main
        \\0:
        \\ j       0b
    );
}
