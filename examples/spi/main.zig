// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — SPI master write (build-only). Configures SPI2 as a
// MOSI-only master and periodically shifts out a few bytes (e.g. a display command
// stream). **Build-only:** the Espressif QEMU does not model an SPI controller, so
// this links and runs on real hardware (route SPI2's CS/CLK/MOSI to pads through
// the GPIO matrix first) but has no emulator output.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const Spi = hal.Spi(regs.SPI2);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Spi.init(4, 8); // f_apb / (5·9) ≈ a slow, scope-friendly SPI clock
    while (true) {
        Spi.write(&.{ 0x9f, 0x01, 0x02, 0x03 }); // e.g. a read-ID + payload frame
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
