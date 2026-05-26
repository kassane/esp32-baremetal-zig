// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 — stack-overflow monitor (build-only). Arms the
// ASSIST_DEBUG SP-spill monitor over the main stack region (hal.StackMonitor); the
// hardware records a violation if the stack pointer ever leaves the range, which a
// firmware can poll or take as an interrupt. **Build-only:** the Espressif QEMU
// does not model ASSIST_DEBUG.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    mmio.log(regs.UART0.FIFO, level, fmt, args);
}

const Stack = hal.StackMonitor(regs.ASSIST_DEBUG);
// The ESP32-S3 main stack sits near the top of DRAM (startup sets SP = 0x3FCD3000).
const stack_low: u32 = 0x3FCC_0000;
const stack_high: u32 = 0x3FCD_3000;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Stack.watchStack(stack_low, stack_high);
    while (true) {
        mmio.log(regs.UART0.FIFO, .info, "stack monitor armed, overflow: {s}", .{if (Stack.tripped()) "YES" else "no"});
        mmio.delay(8_000_000);
    }
}

/// ESP32-S3 entry: enable windowed registers + set SP before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
