// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — linking a precompiled C object, QEMU-verified.
// build.zig compiles `blob.c` (a stand-in for a vendor `.a`) to an Xtensa object
// and links it into the firmware. Exercises FFI in both directions: the firmware
// calls into the blob via `extern fn` (C ABI), and the blob calls back into a
// firmware-supplied callback (`onBlobEvent`) — the same in/out shape a real
// vendor blob's OSI shim (e.g. the WiFi RF libraries) uses. Runs live under
// `zig build demo`.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs");
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;
pub const std_options = con.options;

const uart = regs.UART0.FIFO;

// Provided by the linked-in blob.c (precompiled object), C calling convention.
extern fn blob_transform(x: c_int) c_int;
extern fn blob_checksum(p: [*]const u8, n: c_uint) c_uint;
extern fn blob_run(x: c_int, cb: *const fn (c_int) callconv(.c) void) void;

var cb_value: u32 = 0;
fn onBlobEvent(v: c_int) callconv(.c) void { // the blob calls this (C ABI)
    cb_value = @intCast(v);
}

export fn main() callconv(.c) noreturn {
    init.runtimeInit();
    init.disableWatchdogs(regs);
    const t: u32 = @intCast(blob_transform(5)); // 5*3+7 = 22
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    const sum: u32 = blob_checksum(&data, data.len); // 1+2+3+4+5 = 15
    blob_run(10, &onBlobEvent); // blob calls onBlobEvent(20) — C → Zig callback
    mmio.format(uart, "\r\nblob_transform(5)={d}, blob_checksum={d}, callback={d}\r\n", .{ t, sum, cb_value });
    mmio.halt();
}

export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
