// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// The "blinky" example (ESP32): toggle GPIO2's LED every 500 ms using the GPIO
// Output driver and the cycle-accurate Delay.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const led_mask: u32 = @as(u32, 1) << 2; // GPIO2 (onboard LED), bank 0
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
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
    asm volatile (startup.vector());
}
