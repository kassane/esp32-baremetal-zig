// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Small HAL layer over `mmio` — small register drivers in the usual shape
//! (`Level`/`Output`/`Input`, a cycle-accurate `Delay`, a TIMG `Timer`). All
//! `inline`, panic-free (wrapping arithmetic, comptime division), so it links on
//! this backend; drivers are comptime-parameterized on their register addresses
//! so the MMIO accesses stay provably aligned and non-null (no panic path).

const mmio = @import("mmio");
const reg = @import("reg");

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
        const enable = reg.bit(31);
        const count_up = reg.bit(30);
        const divider = reg.Field(13, 16); // 16-bit prescaler at [28:13]

        pub inline fn start(comptime div: u16) void {
            mmio.writeReg(config_reg, enable | count_up | divider.set(div));
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

/// UART over a FIFO + STATUS register pair (e.g. `regs.UART0.FIFO`,
/// `regs.UART0.STATUS`). TX is the QEMU-safe subset (the emulated chardev drains
/// instantly); RX pops bytes the controller has latched. The TX helpers forward to
/// the `mmio` primitives so the byte loop lives in one place — reach for
/// `Console.write("…")` when a module holds a `Uart`, or `mmio.puts(fifo, …)`
/// directly with a raw FIFO address (as `mmio.log`/the panic formatter do).
pub fn Uart(comptime fifo: u32, comptime status: u32) type {
    return struct {
        const rxfifo_cnt = reg.Field(0, 8); // STATUS.RXFIFO_CNT

        pub inline fn writeByte(byte: u8) void {
            mmio.writeReg(fifo, byte);
        }
        pub inline fn write(bytes: []const u8) void {
            mmio.puts(fifo, bytes);
        }
        /// Number of bytes currently waiting in the RX FIFO.
        pub inline fn rxAvailable() u32 {
            return rxfifo_cnt.get(mmio.readReg(status));
        }
        /// Pop one received byte, or `null` if the RX FIFO is empty.
        pub inline fn readByte() ?u8 {
            if (rxAvailable() == 0) return null;
            return @truncate(mmio.readReg(fifo));
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

/// Single-block SHA on the first-generation SHA accelerator: one 512-bit block,
/// i.e. messages ≤ 55 bytes, big-endian packing. `digest_words` picks the
/// algorithm's output length — 5 for SHA-1, 8 for SHA-256 — and you pass that
/// algorithm's `TEXT_0` plus its START/LOAD/BUSY control registers. Returns the
/// digest as big-endian words; the esp32 demo cross-checks both SHA-1 and SHA-256
/// against `std.crypto`. All indexing uses `[*]`/`@truncate` and the register
/// writes unroll to comptime addresses, so no safety-check path links.
pub fn Sha(comptime digest_words: u32, comptime text_reg: u32, comptime start_reg: u32, comptime load_reg: u32, comptime busy_reg: u32) type {
    return struct {
        pub inline fn hash(msg: []const u8) [digest_words]u32 {
            var block: [16]u32 = @splat(0);
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

            var out: [digest_words]u32 = undefined;
            const o: [*]u32 = &out;
            inline for (0..digest_words) |w| o[w] = mmio.readReg(text_reg + w * 4);
            return out;
        }

        // Big-endian byte position of byte `n` within its 32-bit word.
        inline fn shift(n: usize) u5 {
            return @truncate((@as(usize, 3) -% (n & 3)) *% 8);
        }
    };
}

/// AES ECB single-block encryption on the first-generation AES accelerator,
/// comptime-selected for a `key_bits` of 128, 192 or 256 (the accelerator's
/// `AES_MODE` encrypt codes are 0/1/2, and the key is 4/6/8 words). Pass the
/// `KEY_0` / `TEXT_0` register bases plus MODE/START/IDLE. Key and block are
/// *little-endian* words (`std.mem.readInt(.little)` of the byte arrays, matching
/// the accelerator's reset-default endianness); the ciphertext comes back the
/// same way — line it up with `std.crypto`'s comptime reference.
pub fn Aes(comptime key_bits: u32, comptime key_reg: u32, comptime text_reg: u32, comptime mode_reg: u32, comptime start_reg: u32, comptime idle_reg: u32) type {
    const key_words = switch (key_bits) {
        128, 192, 256 => key_bits / 32, // 4 / 6 / 8 key words
        else => @compileError("AES key_bits must be 128, 192 or 256"),
    };
    const encrypt_mode = key_bits / 64 - 2; // 128→0, 192→1, 256→2

    return struct {
        pub inline fn encryptBlock(key: [key_words]u32, block: [4]u32) [4]u32 {
            inline for (0..key_words) |i| mmio.writeReg(key_reg + i * 4, key[i]);
            mmio.writeReg(mode_reg, encrypt_mode);
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
        const duty_res = reg.Field(0, 4); // [3:0]  PWM resolution in bits
        const clk_div = reg.Field(4, 18); // [21:4] integer.fraction divider
        const tick_sel_apb = reg.bit(24); // source = APB_CLK
        const timer_latch = reg.bit(25); // PARA_UP: apply the new timer config
        // LEDC_CHx_CONF0 / CONF1 / DUTY fields
        const timer_sel = reg.Field(0, 2); // CONF0: which timer drives the channel
        const sig_out_en = reg.bit(2);
        const ch_latch = reg.bit(4); // PARA_UP: apply the new channel config
        const duty_val = reg.Field(4, 20); // CHx_DUTY: duty in 1/16 steps ([4] frac)
        const duty_start = reg.bit(31);

        /// Start the timer: `res_bits` of duty resolution, clocked at APB ÷ `div`.
        pub inline fn startTimer(comptime res_bits: u4, comptime div: u18) void {
            mmio.writeReg(timer_conf, duty_res.set(res_bits) | clk_div.set(div) | tick_sel_apb | timer_latch);
        }
        /// Drive the channel from `timer` at `duty` (0 .. 2^res_bits).
        pub inline fn setDuty(comptime timer: u2, duty: u32) void {
            mmio.writeReg(ch_hpoint, 0);
            mmio.writeReg(ch_duty, duty_val.set(duty));
            mmio.writeReg(ch_conf1, duty_start);
            mmio.writeReg(ch_conf0, timer_sel.set(timer) | sig_out_en | ch_latch);
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
        // I2C_COMD: COMMAND opcode field [13:11] + the ACK-check flag.
        const opcode = reg.Field(11, 3);
        const op_rstart = opcode.set(0);
        const op_write = opcode.set(1);
        const op_stop = opcode.set(3);
        const ack_check_en = reg.bit(8);
        // I2C_CTR fields
        const sda_force_out = reg.bit(0);
        const scl_force_out = reg.bit(1);
        const ms_mode = reg.bit(4); // master
        const trans_start = reg.bit(5);
        const clk_en = reg.bit(8);
        const ctr_cfg: u32 = ms_mode | sda_force_out | scl_force_out | clk_en;
        // I2C_FIFO_CONF fields
        const rx_fifo_rst = reg.bit(12);
        const tx_fifo_rst = reg.bit(13);
        // I2C_COMD byte_num field [7:0] (bytes the WRITE command transfers).
        const byte_count = reg.Field(0, 8);

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
            mmio.writeReg(P.COMD_1, op_write | ack_check_en | byte_count.set(byte_num));
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
        // CH%sCONF0 fields
        const div_cnt = reg.Field(0, 8); // source-clock prescaler
        const idle_thres = reg.Field(8, 16); // counter value marking end of TX
        const mem_size = reg.Field(24, 4); // RAM blocks owned by the channel
        const clk_en = reg.bit(31);
        // CH%sCONF1 flags
        const tx_start = reg.bit(0);
        const mem_wr_rst = reg.bit(2);
        const mem_rd_rst = reg.bit(3);
        const ref_always_on = reg.bit(17); // keep the channel clock running
        // APB_CONF
        const fifo_mask = reg.bit(0); // CHnDATA writes address the RAM directly
        // RMT symbol (32-bit RAM entry): two timed levels.
        const dur0 = reg.Field(0, 15);
        const lvl0 = reg.Field(15, 1);
        const dur1 = reg.Field(16, 15);
        const lvl1 = reg.Field(31, 1);

        /// Build one RMT symbol: level `l0` held for `d0` source-clock ticks, then
        /// level `l1` for `d1`. A symbol with `d0 == 0` is the end-of-stream mark.
        pub inline fn symbol(l0: u1, d0: u15, l1: u1, d1: u15) u32 {
            return dur0.set(d0) | lvl0.set(l0) | dur1.set(d1) | lvl1.set(l1);
        }

        /// Configure the channel: source clock ÷ `div`, one RAM block, direct RAM
        /// writes. Call once before `send`.
        pub inline fn init(comptime div: u8) void {
            mmio.writeReg(apb_conf, fifo_mask);
            mmio.writeReg(conf0, div_cnt.set(div) | mem_size.set(1) | idle_thres.set(0x8000) | clk_en);
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

/// SPI master, half-duplex MOSI-only single transfer (≤ 64 bytes / one data-buffer
/// load). Takes the generated peripheral namespace (e.g. `regs.SPI2`). **Build-only:**
/// the Espressif QEMU machines model no SPI controller, so this programs the
/// controller per the TRM/SVD field layout and runs on hardware (route the CS/CLK/
/// MOSI signals to pads via the GPIO matrix first) but has no emulator activity.
pub fn Spi(comptime P: type) type {
    return struct {
        // SPI_CMD
        const usr = reg.bit(18); // start a user-defined transaction (self-clears)
        // SPI_USER
        const usr_mosi = reg.bit(27); // enable the MOSI (write) phase
        const ck_out_edge = reg.bit(7); // CPHA for SPI mode 0
        // SPI_CLOCK
        const clkcnt_l = reg.Field(0, 6);
        const clkcnt_h = reg.Field(6, 6);
        const clkcnt_n = reg.Field(12, 6);
        const clkdiv_pre = reg.Field(18, 13);
        // SPI_MOSI_DLEN
        const mosi_dbitlen = reg.Field(0, 24); // transfer length in bits − 1

        /// Configure as a MOSI-only master clocked at f_apb / ((pre+1)·(n+1)).
        /// `n` sets the bit period (n+1 source ticks); `h = n/2` gives ~50% duty.
        pub inline fn init(comptime pre: u13, comptime n: u6) void {
            mmio.writeReg(P.CLOCK, clkdiv_pre.set(pre) | clkcnt_n.set(n) | clkcnt_h.set(n / 2) | clkcnt_l.set(n));
            mmio.writeReg(P.USER, usr_mosi | ck_out_edge);
            mmio.writeReg(P.USER1, 0);
            mmio.writeReg(P.USER2, 0);
        }

        /// Blocking write of `data` (≤ 64 bytes) out MOSI, LSB-word-packed into the
        /// data buffer. The data-buffer writes unroll over comptime indices so each
        /// MMIO address is a compile-time constant (no runtime `@ptrFromInt`, hence
        /// no alignment/null panic path); `[*]` indexing avoids bounds checks.
        pub inline fn write(data: []const u8) void {
            const p = data.ptr;
            inline for (0..16) |w| {
                var word: u32 = 0;
                inline for (0..4) |b| {
                    const idx = w * 4 + b; // comptime
                    if (idx < data.len) word |= @as(u32, p[idx]) << (b * 8);
                }
                mmio.writeReg(P.W_0 + w * 4, word);
            }
            mmio.writeReg(P.MOSI_DLEN, mosi_dbitlen.set(@truncate(data.len *% 8 -% 1)));
            mmio.writeReg(P.CMD, usr);
            while (mmio.readReg(P.CMD) & usr != 0) {} // wait for the transfer to finish
        }
    };
}

/// RSA accelerator — modular exponentiation `Z = base^exponent mod modulus`, the
/// core of RSA sign/verify. Takes the peripheral namespace (`regs.RSA`) and the
/// operand length in 32-bit `words` (a multiple of 16, i.e. 512-bit increments).
/// Following ESP-IDF / esp-hal, the caller supplies the two Montgomery constants
/// the hardware needs — `m_prime = -M⁻¹ mod 2³²` and `r = 2^(2·words·32) mod M` —
/// so this driver computes nothing in software (it would not link freestanding).
/// The memory-block writes unroll over comptime indices, keeping every MMIO
/// address a compile-time constant (no `@ptrFromInt` panic path).
///
/// **Build-only here:** the demo example just exercises the register sequence;
/// the Espressif QEMU *does* model RSA, so a value-checked run is a natural future
/// step once a comptime big-integer reference (`std.math.big`) is wired up.
pub fn Rsa(comptime P: type, comptime words: u32) type {
    if (words == 0 or words % 16 != 0) @compileError("RSA words must be a positive multiple of 16");
    return struct {
        const mode = words / 16 - 1; // MODEXP_MODE: length in 512-bit steps − 1

        /// True once the accelerator has finished its post-reset initialisation.
        pub inline fn ready() bool {
            return mmio.readReg(P.CLEAN) & 1 != 0;
        }

        /// Blocking `base^exponent mod modulus`. All operands are `words` little-
        /// endian 32-bit limbs; `m_prime`/`r` are the caller-computed Montgomery
        /// constants (see above).
        pub inline fn modExp(base: [words]u32, exponent: [words]u32, modulus: [words]u32, m_prime: u32, r: [words]u32) [words]u32 {
            inline for (0..words) |i| {
                mmio.writeReg(P.Y_MEM_0 + i * 4, exponent[i]);
                mmio.writeReg(P.M_MEM_0 + i * 4, modulus[i]);
                mmio.writeReg(P.X_MEM_0 + i * 4, base[i]);
                mmio.writeReg(P.Z_MEM_0 + i * 4, r[i]);
            }
            mmio.writeReg(P.M_PRIME, m_prime);
            mmio.writeReg(P.MODEXP_MODE, mode);
            mmio.writeReg(P.MODEXP_START, 1);
            while (mmio.readReg(P.INTERRUPT) & 1 == 0) {} // wait for completion

            var out: [words]u32 = undefined;
            const o: [*]u32 = &out;
            inline for (0..words) |i| o[i] = mmio.readReg(P.Z_MEM_0 + i * 4);
            mmio.writeReg(P.INTERRUPT, 1); // clear the done flag
            return out;
        }
    };
}

/// TWAI (CAN 2.0) controller — transmit a standard (11-bit ID) data frame. The
/// ESP32 TWAI is SJA1000-compatible: configure bit timing in reset mode, drop to
/// operating mode, write the frame to the TX buffer (`DATA_*`), then request TX.
/// Takes the peripheral namespace (`regs.TWAI0`). **Build-only:** routing TX/RX to
/// pads and a transceiver is board-specific, and the data-byte writes unroll over
/// comptime indices (constant MMIO addresses, no panic path).
pub fn Twai(comptime P: type) type {
    return struct {
        const reset_mode = reg.bit(0); // MODE.RESET_MODE — 1 = config, 0 = run
        const tx_req = reg.bit(0); // CMD.TX_REQ
        const tx_buf_free = reg.bit(2); // STATUS.TX_BUF_ST — 1 when buffer free
        const dlc = reg.Field(0, 4); // DATA_0[3:0] — data length code

        /// Enter the bus with SJA1000 bit-timing register values (compute
        /// `timing0` = BAUD_PRESC|SJW and `timing1` = TSEG1|TSEG2|SAMP for the
        /// target bit rate), then switch to normal operating mode.
        pub inline fn init(comptime timing0: u8, comptime timing1: u8) void {
            mmio.writeReg(P.MODE, reset_mode); // reset/config mode
            mmio.writeReg(P.BUS_TIMING_0, timing0);
            mmio.writeReg(P.BUS_TIMING_1, timing1);
            mmio.writeReg(P.MODE, 0); // operating, normal mode
        }

        /// Transmit a standard-frame (SFF, no RTR) data message, `data` ≤ 8 bytes.
        pub inline fn send(id: u11, data: []const u8) void {
            while (mmio.readReg(P.STATUS) & tx_buf_free == 0) {} // await a free TX buffer
            mmio.writeReg(P.DATA_0, dlc.set(@truncate(data.len)));
            mmio.writeReg(P.DATA_1, @as(u32, id) >> 3); // ID[10:3]
            mmio.writeReg(P.DATA_2, (@as(u32, id) & 0x7) << 5); // ID[2:0] in bits [7:5]
            const p = data.ptr;
            inline for (0..8) |i| {
                if (i < data.len) mmio.writeReg(P.DATA_3 + i * 4, p[i]);
            }
            mmio.writeReg(P.CMD, tx_req);
        }
    };
}

/// MCPWM (Motor-Control PWM) — edge-aligned PWM on timer 0 → operator 0,
/// generator A, the building block for motor/servo drive. Takes the peripheral
/// namespace (`regs.MCPWM0`). The generator raises the output at the period start
/// (timer == 0, UTEZ) and lowers it when the up-counter reaches comparator A
/// (UTEA), so duty = `cmp / period`. **Build-only:** QEMU models no MCPWM, and the
/// output still needs routing to a pad via the GPIO matrix.
pub fn Mcpwm(comptime P: type) type {
    return struct {
        const clk_prescale = reg.Field(0, 8); // CLK_CFG
        const t_prescale = reg.Field(0, 8); // TIMER_x_CFG0
        const t_period = reg.Field(8, 16);
        const t_start = reg.Field(0, 3); // TIMER_x_CFG1: 2 = run continuously
        const t_mod = reg.Field(3, 2); // 1 = up-count
        const op0_timersel = reg.Field(0, 2); // OPERATOR_TIMERSEL
        const cmp_a = reg.Field(0, 16); // CH_x_GEN_TSTMP_A (compare value)
        const gen_utez = reg.Field(0, 2); // GEN action at timer == 0
        const gen_utea = reg.Field(4, 2); // GEN action at up-count == compare A
        const action_low = 1;
        const action_high = 2;

        /// Edge-aligned PWM at f = clk / ((clk_pre+1)·(timer_pre+1)·period); duty is
        /// set later via `setDuty(0..period)`. Drives operator 0 / generator A.
        pub inline fn init(comptime clk_pre: u8, comptime timer_pre: u8, comptime period: u16) void {
            mmio.writeReg(P.CLK_CFG, clk_prescale.set(clk_pre));
            mmio.writeReg(P.TIMER_0_CFG0, t_prescale.set(timer_pre) | t_period.set(period));
            mmio.writeReg(P.OPERATOR_TIMERSEL, op0_timersel.set(0)); // operator 0 ← timer 0
            mmio.writeReg(P.CH_0_GEN_0, gen_utez.set(action_high) | gen_utea.set(action_low));
            mmio.writeReg(P.TIMER_0_CFG1, t_mod.set(1) | t_start.set(2)); // up-count, free-run
        }

        /// Set generator A's duty compare value (`0 .. period`).
        pub inline fn setDuty(duty: u16) void {
            mmio.writeReg(P.CH_0_GEN_TSTMP_A, cmp_a.set(duty));
        }
    };
}

/// I2S master transmitter in *single-data* mode — drives BCK/WS and shifts out a
/// constant 32-bit sample continuously, no DMA descriptor chain required (the
/// streaming/DMA path is a larger future piece). Takes the peripheral namespace
/// (`regs.I2S0`). Philips (MSB-shift) framing. **Build-only:** QEMU models no I2S,
/// and BCK/WS/DATA still need routing to pads via the GPIO matrix.
pub fn I2s(comptime P: type) type {
    return struct {
        // CONF
        const tx_reset = reg.bit(0);
        const tx_fifo_reset = reg.bit(2);
        const tx_start = reg.bit(4);
        const tx_msb_shift = reg.bit(10); // Philips I2S framing
        const conf_master_philips = tx_msb_shift; // TX_SLAVE_MOD = 0 ⇒ master
        // CLKM_CONF
        const clkm_div = reg.Field(0, 8);
        const clk_en = reg.bit(20);
        // SAMPLE_RATE_CONF
        const tx_bck_div = reg.Field(0, 6);
        const tx_bits_mod = reg.Field(12, 6);
        // CONF_CHAN / FIFO_CONF
        const tx_chan_mod = reg.Field(0, 3);
        const tx_fifo_mod = reg.Field(13, 3); // DSCR_EN (bit 12) left 0 ⇒ no DMA

        /// Master TX: I2S_CLK = source ÷ `clkm`, BCK = I2S_CLK ÷ `bck`, `bits`-per-
        /// sample, Philips framing. Call once before `writeConstant`.
        pub inline fn init(comptime clkm: u8, comptime bck: u6, comptime bits: u6) void {
            mmio.writeReg(P.CONF, tx_reset | tx_fifo_reset); // reset the TX path
            mmio.writeReg(P.CONF, 0);
            mmio.writeReg(P.CLKM_CONF, clkm_div.set(clkm) | clk_en);
            mmio.writeReg(P.SAMPLE_RATE_CONF, tx_bck_div.set(bck) | tx_bits_mod.set(bits));
            mmio.writeReg(P.CONF_CHAN, tx_chan_mod.set(0)); // both channels = same data
            mmio.writeReg(P.FIFO_CONF, tx_fifo_mod.set(1)); // 16-bit single-channel FIFO
            mmio.writeReg(P.CONF, conf_master_philips);
        }

        /// Continuously transmit the constant 32-bit `sample` (single-data mode).
        pub inline fn writeConstant(sample: u32) void {
            mmio.writeReg(P.CONF_SIGLE_DATA, sample);
            mmio.writeReg(P.CONF, conf_master_philips | tx_start);
        }
    };
}

/// DAC — 8-bit analog output on an RTC DAC pad (`regs.RTC_IO.PAD_DAC_0` = DAC1 on
/// GPIO25, `PAD_DAC_1` = DAC2 on GPIO26). Writing forces the pad's DAC power-up
/// control to this register and drives `level` (0..255 ≈ 0..Vref) — the same path
/// ESP-IDF's `dac_output_voltage` takes. **Build-only:** QEMU has no observable
/// analog output (the cosine-wave generator is left disabled, its reset default).
pub fn Dac(comptime pad_dac_reg: u32) type {
    return struct {
        const dac_xpd_force = reg.bit(10); // power the DAC from this register
        const mux_sel = reg.bit(17); // route the RTC pad to the DAC
        const xpd_dac = reg.bit(18); // DAC powered on
        const value = reg.Field(19, 8); // 8-bit output level

        /// Drive `level` (0 = 0 V … 255 ≈ Vref) on the DAC pad.
        pub inline fn write(level: u8) void {
            mmio.writeReg(pad_dac_reg, dac_xpd_force | xpd_dac | mux_sel | value.set(level));
        }
    };
}

/// ADC (SAR) software one-shot read on `regs.SENS.SAR_MEAS_START1` (ADC1) or
/// `SAR_MEAS_START2` (ADC2). Forces software pad-select + start, triggers a
/// conversion of `channel` and returns the raw result. This is the trigger/read
/// core — a real reading also needs attenuation (`SAR_ATTEN*`), the SAR clock
/// (`SAR_READ_CTRL`) and RTC power configured. **Build-only:** QEMU has no analog
/// input. Fields from the SVD, via reg.zig.
pub fn Adc(comptime meas_reg: u32) type {
    return struct {
        const data = reg.Field(0, 16); // MEASn_DATA_SAR
        const done = reg.bit(16); // MEASn_DONE_SAR
        const start = reg.bit(17); // MEASn_START_SAR (write 1 to trigger)
        const start_force = reg.bit(18); // software, not the RTC FSM
        const en_pad = reg.Field(19, 12); // one bit per channel
        const en_pad_force = reg.bit(31);

        /// Software one-shot of `channel` (0..11): returns the raw SAR value.
        pub inline fn read(comptime channel: u4) u16 {
            const sel = en_pad_force | start_force | en_pad.set(@as(u32, 1) << channel);
            mmio.writeReg(meas_reg, sel); // select the channel
            mmio.writeReg(meas_reg, sel | start); // trigger the conversion
            while (mmio.readReg(meas_reg) & done == 0) {} // wait for completion
            return @truncate(data.get(mmio.readReg(meas_reg)));
        }
    };
}

/// USB Serial/JTAG CDC-ACM console transmitter (ESP32-S3/-C3, the default USB
/// console). Pass the peripheral's `EP1` FIFO byte register and `EP1_CONF`
/// (e.g. `regs.USB_DEVICE.EP1`, `EP1_CONF`). `write` pushes bytes into the IN FIFO
/// — gating on `SERIAL_IN_EP_DATA_FREE` — then sets `WR_DONE` to flush the packet
/// to the host. `[*]` indexing keeps it bounds-check-free. **Build-only:** needs a
/// USB host attached, which the Espressif QEMU does not provide.
pub fn UsbSerial(comptime ep1: u32, comptime ep1_conf: u32) type {
    return struct {
        const wr_done = reg.bit(0); // EP1_CONF.WR_DONE — flush IN FIFO to host
        const in_free = reg.bit(1); // EP1_CONF.SERIAL_IN_EP_DATA_FREE

        pub inline fn writeByte(byte: u8) void {
            while (mmio.readReg(ep1_conf) & in_free == 0) {} // wait for FIFO space
            mmio.writeReg(ep1, byte);
        }
        pub inline fn write(bytes: []const u8) void {
            const p = bytes.ptr;
            var i: usize = 0;
            while (i < bytes.len) : (i +%= 1) writeByte(p[i]);
            mmio.writeReg(ep1_conf, wr_done); // flush the packet to the host
        }
    };
}

/// On-chip temperature sensor (ESP32-S2/-S3) — `regs.SENS.SAR_TSENS_CTRL`. Powers
/// the sensor (software-forced) and returns its raw 8-bit reading once ready; the
/// raw value maps to °C through a per-chip calibration curve the caller applies.
/// **Build-only:** QEMU has no thermal model. Fields from the SVD, via reg.zig.
pub fn TempSensor(comptime ctrl_reg: u32) type {
    return struct {
        const out = reg.Field(0, 8); // SAR_TSENS_OUT
        const ready = reg.bit(8); // SAR_TSENS_READY
        const clk_div = reg.Field(14, 8); // SAR_TSENS_CLK_DIV
        const power_up = reg.bit(22);
        const power_up_force = reg.bit(23); // power the sensor from this register

        /// Power up the sensor (clock ÷ `div`) and return the raw reading once ready.
        pub inline fn read(comptime div: u8) u8 {
            mmio.writeReg(ctrl_reg, power_up_force | power_up | clk_div.set(div));
            while (mmio.readReg(ctrl_reg) & ready == 0) {} // wait for a sample
            return @truncate(out.get(mmio.readReg(ctrl_reg)));
        }
    };
}

/// IO_MUX pad configuration — pull resistor, input-enable and drive strength for a
/// single pad (pass its IO_MUX register, e.g. `regs.IO_MUX.GPIO0`). Complements the
/// `Output`/`Input` drivers, which toggle/read a pad; this sets its electrical
/// properties. Field bits from the SVD, via reg.zig.
pub fn IoMux(comptime pad_reg: u32) type {
    return struct {
        const fun_wpd = reg.bit(7); // pull-down enable
        const fun_wpu = reg.bit(8); // pull-up enable
        const fun_ie = reg.bit(9); // input enable
        const fun_drv = reg.Field(10, 2); // drive strength 0..3 (~5..40 mA)

        pub const Pull = enum { none, up, down };

        /// Configure the pad: `pull` resistor, whether the input buffer is enabled,
        /// and `drive` strength (0..3). `if` (not `switch`) on the enum keeps the
        /// store panic-path-free on this backend.
        pub inline fn config(pull: Pull, input_enable: bool, drive: u2) void {
            var v: u32 = fun_drv.set(drive);
            if (input_enable) v |= fun_ie;
            if (pull == .up) v |= fun_wpu;
            if (pull == .down) v |= fun_wpd;
            mmio.writeReg(pad_reg, v);
        }
    };
}

/// Timer-Group watchdog (TIMGn WDT) — the inverse of `init.disableWatchdogs`: arm
/// a reset-on-timeout watchdog and `feed` it. Pass the timer-group namespace
/// (`regs.TIMG0`). Stage 0 is configured to reset the whole system if the counter
/// (TIMG clock ÷ prescaler) reaches the timeout before a `feed`. Writes are guarded
/// by the hardware write-protect key. Field bits from the SVD, via reg.zig.
pub fn Watchdog(comptime P: type) type {
    return struct {
        const wkey: u32 = 0x50D8_3AA1; // WDTWPROTECT unlock value (TRM constant)
        const wdt_en = reg.bit(31); // WDTCONFIG0.WDT_EN
        const stg0 = reg.Field(29, 2); // stage-0 action
        const prescale = reg.Field(16, 16); // WDTCONFIG1.WDT_CLK_PRESCALE
        const reset_system = 3; // stage action: reset the whole system

        /// Arm the watchdog: TIMG clock ÷ `presc`, stage-0 system reset after
        /// `timeout` ticks. Call `feed()` regularly to avoid the reset.
        pub inline fn start(comptime presc: u16, timeout: u32) void {
            mmio.writeReg(P.WDTWPROTECT, wkey); // unlock
            mmio.writeReg(P.WDTCONFIG1, prescale.set(presc));
            mmio.writeReg(P.WDTCONFIG_0, timeout); // stage-0 hold time (ticks)
            mmio.writeReg(P.WDTCONFIG0, wdt_en | stg0.set(reset_system));
            mmio.writeReg(P.WDTWPROTECT, 0); // re-lock
        }
        /// Reset the timeout counter ("feed the dog").
        pub inline fn feed() void {
            mmio.writeReg(P.WDTWPROTECT, wkey);
            mmio.writeReg(P.WDTFEED, 1);
            mmio.writeReg(P.WDTWPROTECT, 0);
        }
    };
}

/// Reset reason — reads the PRO-CPU reset cause from `regs.RTC_CNTL.RESET_STATE`
/// (1 = power-on, 12 = software, the watchdog/brownout/deep-sleep codes, … per the
/// TRM). Every production firmware branches on this at boot. Single read, field via
/// reg.zig.
pub fn ResetReason(comptime reset_state_reg: u32) type {
    return struct {
        const procpu = reg.Field(0, 6); // RESET_CAUSE_PROCPU

        /// The PRO-CPU reset cause code.
        pub inline fn cause() u8 {
            return @truncate(procpu.get(mmio.readReg(reset_state_reg)));
        }
    };
}

/// Trigger an immediate full software reset via `regs.RTC_CNTL.OPTIONS0`
/// (sets `SW_SYS_RST`). Does not return — the chip restarts; `mmio.halt` is the
/// fallback spin (a panic-free `noreturn`, since a compiler `unreachable` here
/// would emit an unlinkable panic path).
pub inline fn softwareReset(comptime options0_reg: u32) noreturn {
    mmio.writeReg(options0_reg, mmio.readReg(options0_reg) | reg.bit(31));
    mmio.halt();
}

/// Poll-based GPIO edge detection — complements `Input` (level) by latching
/// rising/falling edges in the GPIO event-status register so a poll loop can catch
/// transitions it might otherwise miss (e.g. button presses) without interrupts.
/// Pass the pin's `PIN_n` config register, its bit `mask`, and the bank's `STATUS`
/// + `STATUS_W1TC` registers.
pub fn GpioEdge(comptime pin_reg: u32, comptime mask: u32, comptime status_reg: u32, comptime clr_reg: u32) type {
    return struct {
        const int_type = reg.Field(7, 3); // PIN_n.INT_TYPE

        pub const Edge = enum(u3) { disabled = 0, rising = 1, falling = 2, any = 3 };

        /// Select which edge(s) latch an event for this pin.
        pub inline fn configure(comptime edge: Edge) void {
            mmio.writeReg(pin_reg, int_type.set(@intFromEnum(edge)));
        }
        /// True if an edge has been latched since the last call; clears the latch.
        pub inline fn takeEdge() bool {
            const hit = mmio.readReg(status_reg) & mask != 0;
            if (hit) mmio.writeReg(clr_reg, mask);
            return hit;
        }
    };
}
