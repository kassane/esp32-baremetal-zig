// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — brownout detector (build-only). Arms the RTC brownout
// detector (hal.Brownout) to reset the chip if VDD sags below the trip threshold —
// the power-supply guard production firmware enables at boot — then idles, polling
// the detected flag. Build-only: QEMU has no analog supply model, so the
// detector never trips under emulation.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Power = hal.Brownout(regs.RTC_CNTL.BROWN_OUT);
const trip_level: u3 = 4; // mid-range threshold (0..7, higher = higher trip voltage)

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Power.arm(trip_level); // reset the chip if the supply browns out
    while (true) {
        if (Power.detected()) mmio.puts(regs.UART0.FIFO, "[warn] brownout detected\r\n");
        mmio.delay(4_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
