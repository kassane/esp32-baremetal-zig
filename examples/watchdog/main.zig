// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — TIMG0 watchdog (build-only). Arms a reset-on-timeout
// watchdog and feeds it in the main loop; if the loop ever stalls, the chip
// resets. Build-only: a live watchdog resets the chip, which the QEMU boot
// test would flag as a fault, so this is build-checked rather than run under QEMU.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Wdt = hal.Watchdog(regs.TIMG0);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // clear the boot watchdog first
    Wdt.start(40000, 2_000); // TIMG/40000 ticks; reset if not fed for ~the timeout
    while (true) {
        Wdt.feed(); // keep the system alive
        mmio.delay(200_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
