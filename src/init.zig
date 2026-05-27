// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Bare-metal startup helpers. `inline` for the same reason as `mmio`: the
//! prebuilt xtensa backend can't emit cross-module far calls.

const mmio = @import("mmio");
const reg = @import("reg");

/// C-runtime init: zero `.bss` and copy `.data` from its load address to its run
/// address. Call it as the first statement of `main` — on real hardware SRAM
/// powers up with garbage, so globals are undefined until this runs (the reset
/// vector only sets up the window ABI + stack). The linker scripts export the
/// segment bounds. The loops are word-wide and `volatile`, both so they stay
/// panic-free and so the compiler can't fold them into a `memset`/`memcpy` call
/// (a cross-module far call this backend can't emit). Idempotent in QEMU, where
/// segments load directly into already-zeroed RAM and `_sidata == _data_start`.
pub inline fn runtimeInit() void {
    // Runtime pointers from linker addresses would emit alignment/null checks
    // whose panic path doesn't link here; the bounds are `ALIGN(4)`, so skip them.
    @setRuntimeSafety(false);
    const bss_start = @intFromPtr(@extern([*]u8, .{ .name = "_bss_start" }));
    const bss_end = @intFromPtr(@extern([*]u8, .{ .name = "_bss_end" }));
    const data_start = @intFromPtr(@extern([*]u8, .{ .name = "_data_start" }));
    const data_end = @intFromPtr(@extern([*]u8, .{ .name = "_data_end" }));
    const sidata = @intFromPtr(@extern([*]u8, .{ .name = "_sidata" }));

    var d = bss_start;
    while (d < bss_end) : (d +%= 4) @as(*volatile u32, @ptrFromInt(d)).* = 0;

    var s = sidata;
    d = data_start;
    while (d < data_end) : (d +%= 4) {
        @as(*volatile u32, @ptrFromInt(d)).* = @as(*const volatile u32, @ptrFromInt(s)).*;
        s +%= 4;
    }
}

/// Disable the timer-group and RTC watchdogs. A second-stage bootloader leaves
/// the TIMG0 "flash boot" watchdog (and others) running, so an app that neither
/// feeds nor disables them is reset within seconds on real hardware.
///
/// `R` is the chip's generated `regs` module. The RTC watchdog is only touched
/// when that peripheral exposes the unlock register under this name (it differs
/// on some chips), so the same code is correct for every target.
pub inline fn disableWatchdogs(comptime R: type) void {
    const unlock = reg.wdt_wprotect_key; // *_WDTWPROTECT unlock key

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
