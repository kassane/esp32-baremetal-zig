// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Small HAL layer over `mmio` — small register drivers in the usual shape
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

/// A Timer Group general-purpose timer (TIMGn Tx) as a free-running up-counter,
/// independent of the CPU `CCOUNT`. Comptime register addresses (config/update/
/// lo): `start` enables the counter with a 16-bit prescaler, `ticks` latches the
/// live value and returns its low 32 bits (it counts at the timer-group clock ÷
/// `divider`).
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
/// the pin as an output; pass the GPIO bank's ENABLE / OUT (plain) / OUT set /
/// OUT clear registers. `out_reg` (the plain OUT latch) backs `isSetHigh`/
/// `toggle` — note QEMU does not reflect output writes back through it.
pub fn Output(comptime enable_reg: u32, comptime out_reg: u32, comptime set_reg: u32, comptime clr_reg: u32, comptime mask: u32) type {
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
        pub inline fn isSetHigh() bool {
            return mmio.readReg(out_reg) & mask != 0;
        }
        pub inline fn toggle() void {
            if (isSetHigh()) setLow() else setHigh();
        }
    };
}

/// UART transmitter over a TX FIFO register (e.g. `regs.UART0.FIFO`) — the
/// QEMU-safe subset of a UART driver (the emulated chardev drains instantly;
/// real hardware would also gate on the TX-FIFO status). Comptime `fifo` address.
/// This is just an address-bound convenience over the `mmio` primitives
/// (`writeReg`/`puts`); `write` forwards to `mmio.puts` so the byte loop lives in
/// one place. Reach for `Console.write("…")` when a module already holds a `Uart`;
/// call `mmio.puts(fifo, …)` directly when you only have the raw FIFO address (as
/// the `mmio.log`/panic formatters do internally).
pub fn Uart(comptime fifo: u32) type {
    return struct {
        pub inline fn writeByte(byte: u8) void {
            mmio.writeReg(fifo, byte);
        }
        pub inline fn write(bytes: []const u8) void {
            mmio.puts(fifo, bytes);
        }
    };
}

/// Hardware RNG — reads a 32-bit sample from the RNG data register. Comptime
/// `data` address. (For *true* randomness the SoC's RNG entropy sources must be
/// running; otherwise samples are pseudo-random.)
pub fn Rng(comptime data: u32) type {
    return struct {
        pub inline fn read() u32 {
            return mmio.readReg(data);
        }
    };
}

/// Factory base MAC address read from eFuse — the 48-bit identity each chip is
/// programmed with at manufacturing, from which every radio interface (Wi-Fi
/// STA/AP, Bluetooth, Ethernet) derives its address. Pass the two read-only
/// eFuse words holding it: `lo_reg` (low 32 bits) and `hi_reg` (high 16 bits in
/// bits [15:0]). On ESP32 these are `EFUSE.BLK0_RDATA2`/`BLK0_RDATA1`; on the S2
/// /S3 they are `EFUSE.RD_MAC_SPI_SYS_0`/`_1`. The value is stored big-endian
/// across {hi[15:0], lo[31:0]}, so byte 0 (most significant) comes from the top
/// of `hi`. `@truncate` casts keep the assembly panic-free (no safety path).
pub fn Efuse(comptime lo_reg: u32, comptime hi_reg: u32) type {
    return struct {
        pub inline fn baseMac() [6]u8 {
            const lo = mmio.readReg(lo_reg);
            const hi = mmio.readReg(hi_reg);
            return .{
                @truncate(hi >> 8),
                @truncate(hi),
                @truncate(lo >> 24),
                @truncate(lo >> 16),
                @truncate(lo >> 8),
                @truncate(lo),
            };
        }
    };
}

