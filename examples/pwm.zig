// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// LEDC PWM example (ESP32-S2). Configures a LEDC low-speed timer + channel and
// holds GPIO18's LED at 50 % brightness. Build-only: the Espressif QEMU does not
// model LEDC, so this writes the registers per the TRM layout but produces no
// emulator-observable waveform; on real hardware, route LEDC channel 0 to GPIO18
// through the GPIO matrix (a chip-specific output-signal index).

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s2.svd

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    mmio.log(regs.UART0.FIFO, level, fmt, args);
}

const led_pin: u5 = 18; // RGB LED data pin on common S2 DevKits
const duty_res_bits = 13; // 8192 PWM steps
const half_duty = (1 << duty_res_bits) / 2; // 50 %

const Backlight = hal.Pwm(regs.LEDC.TIMER_0_CONF, regs.LEDC.CH_0_CONF0, regs.LEDC.CH_0_CONF1, regs.LEDC.CH_0_HPOINT, regs.LEDC.CH_0_DUTY);

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Backlight.startTimer(duty_res_bits, 256); // 13-bit resolution, APB ÷ 256
    Backlight.setDuty(0, half_duty); // channel 0, bound to timer 0
    mmio.log(regs.UART0.FIFO, .info, "LEDC: GPIO{d} PWM at {d}/{d} (50%)", .{ led_pin, half_duty, @as(u32, 1) << duty_res_bits });
    while (true) {} // the LEDC channel drives the LED autonomously
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (
        \\ .align 4
        \\ movi    a0, 1
        \\ slli    a0, a0, 18        // PS.WOE = bit 18
        \\ wsr.ps  a0
        \\ rsync
        \\ movi    a0, 0
        \\ wsr.windowbase a0
        \\ rsync
        \\ movi    a0, 1
        \\ wsr.windowstart a0
        \\ rsync
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x220
        \\ slli    a0, a0, 8         // a0 = 0x22000
        \\ sub     a1, a1, a0        // SP = 0x3FFDE000 (top of DRAM)
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
