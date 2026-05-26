// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — critical section, QEMU-verified. Runs a guarded
// read-modify-write on an RTC scratch register inside hal.Critical.enter/exit (which
// mask interrupts via the Xtensa `rsil`/`wsr.ps` instructions), five times, and logs
// the counter — a known-answer check (5). Proves the mask/restore instructions
// execute cleanly. (This firmware enables no interrupts; the section is shown for
// code that does.)

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

const scratch = regs.RTC_CNTL.STORE0; // a register to read-modify-write
const iterations = 5;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.writeReg(scratch, 0);
    var n: u32 = 0;
    while (n < iterations) : (n +%= 1) {
        const token = hal.Critical.enter(); // mask interrupts
        mmio.writeReg(scratch, mmio.readReg(scratch) +% 1); // atomic against an ISR
        hal.Critical.exit(token); // restore
    }
    mmio.log(regs.UART0.FIFO, .info, "critical section OK, counter={d}", .{mmio.readReg(scratch)});
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
