//! Portable int16 DSP kernels built on Zig's native `@Vector` SIMD — no inline
//! asm, no register clobbers, no per-chip gating: the same source builds and
//! runs on esp32 / esp32s2 / esp32s3 (and the host).
//!
//! Research note: the prebuilt LLVM-xtensa backend *scalarizes* `@Vector` — it
//! does not auto-vectorize to the ESP32-S3 PIE (`ee.*`) instructions. So this is
//! portable and idiomatic but not hardware-vectorized; using the PIE unit still
//! requires inline asm. Kernels are `inline` (the backend can't emit
//! cross-module far calls).

const std = @import("std");

/// Q15 (1.15 fixed-point): one lane is in [-1, 1) scaled by 2^15.
pub const q15_bits: u5 = 15;
pub const q15_one: f64 = 32767.0; // 0x7FFF ≈ +1.0, used by comptime table gen

/// int16 lanes per 128-bit SIMD vector.
pub const lanes = 8;
const Vec = @Vector(lanes, i16);
const Wide = @Vector(lanes, i32);

/// `out[i] = saturate(a[i] + b[i])` over `len` lanes (a multiple of `lanes`).
pub inline fn addSatS16(out: [*]i16, a: [*]const i16, b: [*]const i16, len: usize) void {
    var i: usize = 0;
    while (i +% lanes <= len) : (i +%= lanes) {
        const r: [lanes]i16 = @as(Vec, a[i..][0..lanes].*) +| @as(Vec, b[i..][0..lanes].*);
        out[i..][0..lanes].* = r;
    }
}

/// `Σ a[i]·b[i]` over `len` lanes — FIR tap, correlation, or signal energy.
pub inline fn dotProductS16(a: [*]const i16, b: [*]const i16, len: usize) i32 {
    var acc: i32 = 0;
    var i: usize = 0;
    while (i +% lanes <= len) : (i +%= lanes) {
        const va: Wide = @as(Vec, a[i..][0..lanes].*);
        const vb: Wide = @as(Vec, b[i..][0..lanes].*);
        acc +%= @reduce(.Add, va *% vb);
    }
    return acc;
}

/// FIR filter: `out[i] = (Σ_k coeffs[k]·in[i+k]) >> q15_bits` in Q15. `in` must
/// hold at least `out.len + coeffs.len - 1` samples. `.ptr` indexing avoids
/// bounds-check panics (which don't link on the xtensa backend).
pub inline fn firS16(out: []i16, in: []const i16, coeffs: []const i16) void {
    for (out, 0..) |*y, i| {
        var acc: i32 = 0;
        for (coeffs, 0..) |c, k| acc +%= @as(i32, c) *% @as(i32, in.ptr[i +% k]);
        y.* = @truncate(acc >> q15_bits);
    }
}

/// Complex sample in Q15 (1.15 fixed point).
pub const Cplx = struct { re: i16, im: i16 };

/// Twiddle factors W_N^k = e^(-j2πk/N) for k in 0..N/2, as Q15, built at comptime.
fn twiddles(comptime N: usize) [N / 2]Cplx {
    @setEvalBranchQuota(100 * N);
    var w: [N / 2]Cplx = undefined;
    for (0..N / 2) |k| {
        const ang = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        w[k] = .{ .re = @intFromFloat(@round(@cos(ang) * q15_one)), .im = @intFromFloat(@round(@sin(ang) * q15_one)) };
    }
    return w;
}

/// In-place radix-2 DIT FFT of `N` (power-of-two) Q15 complex samples. Scales by
/// 1/2 per stage (1/N total) to avoid overflow. Portable scalar integer math —
/// no FPU, no compiler-rt; the twiddle table is generated at comptime.
pub inline fn fft(comptime N: usize, data: *[N]Cplx) void {
    const stage_scale_bits = 1; // halve each stage so the whole FFT scales by 1/N
    const tw = comptime twiddles(N);
    // Index via many-item pointers + wrapping arithmetic so Debug emits no
    // bounds-check / overflow / divide-by-zero panic path (none links here).
    const d: [*]Cplx = data;
    const w: [*]const Cplx = &tw;

    // bit-reversal permutation
    var i: usize = 1;
    var j: usize = 0;
    while (i < N) : (i +%= 1) {
        var bit: usize = N >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            const t = d[i];
            d[i] = d[j];
            d[j] = t;
        }
    }

    // log2(N) butterfly stages; `step` (= N/len) is halved instead of divided.
    var len: usize = 2;
    var step: usize = N >> 1;
    while (len <= N) : ({
        len <<= 1;
        step >>= 1;
    }) {
        const half = len >> 1;
        var base: usize = 0;
        while (base < N) : (base +%= len) {
            var k: usize = 0;
            while (k < half) : (k +%= 1) {
                const wj = w[k *% step];
                const a = d[base +% k];
                const b = d[base +% k +% half];
                // t = wj * b (Q15 complex multiply); wrapping i32, then >> q15_bits
                const tr: i32 = (@as(i32, wj.re) *% @as(i32, b.re) -% @as(i32, wj.im) *% @as(i32, b.im)) >> q15_bits;
                const ti: i32 = (@as(i32, wj.re) *% @as(i32, b.im) +% @as(i32, wj.im) *% @as(i32, b.re)) >> q15_bits;
                d[base +% k] = .{ .re = @truncate((@as(i32, a.re) +% tr) >> stage_scale_bits), .im = @truncate((@as(i32, a.im) +% ti) >> stage_scale_bits) };
                d[base +% k +% half] = .{ .re = @truncate((@as(i32, a.re) -% tr) >> stage_scale_bits), .im = @truncate((@as(i32, a.im) -% ti) >> stage_scale_bits) };
            }
        }
    }
}
