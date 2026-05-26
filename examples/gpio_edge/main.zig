// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — poll-based GPIO edge detection. Latches falling edges
// on GPIO0 (the boot button) and toggles GPIO2's LED on each press, catching brief
// transitions a level poll could miss. **Build-only:** QEMU drives no button edges.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const Button = hal.GpioEdge(gpio.PIN_0, @as(u32, 1) << 0, gpio.STATUS, gpio.STATUS_W1TC); // GPIO0
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, @as(u32, 1) << 2); // GPIO2

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Led.init();
    Button.configure(.falling); // latch button-press (high→low) edges
    while (true) {
        if (Button.takeEdge()) Led.toggle();
        mmio.delay(50_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
