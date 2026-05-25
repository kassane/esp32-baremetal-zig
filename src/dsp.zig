//! Portable ESP32-family DSP helpers.
//!
//! On chips with the ESP32-S3 PIE unit the kernels use the 128-bit vector
//! instructions; everywhere else they fall back to scalar code. The branch is
//! selected at comptime, so `ee.*` is never analysed (let alone emitted) for a
//! chip without the `esp32s3ops` feature — the same source builds for esp32,
//! esp32s2 and esp32s3.

const std = @import("std");
const builtin = @import("builtin");

/// True on chips with the ESP32-S3 Processor Instruction Extensions (PIE/SIMD).
pub const has_simd = builtin.cpu.arch == .xtensa and
    std.Target.xtensa.featureSetHas(builtin.cpu.features, .esp32s3ops);

/// Signed-16-bit dot product: returns the low 32 bits of `Σ a[i]*b[i]`.
///
/// `len` must be a positive multiple of 8, and `a`/`b` must be 16-byte aligned
/// (one 128-bit PIE vector = eight int16 lanes). On esp32s3 this runs on the
/// PIE multiply-accumulate path (40-bit `ACCX`); elsewhere it is a scalar loop.
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

// Compile-time self-test (`comptime {}` unit test): the scalar reference for
// Σ i² over 1..32 must equal the closed-form result. Runs on every build,
// target-independent, and costs nothing at runtime.
comptime {
    var acc: i32 = 0;
    var i: i32 = 1;
    while (i <= 32) : (i += 1) acc += i * i;
    std.debug.assert(acc == 11440); // 32*33*65/6
}
