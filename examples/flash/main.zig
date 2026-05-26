// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — SPI-flash read via the ROM (build-only). Reads the
// first 16 bytes of flash (the app image header) through esp_rom_spiflash_read
// (hal.FlashRom) and logs the result. **Build-only:** the ROM address is fixed per
// chip, and the QEMU `-kernel` flow has no flash image to read.

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

const Flash = hal.FlashRom(0x4006_2ED8); // ESP32 ROM esp_rom_spiflash_read

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    var hdr: [4]u32 = undefined; // first 16 bytes of flash (the image header)
    const ok = Flash.read(0, &hdr);
    mmio.log(regs.UART0.FIFO, .info, "flash read {s}, word0={d}", .{ if (ok) "OK" else "FAIL", hdr[0] });
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
