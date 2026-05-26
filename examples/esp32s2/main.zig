// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S2 (Xtensa LX7, single core) — DSP demo. FFTs a
// two-tone signal and prints the magnitude spectrum over UART0 (dsp.fft is
// portable scalar code; the S2 has no PIE unit), reports a TIMG uptime, and
// blinks GPIO18 at a cycle-accurate rate set by the peak bin. Build-only: the
// Espressif QEMU fork has no esp32s2 machine.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s2.svd
const startup = @import("startup");
const gpio = regs.GPIO;

// Custom panic namespace: UART message + backtrace, no std.fmt (see src/panic.zig).
const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

// Route `std.log` through UART0 instead of std.fmt's (unlinkable) default.
pub const std_options: std.Options = .{ .logFn = con.logFn };

// GPIO18 (RGB LED data pin on common S2 DevKits) is in bank 0.
const led_pin: u5 = 18;
const led_mask: u32 = @as(u32, 1) << led_pin;
const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const blink_ms_per_bin: u32 = 50; // blink half-period = peak bin × this
const bar_shift: u5 = 6; // bin magnitude → bar width
const bar_max = 60;

const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);
const Uptime = hal.Timer(regs.TIMG0.T_0_CONFIG, regs.TIMG0.T_0_UPDATE, regs.TIMG0.T_0_LO);

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

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init(); // GPIO18 as output
    Uptime.start(2); // TIMG0 timer 0 as a monotonic tick source

    var spectrum: [fft_n]dsp.Cplx = undefined;
    const sp: [*]dsp.Cplx = &spectrum;
    const tp: [*]const dsp.Cplx = &signal;
    var n: usize = 0;
    while (n < fft_n) : (n +%= 1) sp[n] = tp[n]; // element-wise copy (no memcpy)
    dsp.fft(fft_n, &spectrum);
    printSpectrum(regs.UART0.FIFO, &spectrum);

    const peak: u32 = @truncate(peakBin(&spectrum));
    const half_ms = peak *% blink_ms_per_bin;
    mmio.log(regs.UART0.FIFO, .info, "peak bin {d}, half-period {d} ms, uptime {d} ticks", .{ peak, half_ms, Uptime.ticks() });

    // Blink at a cycle-accurate rate set by the peak bin.
    const delay = hal.Delay(cpu_hz);
    while (true) {
        Led.setHigh();
        delay.millis(half_ms);
        Led.setLow();
        delay.millis(half_ms);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (the symbol the second-stage bootloader jumps to). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call;
/// the ROM already does this on hardware, where redoing it is harmless.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
