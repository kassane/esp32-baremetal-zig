// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — IO_MUX pad config (build-only). Enables GPIO0's input
// buffer with an internal pull-up, then mirrors the boot button onto GPIO2.
// Shows hal.IoMux (electrical config) alongside hal.Input/Output (logic level).
// Build-only: the pull-resistor effect isn't observable in QEMU.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Pad0 = hal.IoMux(regs.IO_MUX.GPIO0);
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, @as(u32, 1) << 2); // GPIO2

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    Pad0.config(.up, true, 2); // pull-up, input enabled, mid drive
    Led.init();
    while (true) {
        if (Button.isHigh()) Led.setHigh() else Led.setLow();
        mmio.delay(200_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
