// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — RSA modular exponentiation, QEMU-verified. Computes
// Z = base^exp mod M on the RSA accelerator against a known-answer vector:
// M = 2^512 − 1, base = 2, exp = 2, so Z must be 4. This modulus makes the two
// Montgomery constants exact and tiny — R = 2^512 ≡ 1 (mod M) gives r = R² mod M = 1,
// and M ≡ −1 (mod 2^32) gives m' = −M⁻¹ mod 2^32 = 1 — so the vector needs no
// big-integer software. The Espressif QEMU esp32 machine models RSA, so
// `zig build demo` prints OK.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

pub const std_options: std.Options = .{ .logFn = con.logFn };

const words = 16; // 512-bit operands
const Rsa = hal.Rsa(regs.RSA, words);

// Known-answer vector (see the header): M = 2^512 − 1, so m' = 1 and r = 1 exactly.
const modulus: [words]u32 = @splat(0xFFFF_FFFF);
const base = [_]u32{2} ++ @as([words - 1]u32, @splat(0));
const exponent = [_]u32{2} ++ @as([words - 1]u32, @splat(0));
const r = [_]u32{1} ++ @as([words - 1]u32, @splat(0));
const m_prime: u32 = 1;
const expected: u32 = 4; // 2^2 mod (2^512 − 1)

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    while (!Rsa.ready()) {} // wait for the accelerator to come out of reset
    const z = Rsa.modExp(base, exponent, modulus, m_prime, r);
    // Z must be exactly `expected` in the low word and zero above it.
    var ok = z[0] == expected;
    inline for (1..words) |i| {
        if (z[i] != 0) ok = false;
    }
    // `{d}` (printU32), not `{x}`: the hex digit-table lookup's bounds-check won't
    // link next to the volatile MMIO writes on this backend.
    mmio.log(regs.UART0.FIFO, .info, "RSA 2^2 mod (2^512-1) = {d}: {s}", .{ z[0], if (ok) "OK" else "MISMATCH" });
    while (true) mmio.delay(8_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
