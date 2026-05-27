// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

// Bare-metal Zig for ESP32-S3 — HMAC-SHA256 accelerator (build-only). The HMAC key
// lives in an eFuse block and never leaves the chip, so this configures the
// accelerator (hal.Hmac) for "to user" mode against key block 0 and, on real
// silicon with that key programmed, feeds a message block and checks the MAC
// against `std.crypto`'s comptime HMAC-SHA256 reference. Build-only: QEMU's
// eFuse is blank, so `configure` reports a key-purpose error and the demo stops
// there; the comparison path runs only on hardware with a programmed key.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s3.svd
const startup = @import("startup");

const con = hal.Console(regs.UART0.FIFO);
pub const panic = con.panic;

pub const std_options = con.options;

const Hmac = hal.Hmac(regs.HMAC);
const key_block = 0; // eFuse key block programmed with the HMAC key

// `std.crypto` reference, folded at comptime (no runtime std.crypto): the MAC the
// hardware reproduces when eFuse key block 0 holds `key`. A blank block reads as
// all-zero, so that's the key assumed here.
const key: [32]u8 = @splat(0);
const message = "abc";
fn hmacRef() [8]u32 {
    @setEvalBranchQuota(100_000);
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, message, &key);
    var w: [8]u32 = undefined;
    for (&w, 0..) |*word, i| word.* = std.mem.readInt(u32, mac[i * 4 ..][0..4], .big);
    return w;
}

// One big-endian-packed message block (the message is short enough for a single
// block); the hardware finalises it via `set_message_one`.
fn messageBlock() [16]u32 {
    var block: [16]u32 = @splat(0);
    const b: [*]u32 = &block;
    const p: [*]const u8 = message; // many-item pointer → no bounds-check panic path
    var i: usize = 0;
    while (i < message.len) : (i +%= 1) {
        const sh: u5 = @truncate((@as(usize, 3) -% (i & 3)) *% 8); // big-endian byte position
        b[i >> 2] |= @as(u32, p[i]) << sh;
    }
    return block;
}

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs);
    mmio.puts(regs.UART0.FIFO, "\r\nESP32-S3 bare-metal Zig — HMAC-SHA256\r\n");
    if (!Hmac.configure(Hmac.to_user, key_block)) {
        mmio.puts(regs.UART0.FIFO, "[info] HMAC key block not configured (expected on a blank eFuse)\r\n");
        while (true) mmio.delay(8_000_000);
    }
    const hw = Hmac.hashBlock(comptime messageBlock());
    const ref = comptime hmacRef();
    var ok = true;
    inline for (0..8) |w| {
        if (hw[w] != ref[w]) ok = false;
    }
    mmio.log(regs.UART0.FIFO, .info, "HMAC-SHA256 HW vs std.crypto: {s}", .{if (ok) "OK" else "MISMATCH"});
    while (true) mmio.delay(8_000_000);
}

/// ESP32-S3 entry: enable windowed registers + set SP before the first C-ABI call.
export fn call_start_cpu0() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
