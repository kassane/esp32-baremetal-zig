// Minimal bare-metal Zig for ESP32-S3 (Xtensa LX7)
// Blinks GPIO48 (onboard RGB LED on ESP32-S3-DevKitC-1).
// No std lib, no OS, no IDF.

const std = @import("std");
const mmio = @import("mmio");
const dsp = @import("dsp");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const gpio = regs.GPIO;

/// Baremetal panic: halt forever (no std runtime to unwind into).
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    mmio.halt();
}

// GPIO48 (onboard RGB LED) is in the second bank (pins 32-53), bit 48-32 = 16,
// so it uses the OUT1/ENABLE1 registers. W1TS/W1TC = atomic write-1-to-set/clear.
const led_mask: u32 = @as(u32, 1) << (48 - 32);

// FFT spectral-analysis demo: a Q15 cosine at bin 5, generated at comptime.
const fft_n = 64;
const tone_bin = 5;
const tone: [fft_n]dsp.Cplx = blk: {
    @setEvalBranchQuota(10000);
    var s: [fft_n]dsp.Cplx = undefined;
    for (0..fft_n) |n| {
        const ang = 2.0 * std.math.pi * @as(f64, tone_bin) * @as(f64, @floatFromInt(n)) / @as(f64, fft_n);
        s[n] = .{ .re = @intFromFloat(@round(@cos(ang) * 8000.0)), .im = 0 };
    }
    break :blk s;
};

/// Index of the strongest bin in 1..N/2 of `spectrum` (|re|²+|im|²).
inline fn peakBin(spectrum: *const [fft_n]dsp.Cplx) usize {
    const s: [*]const dsp.Cplx = spectrum;
    var best: usize = 1;
    var best_mag: i32 = 0;
    var b: usize = 1;
    while (b < fft_n / 2) : (b +%= 1) {
        const re: i32 = s[b].re;
        const im: i32 = s[b].im;
        const mag = re *% re +% im *% im;
        if (mag > best_mag) {
            best_mag = mag;
            best = b;
        }
    }
    return best;
}

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    mmio.writeReg(gpio.ENABLE1_W1TS, led_mask); // GPIO48 as output

    // Run an FFT over the test tone and find its dominant frequency bin (= 5);
    // blink at a rate proportional to it, so the spectral result drives the LED.
    var spectrum: [fft_n]dsp.Cplx = undefined;
    const sp: [*]dsp.Cplx = &spectrum;
    const tp: [*]const dsp.Cplx = &tone;
    var n: usize = 0;
    while (n < fft_n) : (n +%= 1) sp[n] = tp[n]; // element-wise copy (no memcpy)
    dsp.fft(fft_n, &spectrum);
    const half_period: u32 = @as(u32, @truncate(peakBin(&spectrum))) *% 240_000;

    while (true) {
        mmio.writeReg(gpio.OUT1_W1TS, led_mask); // LED ON
        mmio.delay(half_period);
        mmio.writeReg(gpio.OUT1_W1TC, led_mask); // LED OFF
        mmio.delay(half_period);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). QEMU `-kernel` enters
/// with PS.WOE=0, so windowed registers must be enabled and SP set (top of
/// DRAM) before the first C-ABI call; the ROM already does this on hardware.
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
        \\ // ── Stack pointer: 0x3FCD3000 = 0x40000000 − 0x32D000 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x32D         // 813
        \\ slli    a0, a0, 12        // a0 = 0x32D000
        \\ sub     a1, a1, a0        // a1 = 0x3FCD3000
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
