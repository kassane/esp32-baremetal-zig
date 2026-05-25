//! Shared bare-metal MMIO + timing helpers for the ESP32 family.
//! No std runtime, no OS — just raw volatile register access.
//!
//! All helpers are `inline`: they compile straight into the caller, so there
//! are no cross-module call symbols (which the prebuilt xtensa backend fails to
//! emit for far calls) and register accessors carry zero call overhead.

/// 32-bit volatile write to a memory-mapped register.
pub inline fn writeReg(addr: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// 32-bit volatile read from a memory-mapped register.
pub inline fn readReg(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Set the bits of `mask` in the register at `addr` (read-modify-write).
pub inline fn setBits(addr: u32, mask: u32) void {
    writeReg(addr, readReg(addr) | mask);
}

/// Clear the bits of `mask` in the register at `addr` (read-modify-write).
pub inline fn clearBits(addr: u32, mask: u32) void {
    writeReg(addr, readReg(addr) & ~mask);
}

/// Naive busy-wait delay (not calibrated to wall-clock time).
/// Uses wrapping `+%` so Debug builds emit no overflow-check / panic path.
pub inline fn delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i +%= 1) {
        asm volatile ("nop");
    }
}

/// Park the CPU forever. Used as the bare-metal panic landing pad.
pub inline fn halt() noreturn {
    while (true) {
        asm volatile ("nop");
    }
}
