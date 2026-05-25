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
