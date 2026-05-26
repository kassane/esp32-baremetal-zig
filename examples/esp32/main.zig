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
const blink_half: u32 = 480_000; // busy-loop iterations per blink half-period

const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0 (boot button), bank 0
const Console = hal.Uart(regs.UART0.FIFO); // UART transmitter
const Entropy = hal.Rng(regs.RNG.DATA); // hardware RNG
const Hasher = hal.Sha256(regs.SHA.TEXT_0, regs.SHA.SHA256_START, regs.SHA.SHA256_LOAD, regs.SHA.SHA256_BUSY);
const Cipher = hal.Aes128(regs.AES.KEY_0, regs.AES.TEXT_0, regs.AES.MODE, regs.AES.START, regs.AES.IDLE);

/// SHA-256 of `m` (8 big-endian words) computed by `std.crypto` at comptime —
/// the reference the hardware accelerator is checked against. The software path
/// can't link here, but comptime evaluation emits no runtime code.
fn sha256ref(comptime m: []const u8) [8]u32 {
    @setEvalBranchQuota(100_000);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(m, &h, .{});
    var w: [8]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = std.mem.readInt(u32, h[i * 4 ..][0..4], .big);
    return w;
}

/// AES-128-ECB(key, pt) ciphertext as 4 little-endian words, via `std.crypto` at
/// comptime — the reference for the hardware AES accelerator.
fn aes128ref(comptime key: [16]u8, comptime pt: [16]u8) [4]u32 {
    @setEvalBranchQuota(100_000);
    var ct: [16]u8 = undefined;
    std.crypto.core.aes.Aes128.initEnc(key).encrypt(&ct, &pt);
    var w: [4]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = std.mem.readInt(u32, ct[i * 4 ..][0..4], .little);
    return w;
}

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    Led.init();
    Console.write("\r\nESP32 bare-metal Zig — hardware crypto demo\r\n");

    // Hardware SHA-256("abc"), checked word-for-word against std.crypto's
    // comptime reference digest.
    const hw = Hasher.hash("abc");
    const ref = comptime sha256ref("abc");
    var sha_ok = true;
    inline for (0..8) |w| {
        if (hw[w] != ref[w]) sha_ok = false;
    }
    // Same routine `std_options.logFn` installs; `std.log.*` can't be called
    // directly (its non-inline helpers need far calls this backend can't emit).
    mmio.log(regs.UART0.FIFO, .info, "SHA-256(\"abc\") HW vs std.crypto: {s}", .{if (sha_ok) "OK" else "MISMATCH"});

    // Hardware AES-128-ECB of an all-zero key+block, checked against std.crypto.
    const ct = Cipher.encryptBlock(.{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 });
    const ct_ref = comptime aes128ref([_]u8{0} ** 16, [_]u8{0} ** 16);
    var aes_ok = true;
    inline for (0..4) |w| {
        if (ct[w] != ct_ref[w]) aes_ok = false;
    }
    mmio.log(regs.UART0.FIFO, .info, "AES-128-ECB HW vs std.crypto: {s}", .{if (aes_ok) "OK" else "MISMATCH"});
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
