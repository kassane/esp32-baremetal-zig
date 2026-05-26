// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 — on-chip temperature sensor (build-only). Powers
// the sensor and logs its raw reading over UART0. **Build-only:** QEMU has no
// thermal model; the raw value maps to °C via a per-chip calibration curve.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const Temp = hal.TempSensor(regs.SENS.SAR_TSENS_CTRL);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    while (true) {
        const raw = Temp.read(6); // clock ÷ 6
        mmio.log(regs.UART0.FIFO, .info, "tsens raw {d}", .{raw});
        mmio.delay(8_000_000);
    }
}

/// ESP32-S3 entry: enable windowed registers + set SP before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
