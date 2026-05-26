// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — SAR ADC1 software one-shot (build-only). Triggers a
// conversion on ADC1 channel 0 (GPIO36) and logs the raw value over UART.
// **Build-only:** QEMU has no observable analog input; a real reading also needs
// attenuation, the SAR clock and RTC power configured (see hal.Adc docs).

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Adc1 = hal.Adc(regs.SENS.SAR_MEAS_START1);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    while (true) {
        const raw = Adc1.read(0); // ADC1 channel 0 → GPIO36
        // `{d}` (printU32) avoids the hex table-lookup that won't link here.
        mmio.log(regs.UART0.FIFO, .info, "ADC1 ch0 raw {d}", .{raw});
        mmio.delay(4_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
