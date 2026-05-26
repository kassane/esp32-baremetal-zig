// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — I2S master TX (build-only). Brings up I2S0 as a
// 16-bit master (Philips framing) and shifts out a constant sample in single-data
// mode (no DMA). **Build-only:** QEMU models no I2S; on hardware route BCK/WS/DATA
// to pads via the GPIO matrix. A DMA-fed streaming path is a larger future piece.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const Audio = hal.I2s(regs.I2S0);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Audio.init(10, 8, 16); // I2S_CLK = src/10, BCK = I2S_CLK/8, 16-bit samples
    Audio.writeConstant(0x7fff_8000); // a fixed left/right level
    while (true) mmio.delay(4_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
