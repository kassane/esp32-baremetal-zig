// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — I2C master write + read (build-only). Configures I2C0
// as a standard-mode master, writes a two-byte command to a device at address 0x3C
// (a common SSD1306 OLED) and reads a status byte back. Build-only: the
// Espressif QEMU does not model an I2C controller, so this links and runs on real
// hardware but has no emulator output; on a real board you must also route SCL/SDA
// to pads through the GPIO matrix first.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const dev_addr: u7 = 0x3c; // SSD1306 OLED (7-bit)
const I2c = hal.I2c(regs.I2C0);

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    I2c.init();
    var status: [1]u8 = undefined;
    while (true) {
        // SSD1306: control byte 0x00 (command stream) + 0xAE ("display off").
        I2c.write(dev_addr, &.{ 0x00, 0xAE });
        I2c.read(dev_addr, &status); // read one status byte back
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
