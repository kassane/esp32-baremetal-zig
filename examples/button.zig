// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// GPIO input→output example (ESP32): mirror the GPIO0 boot button onto GPIO2's
// LED. Reads the input with the GPIO Input driver and drives the Output to match.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const gpio = regs.GPIO;

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const poll_iters: u32 = 200_000; // busy-loop iterations between samples
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0 (boot button)
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, @as(u32, 1) << 2); // GPIO2

export fn main() callconv(.c) noreturn {
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
