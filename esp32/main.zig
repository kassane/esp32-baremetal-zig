// Bare-metal Zig for ESP32 (Xtensa LX6). FFT spectral-analysis demo: FFTs a
// two-tone signal and prints the magnitude spectrum over UART0 (the LX6 has no
// PIE unit, so dsp.fft runs as portable scalar code). Blinks GPIO2.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
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

// GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (bank 0); W1TS/W1TC are atomic.
const led_pin: u5 = 2;
const led_mask: u32 = @as(u32, 1) << led_pin;
const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const blink_ms_per_bin: u32 = 50; // blink half-period = peak bin × this
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

const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init();

    var spectrum: [fft_n]dsp.Cplx = undefined;
    const sp: [*]dsp.Cplx = &spectrum;
    const tp: [*]const dsp.Cplx = &signal;
    var n: usize = 0;
    while (n < fft_n) : (n +%= 1) sp[n] = tp[n]; // element-wise copy (no memcpy)
    dsp.fft(fft_n, &spectrum);
    printSpectrum(regs.UART0.FIFO, &spectrum);

    const peak: u32 = @truncate(peakBin(&spectrum));
    const half_ms = peak *% blink_ms_per_bin;
    // Same routine `std_options.logFn` installs; `std.log.*` can't be called
    // directly (its non-inline helpers need far calls this backend can't emit).
    mmio.log(regs.UART0.FIFO, .info, "peak bin {d}, blink half-period {d} ms", .{ peak, half_ms });

    // Blink at a cycle-accurate rate set by the peak bin (esp-hal-style Delay).
    const delay = hal.Delay(cpu_hz);
    while (true) {
        Led.setHigh();
        delay.millis(half_ms);
        Led.setLow();
        delay.millis(half_ms);
    }
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
