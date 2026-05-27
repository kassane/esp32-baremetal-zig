// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — software CRC-32, QEMU-verified. esp-rs exposes CRC
// through the mask ROM (esp-rom-sys), but the ROM isn't present in QEMU's
// `-kernel` boot, so this uses `std.hash.Crc32` instead — pure, table-based,
// links cleanly on this backend, and needs no peripheral. Checks the standard
// "123456789" → 0xcbf43926 vector, then CRCs a message. Runs under `zig build demo`.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs");
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;
pub const std_options = con.options;
const uart = regs.UART0.FIFO;

export fn main() callconv(.c) noreturn {
    init.runtimeInit();
    init.disableWatchdogs(regs);
    const check = std.hash.Crc32.hash("123456789"); // standard CRC-32 check value
    mmio.format(uart, "\r\nCRC32(\"123456789\") = {x} ({s})\r\n", .{ check, if (check == 0xcbf43926) "OK" else "FAIL" });
    const msg = "esp32-baremetal-zig";
    mmio.format(uart, "CRC32(\"{s}\") = {x}\r\n", .{ msg, std.hash.Crc32.hash(msg) });
    mmio.halt();
}

export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
