// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 — RSA modular exponentiation (build-only). Drives the
// RSA accelerator's modexp register sequence for a 512-bit operand (16 words).
// The Montgomery constants `m_prime = -M⁻¹ mod 2³²` and `r = 2^(2·512) mod M` are
// caller-supplied (as in ESP-IDF/esp-hal) — here they are placeholders, so this is
// **build-only**: it links and runs the sequence on hardware, but the result is
// only meaningful with real constants (a comptime big-int reference is future work).

const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");

fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret_addr);
}
pub const panic = @import("panic").Handler(onPanic);

const words = 16; // 512-bit operands
const Rsa = hal.Rsa(regs.RSA, words);

// Placeholder 512-bit operands (real use derives m_prime/r from the modulus).
const base = [_]u32{2} ++ [_]u32{0} ** (words - 1);
const exponent = [_]u32{0x10001} ++ [_]u32{0} ** (words - 1); // 65537
const modulus = [_]u32{0xFFFF_FFFD} ++ [_]u32{0} ** (words - 1);
const r = [_]u32{0} ** words;
const m_prime: u32 = 0;

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    while (!Rsa.ready()) {} // wait for the accelerator to come out of reset
    const z = Rsa.modExp(base, exponent, modulus, m_prime, r);
    // Report the low word so the call isn't optimised away (build-only). `{d}`
    // (printU32) avoids the hex table-lookup whose bounds-check won't link here.
    mmio.log(regs.UART0.FIFO, .info, "RSA modexp done, z[0]={d}", .{z[0]});
    while (true) mmio.delay(4_000_000);
}

/// ESP32 entry: enable windowed registers + set SP before the first C-ABI call.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
