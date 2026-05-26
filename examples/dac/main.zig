// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — DAC voltage ramp (build-only). Drives DAC1 (GPIO25)
// through a rising 8-bit sawtooth, the classic analog-output test. **Build-only:**
// QEMU has no observable analog output; on hardware, scope GPIO25.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const Dac1 = hal.Dac(regs.RTC_IO.PAD_DAC_0); // DAC1 → GPIO25

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    var level: u8 = 0;
    while (true) {
        Dac1.write(level);
        level +%= 1; // wraps 255 → 0, a sawtooth
        mmio.delay(20_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
