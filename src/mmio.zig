// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Bare-metal MMIO + timing helpers. All `inline`: the prebuilt xtensa backend
//! can't emit cross-module far calls, so these must fold into the caller.

const std = @import("std");

pub inline fn writeReg(addr: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

pub inline fn readReg(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Busy-wait `count` iterations. Wrapping `+%` so Debug emits no overflow check.
pub inline fn delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i +%= 1) {
        asm volatile ("nop");
    }
}

/// Blink forever: pulse `mask` on via `set_reg`, hold, off via `clr_reg`, hold.
/// `set_reg`/`clr_reg` are W1TS/W1TC register addresses (atomic set/clear).
pub inline fn blink(set_reg: u32, clr_reg: u32, mask: u32, half_period: u32) noreturn {
    while (true) {
        writeReg(set_reg, mask);
        delay(half_period);
        writeReg(clr_reg, mask);
        delay(half_period);
    }
}

/// Spin forever; the bare-metal panic landing pad.
pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("nop");
    }
}

// ── UART text output ──────────────────────────────────────────────────────────
// Write bytes to a UART's FIFO register (e.g. regs.UART0.FIFO). In QEMU the
// chardev drains instantly; real hardware would also need TX-FIFO flow control.

pub inline fn puts(fifo: u32, s: []const u8) void {
    for (s) |c| writeReg(fifo, c);
}

/// Print `v` in decimal. Division-free (repeated subtraction): a `/`/`%` here
/// would emit a divide check whose panic path is un-elided next to inline asm
/// (the xtensa backend treats `ee.*` as an optimization barrier) and won't link.
pub inline fn printU32(fifo: u32, v: u32) void {
    var rem = v;
    var started = false;
    inline for (.{ 1_000_000_000, 100_000_000, 10_000_000, 1_000_000, 100_000, 10_000, 1_000, 100, 10, 1 }) |pow| {
        var d: u8 = 0;
        while (rem >= pow) : (rem -%= pow) d +%= 1;
        if (started or d != 0 or pow == 1) {
            writeReg(fifo, '0' +% d);
            started = true;
        }
    }
}

/// Print a horizontal bar of `n` '#' characters (no newline).
pub inline fn bar(fifo: u32, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i +%= 1) writeReg(fifo, '#');
}

/// Print `v` as `0x` + 8 hex digits. The nibble is a `u4`, so indexing the
/// 16-byte digit table is provably in-range and emits no bounds-check panic.
pub inline fn printHex(fifo: u32, v: u32) void {
    const digits = "0123456789abcdef";
    puts(fifo, "0x");
    var shift: u5 = 28;
    while (true) {
        writeReg(fifo, digits[@as(u4, @truncate(v >> shift))]);
        if (shift == 0) break;
        shift -%= 4;
    }
}

/// Print `b` as exactly two lowercase hex digits (no `0x` prefix) — e.g. for
/// byte-wise dumps like a MAC address. The nibble→ASCII conversion is arithmetic
/// (not a table lookup), so it stays bounds-check-free even next to the volatile
/// MMIO writes, which act as optimization barriers that would otherwise un-elide
/// a table index's panic path (which can't link on this backend).
pub inline fn printHexByte(fifo: u32, b: u8) void {
    writeReg(fifo, hexNibble(@truncate(b >> 4)));
    writeReg(fifo, hexNibble(@truncate(b)));
}

inline fn hexNibble(n: u4) u8 {
    const v: u8 = n;
    return if (v < 10) '0' +% v else 'a' +% v -% 10;
}

// ── std.log + panic plumbing ────────────────────────────────────────────────
// A tiny comptime formatter so `std.log` (overridden via `std_options.logFn`)
// and the panic handler can render to UART without `std.fmt` — its formatting
// machinery references the panic path, which doesn't link on this backend.

inline fn argU32(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .comptime_int => @as(u32, v),
        .int => @truncate(v), // truncating cast is panic-free (no range check)
        else => @compileError("log args support only integers (use {s} for strings)"),
    };
}

