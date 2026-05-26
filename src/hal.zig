//! Small HAL layer over `mmio` — a Zig take on the esp-hal driver shapes
//! (`Level`/`Output`/`Input`, a cycle-accurate `Delay`, a TIMG `Timer`). All
//! `inline`, panic-free (wrapping arithmetic, comptime division), so it links on
//! this backend; drivers are comptime-parameterized on their register addresses
//! so the MMIO accesses stay provably aligned and non-null (no panic path).

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

/// A Timer Group general-purpose timer (TIMGn Tx) as a free-running up-counter —
/// the time source esp-hal's `time` driver reads, independent of the CPU
/// `CCOUNT`. Comptime register addresses (config/update/lo): `start` enables the
/// counter with a 16-bit prescaler, `ticks` latches the live value and returns
/// its low 32 bits (it counts at the timer-group clock ÷ `divider`).
pub fn Timer(comptime config_reg: u32, comptime update_reg: u32, comptime lo_reg: u32) type {
    return struct {
        // TIMGn_Tx_CONFIG bit fields (chip Technical Reference Manual).
        const enable: u32 = 1 << 31;
        const count_up: u32 = 1 << 30;
        const divider_shift = 13; // 16-bit prescaler at bits 28:13

        pub inline fn start(comptime divider: u16) void {
            mmio.writeReg(config_reg, enable | count_up | (@as(u32, divider) << divider_shift));
        }
        pub inline fn ticks() u32 {
            mmio.writeReg(update_reg, 1); // latch the live count into the LO/HI shadow
            return mmio.readReg(lo_reg);
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
