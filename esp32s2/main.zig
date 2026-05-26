// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S2 (Xtensa LX7, single core) — DSP + PWM demo. FFTs a
// two-tone signal and prints the magnitude spectrum over UART0 (dsp.fft is
// portable scalar code; the S2 has no PIE unit), reports a TIMG uptime, and sets
// GPIO18's LED brightness via LEDC PWM from the peak bin. Build-only: the
// Espressif QEMU fork has no esp32s2 machine (and does not model LEDC).

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s2.svd
const gpio = regs.GPIO;

// Custom panic namespace: UART message + backtrace, no std.fmt (see src/panic.zig).
fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

// Route `std.log` through UART0 instead of std.fmt's (unlinkable) default.
pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    mmio.log(regs.UART0.FIFO, level, fmt, args);
}

// GPIO18 (RGB LED data pin on common S2 DevKits) — driven by LEDC PWM here.
const led_pin: u5 = 18;
const duty_res_bits = 13; // 8192 PWM steps
const bar_shift: u5 = 6; // bin magnitude → bar width
const bar_max = 60;

const Uptime = hal.Timer(regs.TIMG0.T_0_CONFIG, regs.TIMG0.T_0_UPDATE, regs.TIMG0.T_0_LO);
const Backlight = hal.Pwm(regs.LEDC.TIMER_0_CONF, regs.LEDC.CH_0_CONF0, regs.LEDC.CH_0_CONF1, regs.LEDC.CH_0_HPOINT, regs.LEDC.CH_0_DUTY);

// Two-tone test signal (bins 4 and 12), generated at comptime.
const fft_n = 64;
const tone_a = 4;
const tone_b = 12;
const signal: [fft_n]dsp.Cplx = blk: {
    @setEvalBranchQuota(20000);
    var s: [fft_n]dsp.Cplx = undefined;
    for (0..fft_n) |n| {
        const t = 2.0 * std.math.pi * @as(f64, @floatFromInt(n)) / @as(f64, fft_n);
        const v = @cos(@as(f64, tone_a) * t) * 6000.0 + @cos(@as(f64, tone_b) * t) * 3000.0;
        s[n] = .{ .re = @intFromFloat(@round(v)), .im = 0 };
    }
    break :blk s;
};

/// Index of the strongest bin in 1..N/2 (|re|²+|im|²).
inline fn peakBin(spectrum: *const [fft_n]dsp.Cplx) usize {
    const s: [*]const dsp.Cplx = spectrum;
    var best: usize = 1;
    var best_mag: i32 = 0;
    var b: usize = 1;
    while (b < fft_n / 2) : (b +%= 1) {
        const mag = @as(i32, s[b].re) *% @as(i32, s[b].re) +% @as(i32, s[b].im) *% @as(i32, s[b].im);
        if (mag > best_mag) {
            best_mag = mag;
            best = b;
        }
    }
    return best;
}

/// Print bins 0..N/2 of `spectrum` as a horizontal ASCII magnitude plot.
inline fn printSpectrum(fifo: u32, spectrum: *const [fft_n]dsp.Cplx) void {
    const s: [*]const dsp.Cplx = spectrum;
    mmio.puts(fifo, "\r\nESP32-S2 FFT magnitude spectrum (tones @ bins 4 and 12):\r\n");
    var b: usize = 0;
    while (b <= fft_n / 2) : (b +%= 1) {
        const mag: u32 = @abs(@as(i32, s[b].re)) +% @abs(@as(i32, s[b].im));
        var w: u32 = mag >> bar_shift;
        if (w > bar_max) w = bar_max;
        mmio.puts(fifo, "bin ");
        if (b < 10) mmio.puts(fifo, " ");
        mmio.printU32(fifo, @truncate(b));
        mmio.puts(fifo, " |");
        mmio.bar(fifo, w);
        mmio.puts(fifo, "\r\n");
    }
}

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Uptime.start(2); // TIMG0 timer 0 as a monotonic tick source

    var spectrum: [fft_n]dsp.Cplx = undefined;
    const sp: [*]dsp.Cplx = &spectrum;
    const tp: [*]const dsp.Cplx = &signal;
    var n: usize = 0;
    while (n < fft_n) : (n +%= 1) sp[n] = tp[n]; // element-wise copy (no memcpy)
    dsp.fft(fft_n, &spectrum);
    printSpectrum(regs.UART0.FIFO, &spectrum);

    // Set the LED's PWM brightness from the peak bin (scaled into the 13-bit
    // duty range). On real hardware, route LEDC channel 0 to GPIO18 via the GPIO
    // matrix; QEMU doesn't model LEDC, so this just configures the registers.
    const peak: u32 = @truncate(peakBin(&spectrum));
    const duty = peak *% 256; // peak (1..31) → 256..7936, within 2^13
    Backlight.startTimer(duty_res_bits, 256); // 13-bit resolution, APB ÷ 256
    Backlight.setDuty(0, duty); // channel 0, bound to timer 0
    mmio.log(regs.UART0.FIFO, .info, "peak bin {d}, uptime {d} ticks, GPIO{d} PWM duty {d}/8192", .{ peak, Uptime.ticks(), led_pin, duty });

    while (true) {} // LEDC drives the LED autonomously
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call;
/// the ROM already does this on hardware, where redoing it is harmless.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (
        \\ .align 4
        \\ // ── PS.WOE = bit 18 (enables windowed 'entry' instructions) ──────
        \\ movi    a0, 1
        \\ slli    a0, a0, 18        // a0 = 0x00040000
        \\ wsr.ps  a0
        \\ rsync
        \\ // ── Windowed register file: WINDOWBASE=0, WINDOWSTART=1 ──────────
        \\ movi    a0, 0
        \\ wsr.windowbase a0
        \\ rsync
        \\ movi    a0, 1
        \\ wsr.windowstart a0
        \\ rsync
        \\ // ── Stack pointer: 0x3FFDE000 = 0x40000000 − 0x22000 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x220         // 544
        \\ slli    a0, a0, 8         // a0 = 0x0022000
        \\ sub     a1, a1, a0        // a1 = 0x3FFDE000
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