/// Single-block SHA-256 on the first-generation SHA accelerator: one 512-bit
/// block, i.e. messages ≤ 55 bytes. Pass the SHA `TEXT_0` register plus the
/// SHA-256 START/LOAD/BUSY control registers. Returns the digest as 8 big-endian
/// words — cross-check it against `std.crypto`'s comptime reference (the esp32
/// example does exactly that). All indexing uses `[*]`/`@truncate` and the
/// register writes unroll to comptime addresses, so no safety-check path links.
pub fn Sha256(comptime text_reg: u32, comptime start_reg: u32, comptime load_reg: u32, comptime busy_reg: u32) type {
    return struct {
        pub inline fn hash(msg: []const u8) [8]u32 {
            var block = [_]u32{0} ** 16;
            const b: [*]u32 = &block;
            const p = msg.ptr;
            // pack big-endian message words
            var i: usize = 0;
            while (i < msg.len) : (i +%= 1) b[i >> 2] |= @as(u32, p[i]) << shift(i);
            // 0x80 terminator, then the 64-bit big-endian bit length in word 15
            b[msg.len >> 2] |= @as(u32, 0x80) << shift(msg.len);
            b[15] = @truncate(msg.len *% 8);

            inline for (0..16) |w| mmio.writeReg(text_reg + w * 4, b[w]);
            mmio.writeReg(start_reg, 1);
            while (mmio.readReg(busy_reg) != 0) {}
            mmio.writeReg(load_reg, 1);
            while (mmio.readReg(busy_reg) != 0) {}

            var out: [8]u32 = undefined;
            const o: [*]u32 = &out;
            inline for (0..8) |w| o[w] = mmio.readReg(text_reg + w * 4);
            return out;
        }

        // Big-endian byte position of byte `n` within its 32-bit word.
        inline fn shift(n: usize) u5 {
            return @truncate((@as(usize, 3) -% (n & 3)) *% 8);
        }
    };
}

/// AES-128 ECB single-block encryption on the first-generation AES accelerator.
/// Pass the `KEY_0` / `TEXT_0` register bases plus MODE/START/IDLE. Key and block
/// are 4 *little-endian* words (`std.mem.readInt(.little)` of the byte arrays,
/// matching the accelerator's reset-default endianness); the result comes back
/// the same way — line it up with `std.crypto`'s comptime reference.
pub fn Aes128(comptime key_reg: u32, comptime text_reg: u32, comptime mode_reg: u32, comptime start_reg: u32, comptime idle_reg: u32) type {
    return struct {
        const encrypt_aes128 = 0; // AES_MODE: 0 = encrypt, 128-bit key

        pub inline fn encryptBlock(key: [4]u32, block: [4]u32) [4]u32 {
            inline for (0..4) |i| mmio.writeReg(key_reg + i * 4, key[i]);
            mmio.writeReg(mode_reg, encrypt_aes128);
            inline for (0..4) |i| mmio.writeReg(text_reg + i * 4, block[i]);
            mmio.writeReg(start_reg, 1);
            while (mmio.readReg(idle_reg) == 0) {} // IDLE reads 1 when done
            var out: [4]u32 = undefined;
            const o: [*]u32 = &out;
            inline for (0..4) |i| o[i] = mmio.readReg(text_reg + i * 4);
            return out;
        }
    };
}

/// LEDC PWM (low-speed timer + channel). **Build-only:** the Espressif QEMU does
/// not emulate LEDC, so this writes the timer/channel registers per the TRM field
/// layout but produces no emulator-observable waveform; routing the channel's
/// output to a pad (via the GPIO matrix, a chip-specific signal index) is left to
/// the caller. Pass a timer CONF register and a channel's CONF0/CONF1/HPOINT/DUTY.
pub fn Pwm(comptime timer_conf: u32, comptime ch_conf0: u32, comptime ch_conf1: u32, comptime ch_hpoint: u32, comptime ch_duty: u32) type {
    return struct {
        // LEDC_TIMERx_CONF fields
        const duty_res_pos = 0; // [3:0]  PWM resolution in bits
        const clk_div_pos = 4; // [21:4] integer.fraction (8 fractional bits) divider
        const tick_sel_apb: u32 = 1 << 24; // source = APB_CLK
        const timer_latch: u32 = 1 << 25; // PARA_UP: apply the new timer config
        // LEDC_CHx_CONF0 / CONF1 / DUTY fields
        const sig_out_en: u32 = 1 << 2;
        const ch_latch: u32 = 1 << 4; // PARA_UP: apply the new channel config
        const duty_start: u32 = 1 << 31;
        const duty_frac_bits = 4; // CHx_DUTY holds the duty in 1/16 steps

        /// Start the timer: `res_bits` of duty resolution, clocked at APB ÷ `div`.
        pub inline fn startTimer(comptime res_bits: u4, comptime div: u18) void {
            mmio.writeReg(timer_conf, (@as(u32, res_bits) << duty_res_pos) | (@as(u32, div) << clk_div_pos) | tick_sel_apb | timer_latch);
        }
        /// Drive the channel from `timer` at `duty` (0 .. 2^res_bits).
        pub inline fn setDuty(comptime timer: u2, duty: u32) void {
            mmio.writeReg(ch_hpoint, 0);
            mmio.writeReg(ch_duty, duty << duty_frac_bits);
            mmio.writeReg(ch_conf1, duty_start);
            mmio.writeReg(ch_conf0, @as(u32, timer) | sig_out_en | ch_latch);
        }
    };
}

