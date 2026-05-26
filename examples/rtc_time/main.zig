// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — RTC main-timer uptime over UART. Reads the always-on
// 48-bit RTC slow-clock counter (hal.RtcTime), which keeps running through deep
// sleep, and logs it each iteration. If the Espressif QEMU esp32 machine advances
// the RTC timer, `zig build demo` shows the count climbing.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

pub const std_options = con.options;

const Clock = hal.RtcTime(regs.RTC_CNTL);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.puts(regs.UART0.FIFO, "\r\nESP32 bare-metal Zig — RTC main-timer uptime\r\n");
    while (true) {
        // Low 32 bits advance fastest; the formatter prints u32 (see mmio.argU32).
        mmio.log(regs.UART0.FIFO, .info, "rtc ticks {d}", .{@as(u32, @truncate(Clock.now()))});
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
