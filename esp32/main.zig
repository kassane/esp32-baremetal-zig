// Minimal bare-metal Zig for ESP32 (Xtensa LX6)
// Blinks GPIO2 (onboard LED on ESP32 DevKitC-V4).
// Entry via Reset vector; no std runtime, no OS.

const std = @import("std");
const mmio = @import("mmio");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const gpio = regs.GPIO;

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (bank 0). W1TS/W1TC = atomic
// write-1-to-set / write-1-to-clear, so no read-modify-write is needed.
const led_pin: u5 = 2;
const led_mask: u32 = @as(u32, 1) << led_pin;
const blink_half_period: u32 = 1_200_000;

// ── Application entry ─────────────────────────────────────────────────────────

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    mmio.writeReg(gpio.ENABLE_W1TS, led_mask); // GPIO2 as output
    mmio.blink(gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask, blink_half_period);
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
