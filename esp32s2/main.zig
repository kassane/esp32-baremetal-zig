// Minimal bare-metal Zig for ESP32-S2 (Xtensa LX7, single core)
// Blinks GPIO18 (RGB LED data pin on common ESP32-S2 DevKits, e.g. Saola-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// ── Peripheral register addresses (ESP32-S2) ─────────────────────────────────
//
// GPIO18 is in the first bank (pins 0-31), so it uses the bank-0 registers.

const GPIO_BASE: u32 = 0x3F40_4000;
/// GPIO output register – GPIO 0-31
const GPIO_OUT_REG: u32 = GPIO_BASE + 0x0004;
/// GPIO output enable – GPIO 0-31
const GPIO_ENABLE_REG: u32 = GPIO_BASE + 0x0020;

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    const led_mask: u32 = @as(u32, 1) << 18;

    // Enable GPIO18 as output
    mmio.setBits(GPIO_ENABLE_REG, led_mask);

    while (true) {
        mmio.setBits(GPIO_OUT_REG, led_mask); // LED ON
        mmio.delay(1_200_000);
        mmio.clearBits(GPIO_OUT_REG, led_mask); // LED OFF
        mmio.delay(1_200_000);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// ROM bootloader jumps here (symbol expected by the IDF boot flow).
///
/// Hardware: ROM has already set PS.WOE=1 and configured the register file.
/// Re-initialising is idempotent and safe.
///
/// PS.WOE = bit 18 = 0x40000 (too large for movi; built with movi+slli).
/// Stack pointer: top of internal DRAM = 0x3FFDE000 (= 0x40000000 − 0x22000).
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
        \\ // ── Stack pointer: 0x3FFDE000 = 0x40000000 − 0x22000 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x220         // 544
        \\ slli    a0, a0, 8         // a0 = 0x0022000
        \\ sub     a1, a1, a0        // a1 = 0x3FFDE000
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
