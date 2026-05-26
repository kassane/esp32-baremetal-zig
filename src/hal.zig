// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Small HAL layer over `mmio` — small register drivers in the usual shape
//! (`Level`/`Output`/`Input`, a cycle-accurate `Delay`, a TIMG `Timer`). All
//! `inline`, panic-free (wrapping arithmetic, comptime division), so it links on
//! this backend; drivers are comptime-parameterized on their register addresses
//! so the MMIO accesses stay provably aligned and non-null (no panic path).

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio");
const reg = @import("reg");
const panic_ns = @import("panic");
const config = @import("config"); // build-time knobs (see root build.zig)

/// A UART console bound to a `fifo` register — bundles the freestanding panic
/// handler and the `std.log` backend an example wires into its root, so each one
/// needn't hand-roll them. `options` carries the build-time `-Dlog-level`:
/// ```
/// const con = hal.Console(regs.UART0.FIFO);
/// pub const panic = con.panic;
/// pub const std_options = con.options;
/// ```
pub fn Console(comptime fifo: u32) type {
    return struct {
        fn onPanic(msg: []const u8, ret_addr: ?usize) noreturn {
            mmio.panic(fifo, msg, ret_addr);
        }
        /// Panic namespace: render the message + backtrace over UART, then halt.
        pub const panic = panic_ns.Handler(onPanic);
        /// `std.options.logFn` backend: `[level] message` per line over UART.
        pub fn logFn(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
            mmio.log(fifo, level, fmt, args);
        }
        /// Drop-in `std_options`: routes `std.log` to UART and applies the
        /// build-time `-Dlog-level` (default `info`).
        pub const options: std.Options = .{ .logFn = logFn, .log_level = @enumFromInt(config.log_level) };
    };
}

/// Read the core cycle counter — the Xtensa `CCOUNT` special register, or the
/// RISC-V `cycle` CSR on the ULP coprocessor. Advances at the core clock.
pub inline fn cycleCount() u32 {
    return switch (builtin.cpu.arch) {
        .xtensa => asm volatile ("rsr.ccount %[ret]"
            : [ret] "=r" (-> u32),
        ),
        else => asm volatile ("csrr %[ret], cycle"
            : [ret] "=r" (-> u32),
        ),
    };
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
        // CHx_CONF1 hardware-fade fields: step the duty by `scale` every `cycle` PWM
        // periods, for `num` steps, in the `inc` direction.
        const duty_scale = reg.Field(0, 10);
        const duty_cycle = reg.Field(10, 10);
        const duty_num = reg.Field(20, 10);
        const duty_inc = reg.bit(30);
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
        /// Hardware fade from `start` duty: step by `scale` every `cycle` PWM
        /// periods for `num` steps (rising if `increase`). The LEDC ramps the duty
        /// itself — no CPU loop. Drive the channel from `timer`.
        pub inline fn fade(comptime timer: u2, start: u32, scale: u10, cycle: u10, num: u10, increase: bool) void {
            mmio.writeReg(ch_hpoint, 0);
            mmio.writeReg(ch_duty, duty_val.set(start));
            var conf1 = duty_start | duty_scale.set(scale) | duty_cycle.set(cycle) | duty_num.set(num);
            if (increase) conf1 |= duty_inc;
            mmio.writeReg(ch_conf1, conf1);
            mmio.writeReg(ch_conf0, timer_sel.set(timer) | sig_out_en | ch_latch);
        }
    };
}

