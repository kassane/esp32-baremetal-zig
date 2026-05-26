// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — Pulse Counter (build-only). Configures PCNT unit 0 to
// increment on each positive edge of its input (a rotary encoder, or
// frequency/event counting) and stashes the live count in an RTC scratch register.
// **Build-only:** the Espressif QEMU models no PCNT, and the input still needs
// routing to a pad through the GPIO matrix on real hardware.

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

// PCNT unit 0: CONF0 + the shared CTRL register + the unit's count register.
const Counter = hal.Pcnt(regs.PCNT.UNIT_0_CONF0_0, regs.PCNT.CTRL_0, regs.PCNT.U_CNT_0, 0);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    Counter.init();
    while (true) {
        const c = Counter.count();
        mmio.writeReg(regs.RTC_CNTL.STORE0, @bitCast(@as(i32, c))); // stash the live count
        mmio.delay(2_000_000);
    }
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
