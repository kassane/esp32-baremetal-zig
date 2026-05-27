// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 — system-timer uptime over UART. Reads the always-on
// 52-bit SYSTIMER (hal.SysTimer), a monotonic time base independent of the CPU
// cycle counter, and logs it each iteration. The Espressif QEMU esp32s3 machine
// emulates SYSTIMER, so `zig build demo` shows the count advancing live; the LED
// on GPIO48 toggles alongside.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");
const gpio = regs.GPIO;

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// Route `std.log` through UART0 instead of std.fmt's (unlinkable) default.
pub const std_options = con.options;

const Timer = hal.SysTimer(regs.SYSTIMER);
// GPIO48 (onboard RGB LED data pin) is in the second bank (pins 32-53) → OUT1.
const led_mask: u32 = @as(u32, 1) << (48 - 32);
const Led = hal.Output(gpio.ENABLE1_W1TS, gpio.OUT1, gpio.OUT1_W1TS, gpio.OUT1_W1TC, led_mask);

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    Led.init();
    Timer.init();
    mmio.puts(regs.UART0.FIFO, "\r\nESP32-S3 bare-metal Zig — system-timer uptime\r\n");

    var on = false;
    while (true) {
        // Low 32 bits advance fastest; the formatter prints u32 (see mmio.argU32).
        mmio.log(regs.UART0.FIFO, .info, "systimer {d}", .{@as(u32, @truncate(Timer.count()))});
        on = !on;
        if (on) Led.setHigh() else Led.setLow();
        mmio.delay(2_000_000);
    }
}

/// ESP32-S3 entry: enable windowed registers + set SP before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
