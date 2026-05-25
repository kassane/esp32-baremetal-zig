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
