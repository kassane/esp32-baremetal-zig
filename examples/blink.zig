// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// The "blinky" example (ESP32): toggle GPIO2's LED every 500 ms using the GPIO
// Output driver and the cycle-accurate Delay.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const gpio = regs.GPIO;

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const led_mask: u32 = @as(u32, 1) << 2; // GPIO2 (onboard LED), bank 0
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init();
    const delay = hal.Delay(cpu_hz);
    while (true) {
        Led.setHigh();
        delay.millis(500);
        Led.setLow();
        delay.millis(500);
    }
}

/// ESP32 entry: enable windowed registers + set SP (top of DRAM) before the
/// first C-ABI call (the ROM already does this on hardware).
export fn Reset() callconv(.naked) noreturn {
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
        \\ movi    a0, 0x23E
        \\ slli    a0, a0, 8         // a0 = 0x23E00
        \\ sub     a1, a1, a0        // SP = 0x3FFDC200 (top of DRAM)
        \\ call8   main
        \\0:
        \\ j       0b
    );
}
