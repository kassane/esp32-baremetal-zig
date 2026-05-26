// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — RTC retention scratch register. Writes a magic value
// to RTC_CNTL.STORE0 (hal.RtcStore) and reads it back, logging OK/MISMATCH over
// UART. The store lives in the always-on RTC domain, so it survives deep sleep and
// every reset bar power-on — firmware uses it for boot counters and sleep state.
// The Espressif QEMU esp32 machine backs the register, so `zig build demo` shows
// the round-trip succeed.

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

const Scratch = hal.RtcStore(regs.RTC_CNTL.STORE0);
const magic: u32 = 0xC0FFEE42;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.puts(regs.UART0.FIFO, "\r\nESP32 bare-metal Zig — RTC scratch register\r\n");
    Scratch.write(magic);
    const got = Scratch.read();
    // `{d}` (printU32) not `{x}`: the hex path's digit-table lookup emits a
    // bounds-check whose panic path won't link next to the volatile MMIO writes.
    mmio.log(regs.UART0.FIFO, .info, "RTC STORE0 round-trip: {s} (wrote {d}, read {d})", .{ if (got == magic) "OK" else "MISMATCH", magic, got });
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