/// Render `fmt` with `args` to UART. Supports `{s}` (string), `{d}`/`{}`
/// (decimal int), `{x}` (hex int), and `{{`/`}}` escapes — enough for logging,
/// parsed entirely at comptime so no `std.fmt` is pulled in.
pub inline fn format(fifo: u32, comptime fmt: []const u8, args: anytype) void {
    comptime var arg: usize = 0;
    comptime var i: usize = 0;
    inline while (i < fmt.len) {
        if (fmt[i] == '{' and fmt[i + 1] == '{') {
            writeReg(fifo, '{');
            i += 2;
        } else if (fmt[i] == '}' and fmt[i + 1] == '}') {
            writeReg(fifo, '}');
            i += 2;
        } else if (fmt[i] == '{') {
            comptime var j = i + 1;
            inline while (fmt[j] != '}') j += 1;
            const spec = fmt[i + 1 .. j];
            if (comptime std.mem.eql(u8, spec, "s")) {
                puts(fifo, args[arg]);
            } else if (comptime std.mem.eql(u8, spec, "x")) {
                printHex(fifo, argU32(args[arg]));
            } else if (comptime spec.len == 0 or std.mem.eql(u8, spec, "d")) {
                printU32(fifo, argU32(args[arg]));
            } else {
                @compileError("unsupported format specifier {" ++ spec ++ "}");
            }
            arg += 1;
            i = j + 1;
        } else {
            writeReg(fifo, fmt[i]);
            i += 1;
        }
    }
}

/// `std.options.logFn` backend: `[level] message` per line over UART. Wire it in
/// the root module with `pub const std_options: std.Options = .{ .logFn = … }`.
pub inline fn log(
    fifo: u32,
    comptime level: std.log.Level,
    comptime fmt: []const u8,
    args: anytype,
) void {
    puts(fifo, "[" ++ comptime level.asText() ++ "] ");
    format(fifo, fmt, args);
    puts(fifo, "\r\n");
}

/// Panic landing pad: print the message and a best-effort backtrace over UART,
/// then halt. Driven by the `panic` namespace in `src/panic.zig`.
pub inline fn panic(fifo: u32, msg: []const u8, first_addr: ?usize) noreturn {
    puts(fifo, "\r\n!! PANIC: ");
    puts(fifo, msg);
    puts(fifo, "\r\nbacktrace:\r\n");
    printFrame(fifo, first_addr orelse @returnAddress());
    walkWindowedStack(fifo);
    halt();
}

inline fn printFrame(fifo: u32, addr: usize) void {
    puts(fifo, "  ");
    printHex(fifo, @truncate(addr));
    writeReg(fifo, '\n');
}

// Xtensa windowed-ABI unwind constants.
const dram_base: u32 = 0x3F00_0000; // SP must point into DRAM (0x3F……–0x3FFF……)
const code_base: u32 = 0x4000_0000; // all code lives at 0x40……/0x42……
const save_bytes = 16; // caller's a0..a3 spilled just below SP
const pc_low_bits: u32 = 0x3FFF_FFFF; // a0 keeps PC[29:0]; top 2 bits are the call size
const max_frames = 16;

/// Best-effort Xtensa windowed-ABI unwind: each frame spills the caller's a0
/// (return address) and a1 (stack pointer) below SP; rebuild the PC's top bits
/// from `code_base`. Stops when SP leaves DRAM or fails to ascend — resolve the
/// printed PCs offline with addr2line. (Shallow here: everything is inlined.)
inline fn walkWindowedStack(fifo: u32) void {
    var sp = @frameAddress();
    var depth: usize = 0;
    while (depth < max_frames) : (depth +%= 1) {
        if (sp < dram_base or sp >= code_base) break;
        const save: [*]const u32 = @ptrFromInt(sp -% save_bytes);
        const ret_pc = save[0];
        const caller_sp = save[1];
        if (ret_pc == 0) break;
        printFrame(fifo, (ret_pc & pc_low_bits) | code_base);
        if (caller_sp <= sp) break; // the stack grows down: each caller is higher
        sp = caller_sp;
    }
}

// Freestanding C memory builtins. The compiler emits calls to these for struct
// copies and Debug's `undefined` fill; without libc/compiler-rt we provide them.
// `[*]` indexing + wrapping loops keep them free of any panic path.

export fn memset(dest: ?[*]u8, c: u8, n: usize) callconv(.c) ?[*]u8 {
    if (dest) |d| {
        var i: usize = 0;
        while (i < n) : (i +%= 1) d[i] = c;
    }
    return dest;
}

export fn memcpy(noalias dest: ?[*]u8, noalias src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    if (dest) |d| if (src) |s| {
        var i: usize = 0;
        while (i < n) : (i +%= 1) d[i] = s[i];
    };
    return dest;
}

export fn memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    if (dest) |d| if (src) |s| {
        if (@intFromPtr(d) < @intFromPtr(s)) {
            var i: usize = 0;
            while (i < n) : (i +%= 1) d[i] = s[i];
        } else {
            var i: usize = n;
            while (i > 0) {
                i -%= 1;
                d[i] = s[i];
            }
        }
    };
    return dest;
}