/// I2C master (single-shot blocking write). **Build-only:** the Espressif QEMU
/// machines do not model an I2C controller, so this programs the controller per
/// the TRM register/field layout but has no emulator-observable bus activity —
/// it links and is correct against the SVD, but is exercised only on real
/// hardware (you must also route SCL/SDA to pads via the GPIO matrix first).
///
/// Unlike the single-register drivers above, I2C touches ~13 registers, so this
/// takes the generated peripheral namespace itself (e.g. `regs.I2C0`) and reads
/// the addresses from it — every field is still a comptime constant, so the MMIO
/// stays provably aligned/non-null and emits no panic path.
pub fn I2c(comptime P: type) type {
    return struct {
        // I2C_COMD opcodes (COMMAND field [13:11]).
        const op_rstart: u32 = 0 << 11;
        const op_write: u32 = 1 << 11;
        const op_stop: u32 = 3 << 11;
        // COMD flags
        const ack_check_en: u32 = 1 << 8;
        // I2C_CTR fields
        const sda_force_out: u32 = 1 << 0;
        const scl_force_out: u32 = 1 << 1;
        const ms_mode: u32 = 1 << 4; // master
        const trans_start: u32 = 1 << 5;
        const clk_en: u32 = 1 << 8;
        const ctr_cfg: u32 = ms_mode | sda_force_out | scl_force_out | clk_en;
        // I2C_FIFO_CONF fields
        const rx_fifo_rst: u32 = 1 << 12;
        const tx_fifo_rst: u32 = 1 << 13;

        /// Configure the controller as a master and set standard-mode (~100 kHz
        /// at an 80 MHz APB) SCL timing. Call once before `write`.
        pub inline fn init() void {
            // Pulse the FIFO resets, then run in FIFO (not non-FIFO) mode.
            mmio.writeReg(P.FIFO_CONF, tx_fifo_rst | rx_fifo_rst);
            mmio.writeReg(P.FIFO_CONF, 0);
            // SCL ~100 kHz: half-period ≈ 400 APB ticks; sane setup/hold around it.
            mmio.writeReg(P.SCL_LOW_PERIOD, 400);
            mmio.writeReg(P.SCL_HIGH_PERIOD, 400);
            mmio.writeReg(P.SDA_HOLD, 40);
            mmio.writeReg(P.SDA_SAMPLE, 40);
            mmio.writeReg(P.SCL_START_HOLD, 200);
            mmio.writeReg(P.SCL_RSTART_SETUP, 200);
            mmio.writeReg(P.SCL_STOP_HOLD, 200);
            mmio.writeReg(P.SCL_STOP_SETUP, 200);
            mmio.writeReg(P.CTR, ctr_cfg);
        }

        /// Blocking write of `data` to the 7-bit address `addr`: [START][WRITE
        /// addr+data, ack-checked][STOP]. Pushes the address + payload into the TX
        /// FIFO, scripts the three commands, then triggers the transfer.
        pub inline fn write(addr: u7, data: []const u8) void {
            // FIFO: address byte (write = LSB 0) followed by the payload. `[*]`
            // indexing + wrapping loop keep this bounds-/overflow-check-free.
            mmio.writeReg(P.DATA, (@as(u32, addr) << 1));
            const p = data.ptr;
            var i: usize = 0;
            while (i < data.len) : (i +%= 1) mmio.writeReg(P.DATA, p[i]);

            const byte_num: u32 = @truncate(1 +% data.len); // addr + payload
            mmio.writeReg(P.COMD_0, op_rstart);
            mmio.writeReg(P.COMD_1, op_write | ack_check_en | byte_num);
            mmio.writeReg(P.COMD_2, op_stop);

            mmio.writeReg(P.CTR, ctr_cfg | trans_start);
        }
    };
}

