// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — GPIO matrix routing (build-only). Routes the I2C0
// SCL/SDA signals onto pads GPIO22/GPIO21 (the common ESP32 I2C pins) via
// hal.GpioMatrix — the "route the signals to pads via the GPIO matrix" step the bus
// drivers (i2c, spi, …) refer to. **Build-only:** the routing has no QEMU-observable
// effect.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// ESP32 GPIO-matrix signal indices (the SoC signal map): I2C0 SCL/SDA, in & out.
const i2c0_scl_sig: u9 = 29;
const i2c0_sda_sig: u9 = 30;
const scl_pad: u6 = 22;
const sda_pad: u6 = 21;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    // SCL on GPIO22: drive the I2C0 SCL output out the pad and feed the pad back in
    // (I2C is open-drain, so the controller senses the line it drives).
    hal.GpioMatrix.connectOutput(regs.GPIO.FUNC_OUT_SEL_CFG_22, i2c0_scl_sig);
    hal.GpioMatrix.connectInput(regs.GPIO.FUNC_IN_SEL_CFG_29, scl_pad);
    // SDA on GPIO21.
    hal.GpioMatrix.connectOutput(regs.GPIO.FUNC_OUT_SEL_CFG_21, i2c0_sda_sig);
    hal.GpioMatrix.connectInput(regs.GPIO.FUNC_IN_SEL_CFG_30, sda_pad);
    while (true) mmio.delay(4_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
