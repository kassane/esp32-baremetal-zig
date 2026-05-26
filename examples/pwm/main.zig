// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// LEDC PWM example (ESP32-S2). Configures a LEDC low-speed timer + channel and
// hardware-fades GPIO18's LED brightness up — the LEDC ramps the duty itself, with
// no CPU loop. Build-only: the Espressif QEMU does not model LEDC, so this writes
// the registers per the TRM layout but produces no emulator-observable waveform; on
// real hardware, route LEDC channel 0 to GPIO18 through the GPIO matrix (see the
// gpio_matrix example).

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s2.svd
const startup = @import("startup");

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
const fade_scale = 16; // duty increment per fade cycle
const fade_cycle = 4; // PWM periods between steps
const fade_steps = 256; // number of steps (0 → 4096 over 1024 PWM periods)

const Backlight = hal.Pwm(regs.LEDC.TIMER_0_CONF, regs.LEDC.CH_0_CONF0, regs.LEDC.CH_0_CONF1, regs.LEDC.CH_0_HPOINT, regs.LEDC.CH_0_DUTY);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Backlight.startTimer(duty_res_bits, 256); // 13-bit resolution, APB ÷ 256
    // Channel 0, bound to timer 0: hardware fade up from 0, the LEDC ramping on its own.
    Backlight.fade(0, 0, fade_scale, fade_cycle, fade_steps, true);
    mmio.log(regs.UART0.FIFO, .info, "LEDC: GPIO{d} hardware fade up ({d}/step, {d} steps)", .{ led_pin, fade_scale, fade_steps });
    while (true) {} // the LEDC channel drives the LED autonomously
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (the symbol the second-stage bootloader jumps to). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