/// RMT (Remote Control) transmitter — the chips' register-only path to wireless
/// IR signalling (the NEC/RC5 remote protocols, also WS2812 LED timing). Each
/// channel streams 32-bit *symbols* (two timed logic levels) from its RAM block
/// out a pad. This is the honest "radio" a from-scratch HAL can drive: the Wi-Fi
/// /Bluetooth radios need Espressif's closed RF blobs, but IR is pure registers.
///
/// Pass one channel's CONF0/CONF1/DATA registers plus the shared APB_CONF (e.g.
/// `regs.RMT.CH0CONF0`, `CH0CONF1`, `CH0DATA`, `RMT.APB_CONF`). **Build-only:** no
/// Espressif QEMU machine models RMT, so this links and runs on hardware but has
/// no emulator output (and the channel still needs routing to a pad + a 38 kHz
/// carrier — `CARRIER_EN`/`CHnCARRIER_DUTY` — for a real IR LED). Field layout per
/// the SVD; `[*]` indexing keeps the symbol push bounds-check-free.
pub fn Rmt(comptime conf0: u32, comptime conf1: u32, comptime data: u32, comptime apb_conf: u32) type {
    return struct {
        // CH%sCONF0
        const mem_size_1: u32 = 1 << 24; // MEM_SIZE = 1 (one 64-symbol RAM block)
        const clk_en: u32 = 1 << 31;
        const idle_thres: u32 = 0x8000 << 8; // IDLE_THRES: counter value marking end
        // CH%sCONF1
        const tx_start: u32 = 1 << 0;
        const mem_wr_rst: u32 = 1 << 2;
        const mem_rd_rst: u32 = 1 << 3;
        const ref_always_on: u32 = 1 << 17; // keep the channel clock running
        // APB_CONF
        const fifo_mask: u32 = 1 << 0; // CHnDATA writes address the RAM directly

        /// Build one RMT symbol: level `l0` held for `d0` source-clock ticks, then
        /// level `l1` for `d1`. A symbol with `d0 == 0` is the end-of-stream mark.
        pub inline fn symbol(l0: u1, d0: u15, l1: u1, d1: u15) u32 {
            return @as(u32, d0) | (@as(u32, l0) << 15) | (@as(u32, d1) << 16) | (@as(u32, l1) << 31);
        }

        /// Configure the channel: source clock ÷ `div`, one RAM block, direct RAM
        /// writes. Call once before `send`.
        pub inline fn init(comptime div: u8) void {
            mmio.writeReg(apb_conf, fifo_mask);
            mmio.writeReg(conf0, @as(u32, div) | mem_size_1 | idle_thres | clk_en);
        }

        /// Transmit `items` (RMT symbols, see `symbol`) followed by an end marker.
        pub inline fn send(items: []const u32) void {
            mmio.writeReg(conf1, mem_rd_rst | mem_wr_rst); // rewind the RAM pointers
            mmio.writeReg(conf1, 0);
            const p = items.ptr;
            var i: usize = 0;
            while (i < items.len) : (i +%= 1) mmio.writeReg(data, p[i]);
            mmio.writeReg(data, 0); // duration-0 entry stops the transfer
            mmio.writeReg(conf1, ref_always_on | tx_start);
        }
    };
}
