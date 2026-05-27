// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — cooperative super-loop scheduler, QEMU-verified.
// `hal.runTasks` runs two periodic tasks round-robin off the CPU cycle counter
// (no RTOS, no preemption, no interrupts): a fast "tick" task and a slower
// "heartbeat" task, each logging its own counter over UART0 — so the demo shows
// them interleaving at their different rates. This adapts the RTOS "set of
// periodic tasks" idea to the inline/no-far-call backend. Runs live under
// `zig build demo`.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const std = @import("std");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;
pub const std_options = con.options;

const uart = regs.UART0.FIFO;

// QEMU's esp32 CCOUNT advances at the (emulated) CPU clock; these intervals are
// in raw cycles, picked so the two tasks fire at clearly different rates.
const tick_interval: u32 = 8_000_000;
const beat_interval: u32 = 24_000_000;

var ticks: u32 = 0;
var beats: u32 = 0;

// Tasks are `inline` so they fold into the scheduler loop — this backend doesn't
// emit a callable body for a plain (non-`export`) `fn`.
inline fn tick() void {
    ticks +%= 1;
    mmio.log(uart, .info, "[tick] {d}", .{ticks});
}

inline fn heartbeat() void {
    beats +%= 1;
    mmio.log(uart, .info, "[beat] {d} (after {d} ticks)", .{ beats, ticks });
}

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    mmio.puts(uart, "\r\nESP32 bare-metal Zig — cooperative scheduler\r\n");
    hal.runTasks(hal.cycleCount, .{
        .{ .run = tick, .interval = tick_interval },
        .{ .run = heartbeat, .interval = beat_interval },
    });
}

export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