/// I2C master, single-shot blocking `write` and `read`. **Build-only:** the
/// Espressif QEMU machines do not model an I2C controller, so this programs the
/// controller per the TRM register/field layout but has no emulator-observable bus
/// activity — it links and is correct against the SVD, but is exercised only on
/// real hardware (you must also route SCL/SDA to pads via the GPIO matrix first).
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
        const op_read = opcode.set(2);
        const op_stop = opcode.set(3);
        const ack_check_en = reg.bit(8); // WRITE: check the slave's ACK
        const ack_value = reg.bit(10); // READ: ACK level the master drives (1 = NAK)
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
        // I2C_COMD byte_num field [7:0] (bytes a WRITE/READ command transfers).
        const byte_count = reg.Field(0, 8);
        const trans_complete = reg.bit(7); // I2C_INT_RAW.TRANS_COMPLETE

        // Standard-mode (~100 kHz at an 80 MHz APB) SCL timing, in APB clock ticks.
        const scl_half_period = 400; // SCL low/high half-period
        const scl_phase = 200; // start/stop setup + hold
        const sda_window = 40; // SDA hold + sample

        /// Configure the controller as a master and set standard-mode (~100 kHz
        /// at an 80 MHz APB) SCL timing. Call once before `write`.
        pub inline fn init() void {
            // Pulse the FIFO resets, then run in FIFO (not non-FIFO) mode.
            mmio.writeReg(P.FIFO_CONF, tx_fifo_rst | rx_fifo_rst);
            mmio.writeReg(P.FIFO_CONF, 0);
            mmio.writeReg(P.SCL_LOW_PERIOD, scl_half_period);
            mmio.writeReg(P.SCL_HIGH_PERIOD, scl_half_period);
            mmio.writeReg(P.SDA_HOLD, sda_window);
            mmio.writeReg(P.SDA_SAMPLE, sda_window);
            mmio.writeReg(P.SCL_START_HOLD, scl_phase);
            mmio.writeReg(P.SCL_RSTART_SETUP, scl_phase);
            mmio.writeReg(P.SCL_STOP_HOLD, scl_phase);
            mmio.writeReg(P.SCL_STOP_SETUP, scl_phase);
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

        /// Blocking read of `buf.len` bytes from the 7-bit address `addr`: [START]
        /// [WRITE addr|R, ack-checked][READ … ACK][READ last, NAK][STOP], then pops
        /// the RX FIFO. A runtime branch only picks the one- vs many-byte command
        /// layout — every command-register address stays comptime — and `[*]`
        /// indexing + wrapping arithmetic keep it bounds-/overflow-check-free.
        pub inline fn read(addr: u7, buf: []u8) void {
            mmio.writeReg(P.DATA, (@as(u32, addr) << 1) | 1); // address byte, read = LSB 1
            mmio.writeReg(P.COMD_0, op_rstart);
            mmio.writeReg(P.COMD_1, op_write | ack_check_en | byte_count.set(1)); // send the address
            if (buf.len > 1) {
                // ACK all but the last byte, then NAK the last so the slave releases SDA.
                mmio.writeReg(P.COMD_2, op_read | byte_count.set(@truncate(buf.len -% 1)));
                mmio.writeReg(P.COMD_3, op_read | ack_value | byte_count.set(1));
                mmio.writeReg(P.COMD_4, op_stop);
            } else {
                mmio.writeReg(P.COMD_2, op_read | ack_value | byte_count.set(1));
                mmio.writeReg(P.COMD_3, op_stop);
            }
            mmio.writeReg(P.CTR, ctr_cfg | trans_start);

            while (mmio.readReg(P.INT_RAW) & trans_complete == 0) {} // await the bus transfer
            const p = buf.ptr;
            var i: usize = 0;
            while (i < buf.len) : (i +%= 1) p[i] = @truncate(mmio.readReg(P.DATA)); // pop the RX FIFO
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

        const one_ram_block = 1; // RAM blocks the channel owns
        const idle_threshold = 0x8000; // idle ticks that mark end-of-transmission

        /// Configure the channel: source clock ÷ `div`, one RAM block, direct RAM
        /// writes. Call once before `send`.
        pub inline fn init(comptime div: u8) void {
            mmio.writeReg(apb_conf, fifo_mask);
            mmio.writeReg(conf0, div_cnt.set(div) | mem_size.set(one_ram_block) | idle_thres.set(idle_threshold) | clk_en);
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

/// SPI master, half-duplex single transfer (≤ 64 bytes / one data-buffer load):
/// `write` clocks bytes out MOSI, `read` clocks them in over MISO. Takes the
/// generated peripheral namespace (e.g. `regs.SPI2`). **Build-only:** the Espressif
/// QEMU machines model no SPI controller, so this programs the controller per the
/// TRM/SVD field layout and runs on hardware (route the CS/CLK/MOSI/MISO signals to
/// pads via the GPIO matrix first) but has no emulator activity.
pub fn Spi(comptime P: type) type {
    return struct {
        // SPI_CMD
        const usr = reg.bit(18); // start a user-defined transaction (self-clears)
        // SPI_USER
        const usr_mosi = reg.bit(27); // enable the MOSI (write) phase
        const usr_miso = reg.bit(28); // enable the MISO (read) phase
        const ck_out_edge = reg.bit(7); // CPHA for SPI mode 0
        // SPI_CLOCK
        const clkcnt_l = reg.Field(0, 6);
        const clkcnt_h = reg.Field(6, 6);
        const clkcnt_n = reg.Field(12, 6);
        const clkdiv_pre = reg.Field(18, 13);
        // SPI_MOSI_DLEN / SPI_MISO_DLEN share this field layout.
        const dbitlen = reg.Field(0, 24); // transfer length in bits − 1

        /// Configure as a master clocked at f_apb / ((pre+1)·(n+1)). `n` sets the
        /// bit period (n+1 source ticks); `h = n/2` gives a ~50% duty cycle.
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
            mmio.writeReg(P.USER, usr_mosi | ck_out_edge); // select the MOSI (write) phase
            const p = data.ptr;
            inline for (0..16) |w| {
                var word: u32 = 0;
                inline for (0..4) |b| {
                    const idx = w * 4 + b; // comptime
                    if (idx < data.len) word |= @as(u32, p[idx]) << (b * 8);
                }
                mmio.writeReg(P.W_0 + w * 4, word);
            }
            mmio.writeReg(P.MOSI_DLEN, dbitlen.set(@truncate(data.len *% 8 -% 1)));
            mmio.writeReg(P.CMD, usr);
            while (mmio.readReg(P.CMD) & usr != 0) {} // wait for the transfer to finish
        }

        /// Blocking read of `buf.len` bytes (≤ 64) clocked in over MISO. The
        /// controller fills the same data buffer (`W_0`…) the write path drives;
        /// the unrolled comptime indices keep every MMIO address constant and the
        /// `[*]` writes bounds-check-free.
        pub inline fn read(buf: []u8) void {
            mmio.writeReg(P.USER, usr_miso | ck_out_edge); // select the MISO (read) phase
            mmio.writeReg(P.MISO_DLEN, dbitlen.set(@truncate(buf.len *% 8 -% 1)));
            mmio.writeReg(P.CMD, usr);
            while (mmio.readReg(P.CMD) & usr != 0) {} // wait for the transfer to finish
            const p = buf.ptr;
            inline for (0..16) |w| {
                const word = mmio.readReg(P.W_0 + w * 4);
                inline for (0..4) |b| {
                    const idx = w * 4 + b; // comptime
                    if (idx < buf.len) p[idx] = @truncate(word >> (b * 8));
                }
            }
        }
    };
}

/// RSA accelerator — modular exponentiation `Z = base^exponent mod modulus`, the
/// core of RSA sign/verify. Takes the peripheral namespace (`regs.RSA`) and the
/// operand length in 32-bit `words` (a multiple of 16, i.e. 512-bit increments).
/// The caller supplies the two Montgomery constants the hardware needs —
/// `m_prime = -M⁻¹ mod 2³²` and `r = 2^(2·words·32) mod M` —
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
/// control to this register and drives `level` (0..255 ≈ 0..Vref), the standard
/// software-driven DAC output path. **Build-only:** QEMU has no observable
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
        const wkey = reg.wdt_wprotect_key; // WDTWPROTECT unlock value
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

/// ESP32-S3 System Timer — the SoC's always-on 52-bit up-counter, a monotonic time
/// base independent of the Timer-Group `Timer` and of the CPU-clock changes
/// `CCOUNT` tracks. Takes the peripheral namespace (`regs.SYSTIMER`). A read is a
/// latch handshake — pulse `UNIT_OP.UPDATE`, wait for `VALUE_VALID`, then read the
/// HI/LO snapshot — so `count()` returns a coherent value even while the counter
/// advances. One of the blocks the Espressif QEMU esp32s3 machine emulates, so
/// `examples/systimer` runs under `zig build demo`. Field bits from the SVD, via
/// reg.zig.
pub fn SysTimer(comptime P: type) type {
    return struct {
        const clk_en = reg.bit(31); // CONF.CLK_EN — peripheral clock
        const unit0_work_en = reg.bit(30); // CONF.TIMER_UNIT0_WORK_EN — run unit 0
        const update = reg.bit(30); // UNIT_OP_0.TIMER_UNIT0_UPDATE — latch a snapshot
        const value_valid = reg.bit(29); // UNIT_OP_0.TIMER_UNIT0_VALUE_VALID
        const hi_value = reg.Field(0, 20); // UNIT_VALUE_0_HI holds count bits [51:32]

        /// Enable the timer clock and unit 0's counter. Call once at boot.
        pub inline fn init() void {
            mmio.writeReg(P.CONF, clk_en | unit0_work_en);
        }
        /// Coherent 52-bit count of unit 0 as a u64 (latched via the UPDATE/VALID
        /// handshake so the HI and LO halves can't tear as the counter advances).
        pub inline fn count() u64 {
            mmio.writeReg(P.UNIT_OP_0, update);
            while (mmio.readReg(P.UNIT_OP_0) & value_valid == 0) {} // await a coherent snapshot
            const hi = hi_value.get(mmio.readReg(P.UNIT_VALUE_0_HI));
            const lo = mmio.readReg(P.UNIT_VALUE_0_LO);
            return (@as(u64, hi) << 32) | lo;
        }
    };
}

/// WS2812 / NeoPixel addressable-RGB driver built on the `Rmt` transmitter — the
/// "smart LED" on many ESP32 dev boards (e.g. the ESP32-S3 onboard RGB). Each
/// colour bit becomes one RMT symbol whose high-time encodes 0 vs 1 (the WS2812's
/// single-wire NRZ line code); the 24 bits of a pixel stream out a pad in G-R-B,
/// MSB-first order, and the transmitter's trailing idle doubles as the > 50 µs
/// latch/reset. Takes the same four channel registers as `Rmt`, and reuses it
/// wholesale. **Build-only:** no Espressif QEMU machine models RMT (route the
/// channel to the LED's data pad via the GPIO matrix on hardware). The bit timing
/// folds from the datasheet nanoseconds to source-clock ticks at comptime — no
/// hand-tuned tick counts.
pub fn Ws2812(comptime conf0: u32, comptime conf1: u32, comptime data: u32, comptime apb_conf: u32) type {
    return struct {
        const Channel = Rmt(conf0, conf1, data, apb_conf);
        const src_hz: u32 = 80_000_000; // RMT source = 80 MHz APB clock
        const divider: u8 = 4; // → 20 MHz, i.e. 50 ns per source-clock tick
        const ticks_per_us = src_hz / divider / 1_000_000;
        // WS2812 datasheet bit timing (ns) → ticks, folded at comptime.
        const t0h = nsToTicks(400); // "0" bit: 0.40 µs high
        const t0l = nsToTicks(850); //          0.85 µs low
        const t1h = nsToTicks(800); // "1" bit: 0.80 µs high
        const t1l = nsToTicks(450); //          0.45 µs low
        const bit0 = Channel.symbol(1, t0h, 0, t0l);
        const bit1 = Channel.symbol(1, t1h, 0, t1l);

        inline fn nsToTicks(comptime ns: u32) u15 {
            return @intCast(ns * ticks_per_us / 1000);
        }

        /// A 24-bit colour. The wire order is G-R-B; callers think in r/g/b.
        pub const Color = struct { r: u8, g: u8, b: u8 };

        /// Configure the RMT channel for WS2812 timing. Call once before `write`.
        pub inline fn init() void {
            Channel.init(divider);
        }
        /// Drive one pixel (G-R-B, MSB first), followed by the RMT end marker whose
        /// idle latches the colour. `[*]` indexing keeps the symbol fill panic-free.
        pub inline fn write(color: Color) void {
            const channels = [_]u8{ color.g, color.r, color.b };
            var syms: [8 * channels.len]u32 = undefined;
            const s: [*]u32 = &syms;
            var n: usize = 0;
            for (channels) |byte| {
                var bit: u8 = 0x80; // walk MSB → LSB
                while (bit != 0) : (bit >>= 1) {
                    s[n] = if (byte & bit != 0) bit1 else bit0;
                    n +%= 1;
                }
            }
            Channel.send(&syms);
        }
    };
}

/// Peripheral clock + reset control on the system bus — the gate a peripheral sits
/// behind before its registers respond. `enable()` ungates the peripheral's bus
/// clock; `reset()` pulses its reset line (assert, then release). Pass the
/// clock-enable and reset-enable registers plus the peripheral's bit `mask` — on
/// ESP32 `regs.DPORT.PERIP_CLK_EN` / `PERIP_RST_EN`, on the S2/S3 the `SYSTEM`
/// peripheral's `PERIP_CLK_EN*` / `PERIP_RST_EN*`. Read-modify-write, so it leaves
/// the sibling peripherals sharing the register untouched. The other drivers here
/// assume the boot ROM left their clock running; this is the explicit control for
/// the ones it doesn't.
pub fn ClockGate(comptime clk_en_reg: u32, comptime rst_en_reg: u32, comptime mask: u32) type {
    return struct {
        /// Ungate the peripheral's bus clock.
        pub inline fn enable() void {
            mmio.writeReg(clk_en_reg, mmio.readReg(clk_en_reg) | mask);
        }
        /// Gate (stop) the peripheral's bus clock.
        pub inline fn disable() void {
            mmio.writeReg(clk_en_reg, mmio.readReg(clk_en_reg) & ~mask);
        }
        /// Pulse the peripheral's reset line: assert, then release.
        pub inline fn reset() void {
            mmio.writeReg(rst_en_reg, mmio.readReg(rst_en_reg) | mask);
            mmio.writeReg(rst_en_reg, mmio.readReg(rst_en_reg) & ~mask);
        }
    };
}

/// RTC retention scratch register (`regs.RTC_CNTL.STORE0` … `STORE3`) — a 32-bit
/// word in the always-on RTC power domain that keeps its value across deep sleep
/// and every reset except a power-on, where main RAM is lost. Firmware uses these
/// words for boot counters and to hand state across a sleep/reset cycle; pairs with
/// `ResetReason` and `softwareReset`. A plain read/write of the chosen word.
pub fn RtcStore(comptime store_reg: u32) type {
    return struct {
        pub inline fn read() u32 {
            return mmio.readReg(store_reg);
        }
        pub inline fn write(value: u32) void {
            mmio.writeReg(store_reg, value);
        }
    };
}

/// Brownout detector (`regs.RTC_CNTL.BROWN_OUT`) — trips when the supply sags below
/// a threshold, so firmware never runs on a collapsing rail (battery droop, the
/// inrush of a peripheral powering on). `arm(level)` enables detection at `level`
/// (0..7, higher = higher trip voltage) and resets the chip on a brownout;
/// `detected()` reads the live flag. The detector bits share their register with
/// unrelated RTC-memory-CRC fields, so `arm` read-modify-writes to leave those
/// intact. **Build-only:** QEMU has no analog supply to trip. Fields from the SVD.
pub fn Brownout(comptime brown_out_reg: u32) type {
    return struct {
        const ena = reg.bit(30); // BROWN_OUT.ENA — detector enable
        const rst_ena = reg.bit(26); // RST_ENA — reset the chip on a brownout
        const threshold = reg.Field(27, 3); // DBROWN_OUT_THRES — trip level
        const det = reg.bit(31); // DET — brownout currently detected (read-only)
        const own_bits = ena | rst_ena | threshold.mask;

        /// Enable the detector at `level` (0..7; higher trips at a higher voltage)
        /// and reset the chip when it trips. Preserves the register's other fields.
        pub inline fn arm(comptime level: u3) void {
            const others = mmio.readReg(brown_out_reg) & ~own_bits;
            mmio.writeReg(brown_out_reg, others | ena | rst_ena | threshold.set(level));
        }
        /// True if a brownout is currently being detected.
        pub inline fn detected() bool {
            return mmio.readReg(brown_out_reg) & det != 0;
        }
    };
}

/// Capacitive touch sensor (ESP32) — software-forced single read of a pad's raw
/// capacitance count (a *lower* count means higher capacitance, i.e. a touch).
/// Pads share result registers two-up: pad 2n/2n+1 → `SAR_TOUCH_OUT_n`, the even
/// pad in the low half and the odd pad in the high. Pass the SENS namespace `P`,
/// the pad's `RTC_IO.TOUCH_PADn` config register, its touch number `nr` (0..9) and
/// the matching `SAR_TOUCH_OUT_*` register. **Build-only:** QEMU has no touch model,
/// and a real reading also needs the RTC touch FSM timing tuned for the board.
/// Field bits from the SVD, via reg.zig.
pub fn Touch(comptime P: type, comptime pad_reg: u32, comptime nr: u4, comptime out_reg: u32) type {
    return struct {
        const meas_duration = 0x7FFF; // SAR_TOUCH_CTRL1.TOUCH_MEAS_DELAY (max window)
        const xpd_wait_cycles = 0xFF; // TOUCH_XPD_WAIT — pad power-up settle time
        // RTC_IO.TOUCH_PADn — route the pad to the touch mux and power it.
        const to_gpio = reg.bit(12);
        const mux_sel = reg.bit(19);
        const xpd = reg.bit(20);
        const start = reg.bit(22);
        // SENS.SAR_TOUCH_CTRL1
        const meas_delay = reg.Field(0, 16);
        const xpd_wait = reg.Field(16, 8);
        const out_1en = reg.bit(25);
        // SENS.SAR_TOUCH_CTRL2
        const meas_done = reg.bit(10);
        const start_en = reg.bit(12); // software trigger one measurement
        const start_force = reg.bit(13); // software (not FSM) control
        const worken = reg.bit(nr); // SAR_TOUCH_ENABLE.TOUCH_PAD_WORKEN[nr]
        // SAR_TOUCH_OUT_n packs the even pad in [15:0] and the odd pad in [31:16].
        const count = if (nr & 1 == 0) reg.Field(0, 16) else reg.Field(16, 16);

        /// Configure the pad for touch sensing and select software-forced
        /// measurement. Call once before `read`.
        pub inline fn init() void {
            mmio.writeReg(P.SAR_TOUCH_CTRL1, meas_delay.set(meas_duration) | xpd_wait.set(xpd_wait_cycles) | out_1en);
            mmio.writeReg(pad_reg, start | xpd | mux_sel | to_gpio); // route + power the pad
            mmio.writeReg(P.SAR_TOUCH_ENABLE, mmio.readReg(P.SAR_TOUCH_ENABLE) | worken);
            mmio.writeReg(P.SAR_TOUCH_CTRL2, start_force); // software, not the FSM
        }
        /// Software-forced single measurement: pulse the start bit, wait for the
        /// done flag, and return the pad's raw count.
        pub inline fn read() u16 {
            mmio.writeReg(P.SAR_TOUCH_CTRL2, start_force); // clear start_en
            mmio.writeReg(P.SAR_TOUCH_CTRL2, start_force | start_en); // pulse → trigger
            while (mmio.readReg(P.SAR_TOUCH_CTRL2) & meas_done == 0) {} // await the sample
            return @truncate(count.get(mmio.readReg(out_reg)));
        }
    };
}

/// RTC main timer — the always-on 48-bit slow-clock counter in the RTC power domain
/// (it keeps running through deep sleep, unlike `CCOUNT` or `SysTimer`). Takes the
/// RTC_CNTL namespace (`regs.RTC_CNTL`). A read is a latch handshake: pulse
/// `TIME_UPDATE`, wait for `TIME_VALID`, then read `TIME0` (low 32) + `TIME1` (high
/// 16) so the halves can't tear. Counts at the RTC slow clock (~150 kHz default).
/// Field bits from the SVD, via reg.zig.
pub fn RtcTime(comptime P: type) type {
    return struct {
        const valid = reg.bit(30); // TIME_UPDATE.TIME_VALID
        const update = reg.bit(31); // TIME_UPDATE.TIME_UPDATE — request a latch
        const hi_value = reg.Field(0, 16); // TIME1.TIME_HI holds count bits [47:32]

        /// Coherent 48-bit RTC counter value as a u64.
        pub inline fn now() u64 {
            mmio.writeReg(P.TIME_UPDATE, update);
            while (mmio.readReg(P.TIME_UPDATE) & valid == 0) {} // await a coherent snapshot
            const hi = hi_value.get(mmio.readReg(P.TIME1));
            const lo = mmio.readReg(P.TIME0);
            return (@as(u64, hi) << 32) | lo;
        }
    };
}

/// Deep sleep with an RTC-timer wakeup (ESP32). `timerWakeup(ticks)` reads the
/// current RTC time (reusing `RtcTime`), programs the wakeup alarm `ticks` RTC
/// slow-clock ticks ahead, enables the timer wakeup source and sets `SLEEP_EN` — the
/// chip powers down and resets on wake (so it does not return). Takes the RTC_CNTL
/// namespace. **Build-only:** a live deep sleep powers the chip down (which the QEMU
/// boot test would flag), and a production sleep also configures the RTC power
/// domains. Pairs with `ResetReason`; field bits from the SVD, via reg.zig.
pub fn DeepSleep(comptime P: type) type {
    return struct {
        const timer_trigger = reg.bit(3); // the RTC-timer source within WAKEUP_ENA
        const wakeup_ena = reg.Field(11, 11); // WAKEUP_STATE.WAKEUP_ENA
        const vector_sel = reg.bit(13); // RESET_STATE.PROCPU_STAT_VECTOR_SEL
        const slp_hi = reg.Field(0, 16); // SLP_TIMER1.SLP_VAL_HI (alarm bits [47:32])
        const alarm_en = reg.bit(16); // SLP_TIMER1.MAIN_TIMER_ALARM_EN
        const slp_wakeup = reg.bit(29); // STATE0.SLP_WAKEUP
        const sleep_en = reg.bit(31); // STATE0.SLEEP_EN

        /// Enter deep sleep, waking ~`wake_ticks` RTC slow-clock ticks later. Does
        /// not return — the chip powers down and resets on wake.
        pub inline fn timerWakeup(wake_ticks: u64) noreturn {
            const alarm = RtcTime(P).now() +% wake_ticks;
            mmio.writeReg(P.SLP_TIMER0, @truncate(alarm));
            mmio.writeReg(P.SLP_TIMER1, slp_hi.set(@truncate(alarm >> 32)) | alarm_en);
            mmio.writeReg(P.RESET_STATE, mmio.readReg(P.RESET_STATE) | vector_sel);
            mmio.writeReg(P.WAKEUP_STATE, wakeup_ena.set(timer_trigger));
            mmio.writeReg(P.STATE0, sleep_en | slp_wakeup);
            mmio.halt(); // the chip powers down; halt is the panic-free fallback
        }
    };
}

/// HMAC-SHA256 accelerator (ESP32-S2/-S3) — keyed from an eFuse key block (the key
/// never leaves the chip). `configure(purpose, key_block)` selects the key and
/// purpose and returns `false` on a key-purpose mismatch; `hashBlock` feeds one
/// caller-prepared 512-bit message block and reads the 256-bit MAC. Takes the
/// peripheral namespace (`regs.HMAC`). **Build-only:** the key comes from eFuse,
/// which QEMU leaves blank (so a live run reports a key error) — this programs the
/// documented register sequence and runs on real silicon with a programmed key.
/// `[*]` indexing keeps the result read panic-free.
pub fn Hmac(comptime P: type) type {
    return struct {
        /// `SET_PARA_PURPOSE` = "to user": supply a message and read the MAC.
        pub const to_user = 8;
        const busy = reg.bit(0); // QUERY_BUSY.BUSY_STATE
        const key_err = reg.bit(0); // QUERY_ERROR.QUERY_CHECK (key-purpose mismatch)

        inline fn waitIdle() void {
            while (mmio.readReg(P.QUERY_BUSY) & busy != 0) {}
        }
        /// Select eFuse `key_block` (0..5) for `purpose` (e.g. `to_user`). Returns
        /// `false` if the key's programmed eFuse purpose doesn't match.
        pub inline fn configure(purpose: u8, key_block: u8) bool {
            mmio.writeReg(P.SET_START, 1);
            waitIdle();
            mmio.writeReg(P.SET_PARA_PURPOSE, purpose);
            mmio.writeReg(P.SET_PARA_KEY, key_block);
            mmio.writeReg(P.SET_PARA_FINISH, 1);
            return mmio.readReg(P.QUERY_ERROR) & key_err == 0;
        }
        /// Feed one 512-bit message block (the only/last block) and return the
        /// 256-bit HMAC as 8 words. Call after a successful `configure`.
        pub inline fn hashBlock(block: [16]u32) [8]u32 {
            inline for (0..16) |i| mmio.writeReg(P.WR_MESSAGE_MEM_0 + i * 4, block[i]);
            mmio.writeReg(P.SET_MESSAGE_ONE, 1);
            waitIdle();
            var out: [8]u32 = undefined;
            const o: [*]u32 = &out;
            inline for (0..8) |i| o[i] = mmio.readReg(P.RD_RESULT_MEM_0 + i * 4);
            mmio.writeReg(P.SET_RESULT_FINISH, 1);
            return out;
        }
    };
}

/// Pulse Counter (PCNT) unit (ESP32) — counts edges on an input signal (rotary
/// encoders, frequency/event counting). Configures channel 0 to increment the
/// 16-bit signed counter on each positive edge. Pass the unit's `UNIT_n_CONF0_0`
/// and `U_CNT_n` registers, the shared `CTRL_0` register and the unit number
/// (0..7) — its reset/pause bits in CTRL are at `2·unit` / `2·unit+1`. **Build-only:**
/// QEMU models no PCNT, and the input still needs routing to a pad via the GPIO
/// matrix. CONF0's count-mode field and CTRL's per-unit bits come from the chip
/// register map (the vendored SVD omits them); expressed through reg.zig.
pub fn Pcnt(comptime conf0_reg: u32, comptime ctrl_reg: u32, comptime cnt_reg: u32, comptime unit: u3) type {
    return struct {
        const pos_mode = reg.Field(18, 2); // CONF0.CH0_POS_MODE — action on a +edge
        const increment = 1; //   1 = count up
        const cnt_rst = reg.bit(@as(u5, unit) * 2); // CTRL: reset this unit's counter
        const cnt_pause = reg.bit(@as(u5, unit) * 2 + 1); // CTRL: pause this unit
        const value = reg.Field(0, 16); // U_CNT_n — 16-bit signed count

        /// Configure channel 0 to count up on each positive edge, then reset + run.
        pub inline fn init() void {
            mmio.writeReg(conf0_reg, pos_mode.set(increment));
            mmio.writeReg(ctrl_reg, (mmio.readReg(ctrl_reg) | cnt_rst) & ~cnt_pause); // hold at 0, unpaused
            mmio.writeReg(ctrl_reg, mmio.readReg(ctrl_reg) & ~cnt_rst); // release reset → counting
        }
        /// Current counter value (16-bit, signed).
        pub inline fn count() i16 {
            return @bitCast(@as(u16, @truncate(value.get(mmio.readReg(cnt_reg)))));
        }
    };
}

/// CPU stack-overflow monitor via the ASSIST_DEBUG peripheral (ESP32-S3, core 0).
/// `watchStack(low, high)` arms the SP-spill monitor: the hardware records a
/// violation (and the offending PC) if the stack pointer leaves `[low, high]` — a
/// stack overflow or underflow — which `tripped()` reports. Takes the peripheral
/// namespace (`regs.ASSIST_DEBUG`). **Build-only:** QEMU doesn't model ASSIST_DEBUG.
/// Field bits from the SVD, via reg.zig.
pub fn StackMonitor(comptime P: type) type {
    return struct {
        const spill = reg.bit(8) | reg.bit(9); // SP_SPILL_MIN | SP_SPILL_MAX

        /// Arm the SP monitor against `[low, high]` (a spill outside flags a fault).
        pub inline fn watchStack(low: u32, high: u32) void {
            mmio.writeReg(P.CPU_0_SP_MIN, low);
            mmio.writeReg(P.CPU_0_SP_MAX, high);
            mmio.writeReg(P.CPU_0_MONTR_ENA, mmio.readReg(P.CPU_0_MONTR_ENA) | spill);
        }
        /// True if the SP has spilled out of the watched range since the last clear.
        pub inline fn tripped() bool {
            return mmio.readReg(P.CPU_0_INTR_RAW) & spill != 0;
        }
        /// The PC recorded at the violation (valid once `tripped`).
        pub inline fn faultPc() u32 {
            return mmio.readReg(P.CPU_0_SP_PC);
        }
        /// Clear a recorded violation.
        pub inline fn clear() void {
            mmio.writeReg(P.CPU_0_INTR_CLR, spill);
        }
    };
}

/// SPI-flash read through the chip's ROM (`esp_rom_spiflash_read`) — the same entry
/// the storage stacks use, so no SPI-flash controller driver is needed. Pass the
/// ROM function's address for your chip (ESP32: `0x4006_2ED8`). `read(src, words)`
/// copies `words.len` 32-bit words from flash byte-offset `src` into `words` and
/// returns true on success. Read-only by design (erase/write can brick a running
/// image). **Build-only:** the ROM address is fixed per chip/ROM revision, and the
/// QEMU `-kernel` flow has no flash image to read.
pub fn FlashRom(comptime read_addr: u32) type {
    return struct {
        // ROM ABI: int esp_rom_spiflash_read(u32 src, u32 *dest, i32 len_bytes) → 0 = OK.
        const readFn: *const fn (u32, [*]u32, i32) callconv(.c) i32 = @ptrFromInt(read_addr);

        /// Read `words.len` 32-bit words from flash offset `src`; true on success.
        pub inline fn read(src: u32, words: []u32) bool {
            const len: i32 = @bitCast(@as(u32, @truncate(words.len *% 4)));
            return readFn(src, words.ptr, len) == 0;
        }
    };
}

/// Critical section — briefly mask interrupts so a multi-step register sequence is
/// atomic against an interrupt handler. `enter()` raises the interrupt level
/// (Xtensa `rsil`, or the RISC-V `mstatus.MIE` bit) and returns a token; pass it
/// back to `exit()` to restore. This firmware is poll-based (it enables no
/// interrupts), so this is here for code that does. Arch-selected at comptime.
pub const Critical = struct {
    /// Mask interrupts; returns the prior state to give back to `exit`.
    pub inline fn enter() u32 {
        return switch (builtin.cpu.arch) {
            .xtensa => asm volatile ("rsil %[t], 5"
                : [t] "=r" (-> u32),
            ),
            else => asm volatile ("csrrci %[t], mstatus, 8" // clear mstatus.MIE
                : [t] "=r" (-> u32),
            ),
        };
    }
    /// Restore the interrupt state captured by `enter`.
    pub inline fn exit(token: u32) void {
        switch (builtin.cpu.arch) {
            .xtensa => asm volatile ("wsr.ps %[t]\n rsync"
                :
                : [t] "r" (token),
            ),
            else => asm volatile ("csrw mstatus, %[t]"
                :
                : [t] "r" (token),
            ),
        }
    }
};

/// GPIO matrix — route any peripheral signal to/from any pad. This is the
/// interconnect the "route … to a pad" notes on the bus drivers refer to: a
/// peripheral's output signal can be driven onto a chosen pad, and a pad can be fed
/// into a peripheral's input signal, in software. The config-register addresses are
/// comptime (so the MMIO stays panic-free, like the pin drivers); pass the pad's
/// `GPIO.FUNC_OUT_SEL_CFG_<n>` to drive a signal out, or an input signal's
/// `GPIO.FUNC_IN_SEL_CFG_<m>` to capture a pad. Signal indices come from the chip's
/// signal map. **Build-only:** the routing has no QEMU-observable effect. Field bits
/// from the SVD, via reg.zig.
pub const GpioMatrix = struct {
    // FUNCn_OUT_SEL_CFG
    const out_sel = reg.Field(0, 9); // peripheral output signal index → this pad
    const oe_sel = reg.bit(10); // drive the pad's output-enable from the signal
    // FUNCm_IN_SEL_CFG
    const in_sel = reg.Field(0, 6); // pad number → this input signal
    const sig_in_sel = reg.bit(7); // take the signal through the matrix (not direct IO)

    /// Drive peripheral output `signal` out the pad whose `FUNC_OUT_SEL_CFG` register
    /// is `out_cfg_reg`, enabling the pad's output from that signal.
    pub inline fn connectOutput(comptime out_cfg_reg: u32, signal: u9) void {
        mmio.writeReg(out_cfg_reg, out_sel.set(signal) | oe_sel);
    }
    /// Feed `pad` into the peripheral input whose `FUNC_IN_SEL_CFG` register is
    /// `in_cfg_reg`, routing it through the matrix.
    pub inline fn connectInput(comptime in_cfg_reg: u32, pad: u6) void {
        mmio.writeReg(in_cfg_reg, in_sel.set(pad) | sig_in_sel);
    }
};
