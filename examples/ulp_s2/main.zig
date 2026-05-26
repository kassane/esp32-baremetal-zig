// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for the ESP32-S2 ULP — a RISC-V low-power coprocessor program
// (build-only). The ULP runs independently of the Xtensa main core, from RTC slow
// memory, so this is a *separate* riscv32imc firmware: the main core would load it
// into RTC RAM and start it (that loader is out of scope for this Xtensa HAL). It
// reuses the same `hal`/`mmio`/`startup` modules as the Xtensa examples — the
// register drivers are arch-agnostic — driving an RTC GPIO through the ULP's
// register view (generated from svd/esp32s2-ulp.svd) and handing the main core a
// heartbeat counter via the shared RTC-memory word at 0x400. Build-only: QEMU
// does not run the ULP.

const mmio = @import("mmio");
const hal = @import("hal");
const regs = @import("regs"); // generated from svd/esp32s2-ulp.svd
const startup = @import("startup");

// The ULP has no UART console, so a fault just halts.
fn onPanic(_: []const u8, _: ?usize) noreturn {
    mmio.halt();
}
pub const panic = @import("panic").Handler(onPanic);

const led_mask: u32 = @as(u32, 1) << 0; // an RTC GPIO (board-specific pad)
const shared_word: u32 = 0x400; // HP↔ULP shared RTC slow-memory word
const Led = hal.Output(regs.RTC_IO.ENABLE_W1TS, regs.RTC_IO.OUT, regs.RTC_IO.OUT_W1TS, regs.RTC_IO.OUT_W1TC, led_mask);

export fn main() callconv(.c) noreturn {
    Led.init();
    var i: u32 = 0;
    while (true) {
        i +%= 1;
        mmio.writeReg(shared_word, i); // heartbeat the main core can poll
        Led.toggle();
        mmio.delay(50_000);
    }
}

/// ULP reset vector: must link at offset 0x0 (`.text.vectors`). `startup.ulpVector`
/// sets the stack pointer to the top of the ULP's RTC RAM, then enters `main`.
export fn reset_vector() linksection(".text.vectors") callconv(.naked) noreturn {
    asm volatile (startup.ulpVector());
}
