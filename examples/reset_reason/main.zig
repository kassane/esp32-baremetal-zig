// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — reset-reason read. Logs the PRO-CPU reset cause code
// over UART at boot (1 = power-on, 12 = software, 7 = TG0 WDT, …). The read path
// runs in QEMU too; kept build-only here for consistency with the other examples.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const ResetInfo = hal.ResetReason(regs.RTC_CNTL.RESET_STATE);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.log(regs.UART0.FIFO, .info, "PRO-CPU reset cause {d}", .{ResetInfo.cause()});
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
