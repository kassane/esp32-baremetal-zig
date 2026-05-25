// Minimal bare-metal Zig for ESP32-S2 (Xtensa LX7, single core)
// Blinks GPIO18 (RGB LED data pin on common ESP32-S2 DevKits, e.g. Saola-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");
const gpio = @import("regs").GPIO; // generated from svd/esp32s2.svd

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO18 (RGB LED data pin on common S2 DevKits) is in bank 0. W1TS/W1TC =
// atomic write-1-to-set / write-1-to-clear, so no read-modify-write is needed.
const led_mask: u32 = @as(u32, 1) << 18;

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    mmio.writeReg(gpio.ENABLE_W1TS, led_mask); // GPIO18 as output

    while (true) {
        mmio.writeReg(gpio.OUT_W1TS, led_mask); // LED ON
        mmio.delay(1_200_000);
        mmio.writeReg(gpio.OUT_W1TC, led_mask); // LED OFF
        mmio.delay(1_200_000);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call;
/// the ROM already does this on hardware, where redoing it is harmless.
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
