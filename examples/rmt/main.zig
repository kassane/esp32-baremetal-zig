// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — RMT IR transmit (build-only). Streams an NEC-style
// remote frame (9 ms leader, then a few data bits) out RMT channel 0 in a loop.
// IR is the one wireless protocol a from-scratch register HAL can drive — the
// Wi-Fi/Bluetooth radios need Espressif's closed RF blobs. Build-only: no
// Espressif QEMU machine models RMT, so this links and runs on real hardware (route
// channel 0 to an IR-LED pad via the GPIO matrix, ideally with a 38 kHz carrier).

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// RMT channel 0: CONF0 / CONF1 / DATA window + the shared APB_CONF.
const Ir = hal.Rmt(regs.RMT.CHCONF0_0, regs.RMT.CHCONF1_0, regs.RMT.CHDATA_0, regs.RMT.APB_CONF);

// Divider 80: an 80 MHz source clock → 1 MHz, i.e. one tick per microsecond, so
// the NEC durations below are written directly in µs.
const clk_div: u8 = 80;

// An NEC frame fragment: 9 ms leader mark + 4.5 ms space, a '1' bit
// (560 µs mark, 1690 µs space) and a '0' bit (560 µs mark, 560 µs space).
const frame = [_]u32{
    Ir.symbol(1, 9000, 0, 4500),
    Ir.symbol(1, 560, 0, 1690),
    Ir.symbol(1, 560, 0, 560),
    Ir.symbol(1, 560, 0, 0),
};

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Ir.init(clk_div);
    while (true) {
        Ir.send(&frame);
        mmio.delay(4_000_000); // ~idle between frames
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
