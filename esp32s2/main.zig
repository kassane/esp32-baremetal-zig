// Minimal bare-metal Zig for ESP32-S2 (Xtensa LX7, single core).
// GPIO input→output example: mirrors the GPIO0 boot button onto the GPIO18 LED
// (RGB LED data pin on common ESP32-S2 DevKits, e.g. Saola-1). No std/OS/IDF.

const std = @import("std");
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs"); // generated from svd/esp32s2.svd
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

// GPIO18 (RGB LED data pin on common S2 DevKits) is in bank 0. W1TS/W1TC =
// atomic write-1-to-set / write-1-to-clear, so no read-modify-write is needed.
const led_pin: u5 = 18;
const led_mask: u32 = @as(u32, 1) << led_pin;
const cpu_hz = 240_000_000; // Xtensa default; sets the cycle-accurate Delay scale
const poll_ms: u32 = 20; // how often to sample the button
const Led = hal.Output(gpio.ENABLE_W1TS, gpio.OUT_W1TS, gpio.OUT_W1TC, led_mask);
const Button = hal.Input(gpio.IN, @as(u32, 1) << 0); // GPIO0 (boot button), bank 0

// ── Application entry ─────────────────────────────────────────────────────────

export fn app_main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real HW
    mmio.log(regs.UART0.FIFO, .info, "ESP32-S2 up; mirroring GPIO0 -> GPIO{d}", .{led_pin});
    Led.init(); // GPIO18 as output

    // Drive the LED from the button each poll (GPIO input → output). The bool
    // `isHigh` form keeps the in-loop read panic-free under the cycle-delay
    // barrier; routing the Level enum through the loop re-adds checks that don't
    // link here.
    const delay = hal.Delay(cpu_hz);
    while (true) {
        if (Button.isHigh()) Led.setHigh() else Led.setLow();
        delay.millis(poll_ms);
    }
}

// ── Startup ───────────────────────────────────────────────────────────────────

/// Entry point (symbol expected by the IDF boot flow). Enables windowed
/// registers and sets SP (top of internal DRAM) before the first C-ABI call;
/// the ROM already does this on hardware, where redoing it is harmless.
export fn call_start_cpu0() callconv(.naked) noreturn {
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
        \\ // ── Stack pointer: 0x3FFDE000 = 0x40000000 − 0x22000 ─────────────
        \\ movi    a1, 1
        \\ slli    a1, a1, 30        // a1 = 0x40000000
        \\ movi    a0, 0x220         // 544
        \\ slli    a0, a0, 8         // a0 = 0x0022000
        \\ sub     a1, a1, a0        // a1 = 0x3FFDE000
        \\ // ── Windowed call: CALLINC=2 matches 'entry a1,N' in callee ──────
        \\ call8   app_main
        \\0:
        \\ j       0b
    );
}
