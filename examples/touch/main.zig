// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — capacitive touch sensor (build-only). Software-forces
// a measurement of touch pad T0 (GPIO4) via hal.Touch and stashes the raw count in
// an RTC scratch register; a lower count means the pad is being touched.
// Build-only: QEMU has no touch model, and a real reading also needs the RTC
// touch FSM timing tuned for the board.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// Touch pad T0 = GPIO4 → RTC_IO.TOUCH_PAD0, touch number 0, result in SAR_TOUCH_OUT_0.
const Pad = hal.Touch(regs.SENS, regs.RTC_IO.TOUCH_PAD0, 0, regs.SENS.SAR_TOUCH_OUT_0);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Pad.init();
    while (true) {
        const count = Pad.read();
        mmio.writeReg(regs.RTC_CNTL.STORE0, count); // stash the latest reading
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
