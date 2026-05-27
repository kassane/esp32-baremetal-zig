// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// GPIO input→output example (ESP32): mirror the GPIO0 boot button onto GPIO2's
// LED. Reads the input with the GPIO Input driver and drives the Output to match.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const poll_iters: u32 = 200_000; // busy-loop iterations between samples
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0 (boot button)
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, @as(u32, 1) << 2); // GPIO2

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init();
    // Drive the LED from the button each poll. The boolean `isHigh` form keeps
    // the loop read panic-free (a `switch` on the Level enum wouldn't link here).
    while (true) {
        if (Button.isHigh()) Led.setHigh() else Led.setLow();
        mmio.delay(poll_iters);
    }
}

/// ESP32 entry: enable windowed registers + set SP (top of DRAM) before the
/// first C-ABI call (the ROM already does this on hardware).
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
