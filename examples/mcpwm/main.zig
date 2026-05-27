// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — MCPWM duty sweep (build-only). Configures an
// edge-aligned PWM (timer 0 → operator 0, generator A) and ramps the duty up and
// down, the classic motor/servo/LED-dimming pattern. Build-only: QEMU models
// no MCPWM; on hardware, route operator 0's output to a pad via the GPIO matrix.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

const Motor = hal.Mcpwm(regs.MCPWM0);
const period: u16 = 1000; // PWM resolution / top value

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs);
    Motor.init(0, 9, period); // ~edge-aligned PWM; duty set below
    var duty: u16 = 0;
    var rising = true;
    while (true) {
        Motor.setDuty(duty);
        if (rising) {
            duty +%= 50;
            if (duty >= period) rising = false;
        } else {
            duty -%= 50;
            if (duty <= 50) rising = true;
        }
        mmio.delay(200_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
