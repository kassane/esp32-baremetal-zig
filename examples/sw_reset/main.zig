// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — reset reason + software reset (build-only). On a
// power-on boot it logs the cause and triggers one software reset; on the
// resulting software-reset boot it logs and idles (so it doesn't loop). Shows
// hal.ResetReason and hal.softwareReset together. **Build-only:** a live reset
// restarts the chip, which the QEMU boot test would flag.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const ResetInfo = hal.ResetReason(regs.RTC_CNTL.RESET_STATE);
const power_on_cause = 1; // RTC_SW_CPU_RESET differs; 1 = power-on

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    const cause = ResetInfo.cause();
    mmio.log(regs.UART0.FIFO, .info, "boot, reset cause {d}", .{cause});
    if (cause == power_on_cause) {
        mmio.puts(regs.UART0.FIFO, "[info] power-on; triggering a software reset\r\n");
        hal.softwareReset(regs.RTC_CNTL.OPTIONS0); // does not return
    }
    while (true) mmio.delay(8_000_000); // software-reset boot: idle
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
