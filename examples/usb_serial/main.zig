// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 — USB Serial/JTAG console (build-only). Writes a
// banner over the built-in USB CDC-ACM port (the default console on S3 DevKits).
// Build-only: the Espressif QEMU provides no USB host; on hardware, open the
// board's USB serial port to see the output.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Usb = hal.UsbSerial(regs.USB_DEVICE.EP1, regs.USB_DEVICE.EP1_CONF);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    while (true) {
        Usb.write("ESP32-S3 USB Serial/JTAG console\r\n");
        mmio.delay(8_000_000);
    }
}

/// ESP32-S3 entry: enable windowed registers + set SP before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
