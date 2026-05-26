// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — eFuse base-MAC reader. Reads the 48-bit factory MAC
// address the chip was programmed with at manufacturing (eFuse BLK0) and prints
// it over UART. This is the identity every connectivity interface derives from:
// Wi-Fi STA uses it directly, Wi-Fi SoftAP / Bluetooth / Ethernet use locally
// administered variants. eFuse is emulated by the Espressif QEMU fork, so this
// runs under QEMU (`zig build demo`) as well as on real hardware. Blinks GPIO2.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

pub const std_options: std.Options = .{ .logFn = con.logFn };

const led_mask: u32 = @as(u32, 1) << 2; // GPIO2 onboard LED
const blink_half: u32 = 480_000;

const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);
// ESP32 base MAC: low 32 bits in EFUSE BLK0_RDATA2, high 16 bits in BLK0_RDATA1.
const Mac = hal.Efuse(regs.EFUSE.BLK0_RDATA2, regs.EFUSE.BLK0_RDATA1);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Led.init();
    mmio.puts(regs.UART0.FIFO, "\r\nESP32 bare-metal Zig — eFuse base-MAC reader\r\n");

    const mac = Mac.baseMac();
    mmio.puts(regs.UART0.FIFO, "[info] base MAC ");
    // `inline for` unrolls with comptime indices so `mac[i]` is provably
    // in-range; a runtime index would emit a bounds-check panic path that the
    // volatile UART writes un-elide and this backend can't link.
    inline for (0..6) |i| {
        if (i != 0) mmio.writeReg(regs.UART0.FIFO, ':');
        mmio.printHexByte(regs.UART0.FIFO, mac[i]);
    }
    mmio.puts(regs.UART0.FIFO, "\r\n");
    // QEMU's eFuse block is unprogrammed, so the MAC reads back all-zero under
    // emulation; on real silicon this is the unique factory-programmed address.
    mmio.puts(regs.UART0.FIFO, "[info] (all-zero under QEMU; real silicon has a unique factory MAC)\r\n");

    mmio.blink(gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask, blink_half);
}

/// Entry point. QEMU `-kernel` enters with PS.WOE=0, so windowed registers must
/// be enabled and SP set (top of DRAM) before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
