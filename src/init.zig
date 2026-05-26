// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Bare-metal startup helpers. `inline` for the same reason as `mmio`: the
//! prebuilt xtensa backend can't emit cross-module far calls.

const mmio = @import("mmio");

/// Disable the timer-group and RTC watchdogs. A second-stage bootloader leaves
/// the TIMG0 "flash boot" watchdog (and others) running, so an app that neither
/// feeds nor disables them is reset within seconds on real hardware.
///
/// `R` is the chip's generated `regs` module. The RTC watchdog is only touched
/// when that peripheral exposes the unlock register under this name (it differs
/// on some chips), so the same code is correct for every target.
pub inline fn disableWatchdogs(comptime R: type) void {
    const unlock: u32 = 0x50D8_3AA1; // magic key for the *_WDTWPROTECT registers

    inline for (.{ R.TIMG0, R.TIMG1 }) |tg| {
        mmio.writeReg(tg.WDTWPROTECT, unlock); // unlock
        mmio.writeReg(tg.WDTCONFIG0, 0); // clear enable + all stage actions
        mmio.writeReg(tg.WDTWPROTECT, 0); // re-lock
    }

    if (@hasDecl(R.RTC_CNTL, "WDTWPROTECT")) {
        mmio.writeReg(R.RTC_CNTL.WDTWPROTECT, unlock);
        mmio.writeReg(R.RTC_CNTL.WDTCONFIG0, 0);
        mmio.writeReg(R.RTC_CNTL.WDTWPROTECT, 0);
    }
}
