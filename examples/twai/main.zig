// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — TWAI (CAN 2.0) frame transmit (build-only). Brings up
// the SJA1000-compatible controller and periodically sends a standard-ID data
// frame. **Build-only:** a real bus needs TX/RX routed to pads and an external CAN
// transceiver (e.g. SN65HVD230), so there is no emulator output. The bit-timing
// values below are placeholders — compute them for your bit rate and clock.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Can = hal.Twai(regs.TWAI0);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    // timing0 = BAUD_PRESC|SJW, timing1 = TSEG1|TSEG2|SAMP (placeholders).
    Can.init(0x09, 0x1c);
    while (true) {
        Can.send(0x123, &.{ 0xde, 0xad, 0xbe, 0xef });
        mmio.delay(4_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
