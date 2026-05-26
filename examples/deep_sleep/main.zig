// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — deep sleep with a timer wakeup (build-only). Logs the
// reset cause, then deep-sleeps for ~2 s via hal.DeepSleep (which reads the RTC
// timer to set the wakeup alarm). The chip resets on wake, so each boot logs its
// cause and sleeps again. **Build-only:** a live deep sleep powers the chip down,
// which the QEMU boot test would flag (a production sleep also configures the RTC
// power domains).

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

pub const std_options: std.Options = .{ .logFn = con.logFn };

const Sleep = hal.DeepSleep(regs.RTC_CNTL);
const ResetInfo = hal.ResetReason(regs.RTC_CNTL.RESET_STATE);
const rtc_hz = 150_000; // ESP32 RTC slow clock ≈ 150 kHz (default RC oscillator)
const wake_ticks = 2 * rtc_hz; // ~2 seconds

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.log(regs.UART0.FIFO, .info, "boot (reset cause {d}); deep-sleeping ~2 s", .{ResetInfo.cause()});
    Sleep.timerWakeup(wake_ticks); // does not return — powers down, resets on wake
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
