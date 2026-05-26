// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — heap allocation, QEMU-verified. Bump-allocates a u32
// array from a typed arena (the `heap` module — a static SRAM buffer, since the std
// allocator interface doesn't lower on this backend), fills it with squares, sums
// them and logs the result — a known-answer check (Σ i² for i in 0..8 = 140). Shows
// dynamic allocation works on bare metal with no OS page allocator. Runs live under
// `zig build demo`.

const mmio = @import("mmio");
const heap = @import("heap");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const std = @import("std");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

pub const std_options: std.Options = .{ .logFn = logFn, .log_level = mmio.log_level };
fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    mmio.log(regs.UART0.FIFO, level, fmt, args);
}

const Pool = heap.Arena(u32, 1024);
const n = 8;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    const xs = Pool.alloc(n) orelse {
        mmio.puts(regs.UART0.FIFO, "[error] arena full\r\n");
        mmio.halt();
    };
    // `[*]` indexing + wrapping arithmetic keep the fill/sum bounds-/overflow-check
    // free (those panic paths don't link on this backend).
    const p = xs.ptr;
    var i: usize = 0;
    while (i < n) : (i +%= 1) p[i] = @truncate(i *% i); // 0,1,4,9,16,25,36,49
    var sum: u32 = 0;
    i = 0;
    while (i < n) : (i +%= 1) sum +%= p[i];
    mmio.log(regs.UART0.FIFO, .info, "heap: alloc {d} u32 ({d}/{d} used), sum of squares = {d}", .{ n, Pool.used(), Pool.items, sum });
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
