// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — peripheral clock gating (build-only). Pulses the
// reset line and ungates the bus clock of the I2C0 controller through DPORT
// (hal.ClockGate) before a driver would touch its registers — the explicit form
// of the clock bring-up the boot ROM performs for the peripherals the other
// examples assume are already running. Build-only: the gating has no
// UART-observable effect under QEMU.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// DPORT_I2C_EXT0_CLK_EN / _RST_EN — bit 7 of PERIP_CLK_EN / PERIP_RST_EN.
const i2c0_bit: u32 = @as(u32, 1) << 7;
const I2c0Clock = hal.ClockGate(regs.DPORT.PERIP_CLK_EN, regs.DPORT.PERIP_RST_EN, i2c0_bit);

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    I2c0Clock.reset(); // pulse the controller's reset line
    I2c0Clock.enable(); // ungate its bus clock — its registers now respond
    while (true) mmio.delay(4_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
