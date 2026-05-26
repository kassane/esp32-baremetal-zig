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

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    mmio.log(regs.UART0.FIFO, level, fmt, args);
}

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
