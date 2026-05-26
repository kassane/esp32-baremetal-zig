// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — WS2812 / NeoPixel addressable RGB (build-only).
// Cycles a "smart LED" through red → green → blue → white on RMT channel 0,
// encoding each colour's 24 bits as RMT symbols (hal.Ws2812, built on hal.Rmt).
// Build-only: no Espressif QEMU machine models RMT; on a board, route channel
// 0 to the LED's data pad via the GPIO matrix (e.g. the ESP32-S3 DevKit's onboard
// RGB is GPIO48). The single-wire WS2812 line code is the kind of pure-register
// "radio-adjacent" protocol a from-scratch HAL can drive without vendor blobs.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// RMT channel 0: CONF0 / CONF1 / DATA window + the shared APB_CONF (as in rmt/).
const Led = hal.Ws2812(regs.RMT.CHCONF0_0, regs.RMT.CHCONF1_0, regs.RMT.CHDATA_0, regs.RMT.APB_CONF);

const dim: u8 = 0x20; // keep it gentle on the eyes (~12 % duty)
const palette = [_]Led.Color{
    .{ .r = dim, .g = 0, .b = 0 }, // red
    .{ .r = 0, .g = dim, .b = 0 }, // green
    .{ .r = 0, .g = 0, .b = dim }, // blue
    .{ .r = dim, .g = dim, .b = dim }, // white
};

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Led.init();
    // `inline for` over the comptime palette: fully unrolled, so no runtime index
    // and no bounds-check panic path (which wouldn't link on this backend).
    while (true) {
        inline for (palette) |color| {
            Led.write(color);
            mmio.delay(4_000_000);
        }
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
