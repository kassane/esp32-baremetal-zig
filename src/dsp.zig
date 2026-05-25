//! Portable int16 DSP kernels: ESP32-S3 PIE (SIMD) when available, scalar
//! otherwise. The branch is comptime-selected, so `ee.*` is never analysed on
//! chips lacking `esp32s3ops`. Kernels are `inline` (the prebuilt xtensa backend
//! can't emit cross-module far calls).
//!
//! All take `len` a positive multiple of 8 and 16-byte-aligned buffers (one
//! 128-bit PIE vector = eight int16 lanes).

const std = @import("std");
const builtin = @import("builtin");

/// True on chips with the ESP32-S3 Processor Instruction Extensions (PIE/SIMD).
pub const has_simd = builtin.cpu.arch == .xtensa and
    std.Target.xtensa.featureSetHas(builtin.cpu.features, .esp32s3ops);

/// `out[i] = saturate(a[i] + b[i])` — e.g. mixing two signals with clipping.
pub inline fn addSatS16(out: [*]align(16) i16, a: [*]align(16) const i16, b: [*]align(16) const i16, len: u32) void {
    const chunks = len / 8;
    if (comptime has_simd) {
        var po = out;
        var pa = a;
        var pb = b;
        var n = chunks;
        asm volatile (
            \\1:
            \\ ee.vld.128.ip q0, %[a], 16
            \\ ee.vld.128.ip q1, %[b], 16
            \\ ee.vadds.s16  q2, q0, q1
            \\ ee.vst.128.ip q2, %[o], 16
            \\ addi          %[n], %[n], -1
            \\ bnez          %[n], 1b
            : [a] "+r" (pa),
              [b] "+r" (pb),
              [o] "+r" (po),
              [n] "+r" (n),
            :
            : .{ .q0 = true, .q1 = true, .q2 = true, .memory = true });
    } else {
        var i: usize = 0;
        const total: usize = @as(usize, chunks) *% 8;
        while (i < total) : (i +%= 1) {
            const s = @as(i32, a[i]) +% @as(i32, b[i]);
            const c: i32 = if (s > 32767) 32767 else if (s < -32768) -32768 else s;
            out[i] = @truncate(c); // c is clamped into i16 range
        }
    }
}

/// `Σ a[i]*b[i]` (low 32 bits) — FIR tap, correlation, or signal energy.
/// On esp32s3 this uses the PIE 40-bit multiply-accumulate (`ACCX`).
pub inline fn dotProductS16(a: [*]align(16) const i16, b: [*]align(16) const i16, len: u32) u32 {
    const chunks = len / 8;
    if (comptime has_simd) {
        var lo: u32 = undefined;
        var pa = a;
        var pb = b;
        var n = chunks;
        asm volatile (
            \\ ee.zero.accx
            \\1:
            \\ ee.vld.128.ip      q0, %[a], 16
            \\ ee.vld.128.ip      q1, %[b], 16
            \\ ee.vmulas.s16.accx q0, q1
            \\ addi               %[n], %[n], -1
            \\ bnez               %[n], 1b
            \\ rur.accx_0         %[lo]
            : [lo] "=r" (lo),
              [a] "+r" (pa),
              [b] "+r" (pb),
              [n] "+r" (n),
            :
            : .{ .q0 = true, .q1 = true });
        return lo;
    } else {
        var acc: u32 = 0;
        const total: usize = @as(usize, chunks) *% 8;
        var i: usize = 0;
        while (i < total) : (i +%= 1) {
            const prod: i32 = @as(i32, a[i]) *% @as(i32, b[i]);
            acc +%= @bitCast(prod);
        }
        return acc;
    }
}

/// FIR filter: `out[i] = (Σ_k coeffs[k]·in[i+k]) >> 15` in Q15. `in` must hold at
/// least `out.len + coeffs.len - 1` samples. Scalar/portable. Uses `.ptr`
/// indexing (no bounds checks → no panic path on the xtensa backend).
pub inline fn firS16(out: []i16, in: []const i16, coeffs: []const i16) void {
    for (out, 0..) |*y, i| {
        var acc: i32 = 0;
        for (coeffs, 0..) |c, k| acc +%= @as(i32, c) *% @as(i32, in.ptr[i +% k]);
        y.* = @truncate(acc >> 15);
    }
}

/// Complex sample in Q15 (1.15 fixed point).
pub const Cplx = extern struct { re: i16, im: i16 };

/// Twiddle factors W_N^k = e^(-j2πk/N) for k in 0..N/2, as Q15, built at comptime.
fn twiddles(comptime N: usize) [N / 2]Cplx {
    @setEvalBranchQuota(100 * N);
    var w: [N / 2]Cplx = undefined;
    for (0..N / 2) |k| {
        const ang = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        w[k] = .{ .re = @intFromFloat(@round(@cos(ang) * 32767.0)), .im = @intFromFloat(@round(@sin(ang) * 32767.0)) };
    }
    return w;
}

/// In-place radix-2 DIT FFT of `N` (power-of-two) Q15 complex samples. Scales by
/// 1/2 per stage (1/N total) to avoid overflow. Portable scalar integer math —
/// no FPU, no compiler-rt; the twiddle table is generated at comptime.
pub inline fn fft(comptime N: usize, data: *[N]Cplx) void {
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
                // t = wj * b (Q15 complex multiply); wrapping i32, then >> 15
                const tr: i32 = (@as(i32, wj.re) *% @as(i32, b.re) -% @as(i32, wj.im) *% @as(i32, b.im)) >> 15;
                const ti: i32 = (@as(i32, wj.re) *% @as(i32, b.im) +% @as(i32, wj.im) *% @as(i32, b.re)) >> 15;
                d[base +% k] = .{ .re = @truncate((@as(i32, a.re) +% tr) >> 1), .im = @truncate((@as(i32, a.im) +% ti) >> 1) };
                d[base +% k +% half] = .{ .re = @truncate((@as(i32, a.re) -% tr) >> 1), .im = @truncate((@as(i32, a.im) -% ti) >> 1) };
            }
        }
    }
}
