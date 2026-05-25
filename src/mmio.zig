//! Bare-metal MMIO + timing helpers. All `inline`: the prebuilt xtensa backend
//! can't emit cross-module far calls, so these must fold into the caller.

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
