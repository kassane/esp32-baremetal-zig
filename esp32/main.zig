// Bare-metal Zig for ESP32 (Xtensa LX6). FFT spectral-analysis demo: FFTs a
// two-tone signal and prints the magnitude spectrum over UART0 (the LX6 has no
// PIE unit, so dsp.fft runs as portable scalar code). Blinks GPIO2.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const gpio = regs.GPIO;

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (bank 0); W1TS/W1TC are atomic.
const led_pin: u5 = 2;
const led_mask: u32 = @as(u32, 1) << led_pin;
const blink_per_bin: u32 = 240_000;
const bar_shift: u5 = 6; // bin magnitude → bar width
const bar_max = 60;

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
    mmio.puts(fifo, "\r\nESP32 FFT magnitude spectrum (tones @ bins 4 and 12):\r\n");
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
    mmio.writeReg(gpio.ENABLE_W1TS, led_mask); // GPIO2 as output

    var spectrum: [fft_n]dsp.Cplx = undefined;
    const sp: [*]dsp.Cplx = &spectrum;
    const tp: [*]const dsp.Cplx = &signal;
    var n: usize = 0;
    while (n < fft_n) : (n +%= 1) sp[n] = tp[n]; // element-wise copy (no memcpy)
    dsp.fft(fft_n, &spectrum);
    printSpectrum(regs.UART0.FIFO, &spectrum);
    const half_period: u32 = @as(u32, @truncate(peakBin(&spectrum))) *% blink_per_bin;

    mmio.blink(gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask, half_period);
}

// ── Reset vector ────────────────────────────────────────────────────────────

/// Entry point. QEMU `-kernel` enters with PS.WOE=0, so windowed registers must
/// be enabled and SP set (top of DRAM) before the first C-ABI call. The ROM
/// already does this on hardware, where redoing it is harmless.
export fn Reset() callconv(.naked) noreturn {
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
        \\ movi    a0, 0x23E
        \\ slli    a0, a0, 8         // a0 = 0x23E00
        \\ sub     a1, a1, a0        // SP = 0x3FFDC200 (top of DRAM)
        \\ call8   main
        \\0:
        \\ j       0b
    );
}
