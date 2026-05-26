//! Small HAL layer over `mmio` — a Zig take on the esp-hal driver shape
//! (`Level`/`Output`, a cycle-accurate `Delay`). All `inline`, panic-free
//! (wrapping arithmetic, comptime division), so it links on this backend.

const mmio = @import("mmio");

/// Read the Xtensa core cycle counter (`CCOUNT`). Advances at the CPU clock.
pub inline fn cycleCount() u32 {
    return asm volatile ("rsr.ccount %[ret]"
        : [ret] "=r" (-> u32),
    );
}

/// Busy-wait `clocks` CPU cycles. Wrapping subtract handles the 32-bit rollover.
pub inline fn delayCycles(clocks: u32) void {
    const start = cycleCount();
    while (cycleCount() -% start < clocks) {}
}

/// Cycle-accurate blocking delay for a comptime CPU clock (Hz), e.g.
/// `const delay = hal.Delay(240_000_000);  delay.millis(500);`.
pub fn Delay(comptime hz: u32) type {
    return struct {
        const per_us: u32 = hz / 1_000_000; // folded at comptime — no runtime divide

        pub inline fn cycles(clocks: u32) void {
            delayCycles(clocks);
        }
        pub inline fn micros(us: u32) void {
            delayCycles(per_us *% us);
        }
        pub inline fn millis(ms: u32) void {
            delayCycles(per_us *% 1000 *% ms);
        }
    };
}

/// Logic level of a pin.
pub const Level = enum {
    low,
    high,
    pub inline fn not(self: Level) Level {
        // `if`, not `switch`: a switch on the enum emits a corrupt-value safety
        // check whose panic path doesn't link here.
        return if (self == .low) .high else .low;
    }
};

/// A read-only input pin: reports the level latched in the GPIO bank's IN
/// register. Comptime register/mask for the same panic-free reason as `Output`.
pub fn Input(comptime in_reg: u32, comptime mask: u32) type {
    return struct {
        pub inline fn isHigh() bool {
            return mmio.readReg(in_reg) & mask != 0;
        }
        pub inline fn isLow() bool {
            return !isHigh();
        }
        pub inline fn level() Level {
            return if (isHigh()) .high else .low;
        }
    };
}

/// A push-pull output pin driven through atomic W1TS/W1TC registers, so a
/// set/clear is a single store (no read-modify-write). The register addresses
/// are comptime so the stores keep their fixed, aligned addresses and emit no
/// alignment/null safety-check panic (which wouldn't link). `init` configures
/// the pin as an output; pass the GPIO bank's ENABLE/OUT set+clear registers.
pub fn Output(comptime enable_reg: u32, comptime set_reg: u32, comptime clr_reg: u32, comptime mask: u32) type {
    return struct {
        pub inline fn init() void {
            mmio.writeReg(enable_reg, mask);
        }
        pub inline fn setHigh() void {
            mmio.writeReg(set_reg, mask);
        }
        pub inline fn setLow() void {
            mmio.writeReg(clr_reg, mask);
        }
        pub inline fn setLevel(level: Level) void {
            mmio.writeReg(if (level == .high) set_reg else clr_reg, mask);
        }
    };
}
