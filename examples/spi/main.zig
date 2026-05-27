// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — SPI master write + read (build-only). Configures SPI2
// as a master, sends a JEDEC read-ID command, then clocks the 3-byte response back
// in over MISO (hal.Spi `write` + `read`). Build-only: the Espressif QEMU does
// not model an SPI controller, so this links and runs on real hardware (route SPI2's
// CS/CLK/MOSI/MISO to pads through the GPIO matrix first) but has no emulator output.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Spi = hal.Spi(regs.SPI2);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Spi.init(4, 8); // f_apb / (5·9) ≈ a slow, scope-friendly SPI clock
    var id: [3]u8 = undefined;
    while (true) {
        Spi.write(&.{0x9f}); // JEDEC read-ID command
        Spi.read(&id); // clock in the 3-byte manufacturer/device ID
        Spi.write(&id); // echo it back out (uses the response; build-only)
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
