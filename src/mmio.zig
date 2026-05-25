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

/// Spin forever; the bare-metal panic landing pad.
pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("nop");
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
