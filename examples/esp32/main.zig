// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32 (Xtensa LX6) — hardware-crypto demo. Runs SHA-256 on
// the SHA accelerator and checks the digest, word for word, against the value
// std.crypto computes at comptime; also samples the hardware RNG and reports the
// GPIO0 level. Blinks GPIO2. (The cycle-accurate Delay lives in the esp32s2/s3
// examples — it's an optimization barrier that would un-elide the inlined SHA
// safety checks, so this demo uses the plain busy-loop blink.)

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32.svd
const startup = @import("startup");
const gpio = regs.GPIO;

// UART0 console: the panic namespace (message + backtrace, no std.fmt) and the
// std.log backend, both routed to UART0 (see hal.Console / src/panic.zig).
const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;
pub const std_options = con.options;

// GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (bank 0); W1TS/W1TC are atomic.
const led_pin: u5 = 2;
const led_mask: u32 = @as(u32, 1) << led_pin;
const blink_half: u32 = 480_000; // busy-loop iterations per blink half-period

const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0 (boot button), bank 0
const Console = hal.Uart(regs.UART0.FIFO, regs.UART0.STATUS); // UART TX + RX
const Entropy = hal.Rng(regs.RNG.DATA); // hardware RNG
const Hasher = hal.Sha(8, regs.SHA.TEXT_0, regs.SHA.SHA256_START, regs.SHA.SHA256_LOAD, regs.SHA.SHA256_BUSY);
const Hasher1 = hal.Sha(5, regs.SHA.TEXT_0, regs.SHA.SHA1_START, regs.SHA.SHA1_LOAD, regs.SHA.SHA1_BUSY);
const Cipher128 = hal.Aes(128, regs.AES.KEY_0, regs.AES.TEXT_0, regs.AES.MODE, regs.AES.START, regs.AES.IDLE);
const Cipher256 = hal.Aes(256, regs.AES.KEY_0, regs.AES.TEXT_0, regs.AES.MODE, regs.AES.START, regs.AES.IDLE);

/// Digest of `m` as big-endian words via `std.crypto` at comptime — the reference
/// the hardware accelerator is checked against. `Hash` is the matching std type
/// (`Sha1`/`Sha256`), so one helper covers every digest length. The software path
/// can't link here, but comptime evaluation emits no runtime code.
fn shaRef(comptime Hash: type, comptime m: []const u8) [Hash.digest_length / 4]u32 {
    @setEvalBranchQuota(100_000);
    var h: [Hash.digest_length]u8 = undefined;
    Hash.hash(m, &h, .{});
    var w: [Hash.digest_length / 4]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = std.mem.readInt(u32, h[i * 4 ..][0..4], .big);
    return w;
}

/// AES-ECB(key, pt) ciphertext as 4 little-endian words, via `std.crypto` at
/// comptime — the reference for the hardware AES accelerator. `Cipher` is the
/// matching `std.crypto.core.aes` type (`Aes128`/`Aes256`), so one helper covers
/// every key length.
fn aesRef(comptime Cipher: type, comptime key: [Cipher.key_bits / 8]u8, comptime pt: [16]u8) [4]u32 {
    @setEvalBranchQuota(100_000);
    var ct: [16]u8 = undefined;
    Cipher.initEnc(key).encrypt(&ct, &pt);
    var w: [4]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = std.mem.readInt(u32, ct[i * 4 ..][0..4], .little);
    return w;
}

export fn main() callconv(.c) noreturn {
    init.runtimeInit(); // zero .bss + copy .data (real-HW C runtime)
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init();
    Console.write("\r\nESP32 bare-metal Zig — hardware crypto demo\r\n");

    // Hardware SHA-1 and SHA-256 of "abc", each checked word-for-word against
    // std.crypto's comptime reference digest.
    const sha1_hw = Hasher1.hash("abc");
    const sha1_ref = comptime shaRef(std.crypto.hash.Sha1, "abc");
    var sha1_ok = true;
    inline for (0..5) |w| {
        if (sha1_hw[w] != sha1_ref[w]) sha1_ok = false;
    }
    // Same routine `std_options.logFn` installs; `std.log.*` can't be called
    // directly (its non-inline helpers need far calls this backend can't emit).
    mmio.log(regs.UART0.FIFO, .info, "SHA-1(\"abc\") HW vs std.crypto: {s}", .{if (sha1_ok) "OK" else "MISMATCH"});

    const hw = Hasher.hash("abc");
    const ref = comptime shaRef(std.crypto.hash.sha2.Sha256, "abc");
    var sha_ok = true;
    inline for (0..8) |w| {
        if (hw[w] != ref[w]) sha_ok = false;
    }
    mmio.log(regs.UART0.FIFO, .info, "SHA-256(\"abc\") HW vs std.crypto: {s}", .{if (sha_ok) "OK" else "MISMATCH"});

    // Hardware AES-128 and AES-256 ECB of an all-zero key+block, each checked
    // against std.crypto's comptime reference (one driver, comptime key length).
    const ct128 = Cipher128.encryptBlock(.{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    const ref128 = comptime aesRef(std.crypto.core.aes.Aes128, @splat(0), @splat(0));
    var aes128_ok = true;
    inline for (0..4) |w| {
        if (ct128[w] != ref128[w]) aes128_ok = false;
    }
    mmio.log(regs.UART0.FIFO, .info, "AES-128-ECB HW vs std.crypto: {s}", .{if (aes128_ok) "OK" else "MISMATCH"});

    const ct256 = Cipher256.encryptBlock(.{ 0, 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    const ref256 = comptime aesRef(std.crypto.core.aes.Aes256, @splat(0), @splat(0));
    var aes256_ok = true;
    inline for (0..4) |w| {
        if (ct256[w] != ref256[w]) aes256_ok = false;
    }
    mmio.log(regs.UART0.FIFO, .info, "AES-256-ECB HW vs std.crypto: {s}", .{if (aes256_ok) "OK" else "MISMATCH"});
    mmio.log(regs.UART0.FIFO, .info, "rng sample {d}, GPIO0 {s}", .{ Entropy.read(), if (Button.isHigh()) "high" else "low" });

    mmio.blink(gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask, blink_half);
}

// ── Reset vector ────────────────────────────────────────────────────────────

/// Entry point. QEMU `-kernel` enters with PS.WOE=0, so windowed registers must
/// be enabled and SP set (top of DRAM) before the first C-ABI call. The ROM
/// already does this on hardware, where redoing it is harmless.
export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
