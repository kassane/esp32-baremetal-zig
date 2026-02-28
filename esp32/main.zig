// Minimal bare-metal Zig for ESP32 (Xtensa LX6)
// Blinks GPIO2 (onboard LED on ESP32 DevKitC-V4).
// Entry via Reset vector; no std runtime, no OS.

const std = @import("std");

/// Baremetal panic: just halt. Replaces the default panic that calls abort().
pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    abort();
}

/// Required by compiler_rt safety checks (overflow-detected builtins in Debug mode).
export fn abort() callconv(.c) noreturn {
    while (true) {
        asm volatile ("nop");
    }
}

// ── Peripheral register addresses (ESP32) ────────────────────────────────────

const GPIO_BASE: u32 = 0x3FF4_4000;
/// GPIO output register – controls GPIO 0-31
const GPIO_OUT_REG: u32 = GPIO_BASE + 0x0004;
/// GPIO output enable register – GPIO 0-31
const GPIO_ENABLE_REG: u32 = GPIO_BASE + 0x0020;

// ── Register helpers ──────────────────────────────────────────────────────────

fn write_reg32(addr: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

fn read_reg32(addr: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Naive busy-wait delay (not calibrated to wall-clock time).
fn simple_delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("nop");
    }
}

// ── Application logic ─────────────────────────────────────────────────────────

fn blink() noreturn {
    // GPIO2 = onboard blue LED on ESP32 DevKitC-V4 (active-high)
    const led_pin: u5 = 2;
    const led_mask: u32 = @as(u32, 1) << led_pin;

    // Enable GPIO2 as output
    write_reg32(GPIO_ENABLE_REG, read_reg32(GPIO_ENABLE_REG) | led_mask);

    while (true) {
        // LED ON
        write_reg32(GPIO_OUT_REG, read_reg32(GPIO_OUT_REG) | led_mask);
        simple_delay(1_200_000);

        // LED OFF
        write_reg32(GPIO_OUT_REG, read_reg32(GPIO_OUT_REG) & ~led_mask);
        simple_delay(1_200_000);
    }
}

// ── Entry points ──────────────────────────────────────────────────────────────

/// Reset vector – first code executed on both real hardware and QEMU.
///
/// Hardware: ROM bootloader has already set PS.WOE=1 and configured the
/// register file before jumping here.  Re-initialising is idempotent.
///
/// QEMU (-kernel): jumps here with PS.WOE=0, making every subsequent
/// windowed 'entry' instruction illegal.  We must explicitly set WOE and
/// initialise the register window before any Zig C-ABI function runs.
///
/// PS.WOE = bit 18 = 0x40000.  Too large for 'movi' (12-bit signed ±2047),
/// so we build it with 'movi a0, 1 / slli a0, a0, 18'.
/// Stack pointer: top of DRAM = 0x3FFDC200 (= 0x40000000 − 0x23E00).
export fn Reset() callconv(.naked) noreturn {
    asm volatile (
        \\ .align 4
        \\ // ── PS.WOE = bit 18 (enables windowed 'entry' instructions) ──────
        \\ movi    a0, 1
        \\ slli    a0, a0, 18        // a0 = 0x00040000
        \\ wsr.ps  a0
        \\ rsync
        \\ // ── Windowed register file: WINDOWBASE=0, WINDOWSTART=1 ──────────
        \\ movi    a0, 0
        \\ wsr.windowbase a0
        \\ rsync
        \\ movi    a0, 1
        \\ wsr.windowstart a0
        \\ rsync
        \\ // ── Stack pointer: 0x3FFDC200 = 0x40000000 − 0x23E00 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x23E         // 574
        \\ slli    a0, a0, 8         // a0 = 0x0023E00
        \\ sub     a1, a1, a0        // a1 = 0x3FFDC200
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   main
        \\0:
        \\ j       0b
    );
}

export fn main() callconv(.c) noreturn {
    blink();
}
