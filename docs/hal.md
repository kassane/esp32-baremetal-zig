# HAL reference (`src/hal.zig`)

A small register driver layer over `mmio` (imported as `hal`):

- `hal.Output(enable, out, set, clr, mask)` — a push-pull pin over the atomic
  W1TS/W1TC registers (`init`/`setHigh`/`setLow`/`setLevel`/`toggle`/`isSetHigh`). It's
  **comptime-parameterized** on the register addresses so the stores keep fixed,
  aligned, non-null targets and emit no alignment/null panic (which wouldn't
  link). `hal.Level` is the `.low`/`.high` enum (with `not`).
- `hal.Input(in_reg, mask)` — a read-only pin reporting the level latched in the
  GPIO bank's IN register (`isHigh`/`isLow`/`level`). The esp32 example reports
  GPIO0's level over UART; the `button` example mirrors the GPIO0 boot button
  onto GPIO2's LED.
  (In hot read loops use the boolean `isHigh`, not the `Level` enum — a `switch`
  on it emits a corrupt-value safety check that doesn't link.)
- `hal.Delay(cpu_hz)` — a cycle-accurate blocking delay (`cycles`/`micros`/
  `millis`) built on the Xtensa core cycle counter (`rsr.ccount`). `rsr.ccount`
  is an optimization barrier (like the `ee.*` PIE ops), so it only un-elides
  safety checks the surrounding code has already eliminated — which is why
  `Output` must keep its addresses comptime. Verified in QEMU: the cycle counter
  advances and the demos blink at the expected `cpu_hz`-scaled rate.
- `hal.Timer(config, update, lo)` — a Timer Group general-purpose up-counter (a
  monotonic time base independent of `CCOUNT`); `start(divider)` enables it and
  `ticks()` latches + reads the low 32 bits. The esp32 demo prints its uptime.
- `hal.SysTimer(P)` — the ESP32-S3 system timer (`regs.SYSTIMER`), the SoC's
  always-on 52-bit monotonic counter; `count()` returns a coherent 64-bit value
  via the hardware UPDATE/VALUE_VALID latch handshake. QEMU emulates it, so
  `examples/systimer` prints the advancing count under `zig build demo`.
- `hal.Uart(fifo, status)` — full-duplex UART: TX (`writeByte`/`write`) over the
  FIFO plus RX (`readByte` → `?u8`, `rxAvailable`) gated on `STATUS.RXFIFO_CNT`.
- `hal.Rng(data)` — reads a 32-bit hardware-RNG sample; the esp32 demo prints one.
- `hal.Sha(digest_words, ...)` / `hal.Aes(key_bits, ...)` — single-block SHA
  (`digest_words` 5 = SHA-1, 8 = SHA-256) and AES-ECB (`key_bits` 128/192/256) on
  the hardware accelerators, algorithm selected at comptime; the esp32 demo checks
  SHA-1, SHA-256, AES-128 *and* AES-256 against `std.crypto`'s comptime reference
  (verified live in QEMU).
- `hal.Efuse(lo, hi)` — reads the 48-bit factory base MAC from eFuse (the
  identity Wi-Fi/Bluetooth/Ethernet derive from), assembled big-endian. eFuse is
  one of the blocks the Espressif QEMU fork emulates, so the `examples/efuse`
  reader runs under `zig build demo` — though QEMU's eFuse is unprogrammed, so it
  reads back all-zero there; real silicon returns the unique factory address.
- `hal.Pwm(timer, conf0, conf1, hpoint, duty)` — LEDC PWM timer + channel
  (see `examples/pwm/`). **Build-only**: QEMU doesn't model LEDC, and routing
  the channel to a pad via the GPIO matrix is left to the application.
- `hal.I2c(P)` — I2C master, single-shot blocking `write` and `read`; takes the
  generated peripheral namespace (e.g. `regs.I2C0`) since it spans ~13 registers
  (see `examples/i2c/`). **Build-only**: QEMU models no I2C controller, so it links
  and runs on hardware but has no emulator activity (route SCL/SDA to pads first).
- `hal.Rmt(conf0, conf1, data, apb_conf)` — RMT transmitter: streams 32-bit
  symbols (two timed levels each) out a channel for IR remote protocols
  (NEC/RC5) or WS2812 timing (see `examples/rmt/`). **Build-only**: QEMU models no
  RMT (route the channel to an IR-LED pad, with a 38 kHz carrier, on hardware).
- `hal.Ws2812(conf0, conf1, data, apb_conf)` — WS2812/NeoPixel addressable RGB
  built on `Rmt`: encodes a pixel's 24 bits (G-R-B, MSB first) as RMT symbols, the
  datasheet bit timing folded from nanoseconds to source-clock ticks at comptime
  (see `examples/ws2812/`). **Build-only**: QEMU models no RMT (route the channel
  to the LED's data pad on hardware).
- `hal.Spi(P)` — SPI master, half-duplex single transfer (≤ 64 bytes / data-buffer
  load): `write` clocks bytes out MOSI, `read` clocks them in over MISO; takes the
  peripheral namespace (e.g. `regs.SPI2`) (see `examples/spi/`). **Build-only**:
  QEMU models no SPI controller (route CS/CLK/MOSI/MISO to pads first).
- `hal.Rsa(P, words)` — RSA modular exponentiation (`base^exp mod modulus`), the
  core of RSA sign/verify, for `words`×32-bit operands (512-bit increments). The
  caller supplies the Montgomery constants (`m' = -M⁻¹ mod 2³²`,
  `r = 2^(2·bits) mod M`), so the driver computes nothing in software.
  **QEMU-verified**: `examples/rsa` runs a known-answer vector — 2² mod (2⁵¹²−1) = 4,
  a modulus for which both constants reduce to 1 — live under `zig build demo`.
- `hal.Hmac(P)` — HMAC-SHA256 accelerator (ESP32-S2/-S3) keyed from an eFuse block
  (the key never leaves the chip): `configure(purpose, key_block)` selects the key,
  `hashBlock` feeds a 512-bit message block and reads the 256-bit MAC (see
  `examples/hmac/`, which cross-checks it against `std.crypto` on hardware).
  **Build-only**: the key lives in eFuse, which QEMU leaves blank.
- `hal.Pcnt(conf0, ctrl, cnt, unit)` — Pulse Counter unit (ESP32): channel 0
  increments a 16-bit signed counter on each positive edge (rotary encoders,
  frequency/event counting); `count()` reads it (see `examples/pcnt/`). **Build-only**:
  QEMU models no PCNT. CONF0's count-mode field and CTRL's per-unit reset/pause bits
  are from the chip register map (the vendored SVD omits them).
- `hal.StackMonitor(P)` — CPU stack-overflow monitor via ASSIST_DEBUG (ESP32-S3):
  `watchStack(low, high)` arms the SP-spill monitor so the hardware records a
  violation (and the PC) if the stack pointer leaves the range; `tripped()` /
  `faultPc()` / `clear()` read and reset it (see `examples/stack_monitor/`).
  **Build-only**: QEMU doesn't model ASSIST_DEBUG.
- `hal.FlashRom(read_addr)` — SPI-flash read through the chip ROM
  (`esp_rom_spiflash_read`, e.g. `0x4006_2ED8` on ESP32): `read(src, words)` copies
  words from a flash offset — the entry the storage stacks use, so no flash-controller
  driver is needed (see `examples/flash/`). Read-only (erase/write can brick a running
  image). **Build-only**: the ROM address is fixed per chip/ROM revision.
- `hal.Critical` — critical section: `enter()` masks interrupts (Xtensa `rsil`, or
  the RISC-V `mstatus.MIE` bit) and returns a token; `exit(token)` restores it,
  making a register sequence atomic against an interrupt handler (see
  `examples/critical/`, QEMU-verified). The firmware enables no interrupts itself —
  this is for code that does.
- `hal.Twai(P)` — TWAI (CAN 2.0) controller: transmit a standard-ID data frame on
  the SJA1000-compatible peripheral (`regs.TWAI0`) (see `examples/twai/`).
  **Build-only**: a live bus needs TX/RX routed to pads + an external CAN transceiver.
- `hal.Mcpwm(P)` — motor-control PWM: edge-aligned output on timer 0 / operator 0 /
  generator A (`regs.MCPWM0`), duty = `cmp/period` (see `examples/mcpwm/`).
  **Build-only**: QEMU models no MCPWM (route the operator output to a pad first).
- `hal.I2s(P)` — I2S master TX in single-data mode (constant sample, no DMA;
  Philips framing) on `regs.I2S0` (see `examples/i2s/`). **Build-only**: QEMU models
  no I2S; the DMA-fed streaming path is a larger future piece.
- `hal.Dac(pad_dac_reg)` — 8-bit analog output on an RTC DAC pad (`PAD_DAC_0` =
  DAC1/GPIO25, `PAD_DAC_1` = DAC2/GPIO26); `write(level)` drives 0..Vref over the
  software DAC output path (see `examples/dac/`). **Build-only**: QEMU has no
  observable analog output.
- `hal.Adc(meas_reg)` — SAR ADC software one-shot (`SAR_MEAS_START1` = ADC1,
  `SAR_MEAS_START2` = ADC2): `read(channel)` triggers a conversion and returns the
  raw value (see `examples/adc/`). **Build-only**: QEMU has no analog input, and a
  real reading also needs attenuation / SAR clock / RTC power configured.
- `hal.UsbSerial(ep1, ep1_conf)` — USB Serial/JTAG CDC-ACM console TX (the default
  USB console on ESP32-S3/-C3); `write` fills the IN FIFO (gated on
  `SERIAL_IN_EP_DATA_FREE`) and flushes via `WR_DONE` (see `examples/usb_serial/`).
  **Build-only**: needs a USB host, which QEMU doesn't provide.
- `hal.TempSensor(ctrl_reg)` — on-chip temperature sensor (ESP32-S2/-S3,
  `regs.SENS.SAR_TSENS_CTRL`): `read(div)` powers it up and returns the raw 8-bit
  value (→ °C via a per-chip curve) (see `examples/tsens/`). **Build-only**: QEMU
  has no thermal model.
- `hal.IoMux(pad_reg)` — pad electrical config (pull-up/down, input-enable, drive
  strength) for one pad (`regs.IO_MUX.GPIO0`, …), complementing `Output`/`Input`
  (see `examples/iomux/`). **Build-only**: the pull effect isn't QEMU-observable.
- `hal.Watchdog(P)` — Timer-Group watchdog (the inverse of `init.disableWatchdogs`):
  `start(prescale, timeout)` arms a stage-0 system reset and `feed()` postpones it,
  guarded by the hardware write-protect key (`regs.TIMG0`, see `examples/watchdog/`).
  **Build-only**: a live WDT resets the chip, which the QEMU boot test would flag.
- `hal.ResetReason(reset_state_reg)` — reads the PRO-CPU reset cause from
  `regs.RTC_CNTL.RESET_STATE` (power-on / software / watchdog / brownout / deep-sleep
  codes), the boot-time branch every firmware needs (see `examples/reset_reason/`).
- `hal.softwareReset(options0_reg)` — triggers an immediate full software reset via
  `regs.RTC_CNTL.OPTIONS0` (does not return); pairs with `ResetReason` (see
  `examples/sw_reset/`). **Build-only**: a live reset restarts the chip.
- `hal.RtcStore(store_reg)` — read/write an RTC retention scratch word
  (`regs.RTC_CNTL.STORE0` … `STORE3`) that survives deep sleep and every reset bar
  power-on; pairs with `ResetReason`/`softwareReset` for boot counters and sleep
  state (see `examples/rtc_store/`). QEMU backs the register, so the round-trip runs
  under `zig build demo`.
- `hal.RtcTime(P)` — the always-on 48-bit RTC main timer (`regs.RTC_CNTL`), which
  keeps running through deep sleep (unlike `CCOUNT`/`SysTimer`); `now()` returns a
  coherent `u64` via the `TIME_UPDATE`/`TIME_VALID` latch handshake. QEMU advances
  it, so `examples/rtc_time` prints the climbing count under `zig build demo`.
- `hal.DeepSleep(P)` — deep sleep with an RTC-timer wakeup: `timerWakeup(ticks)`
  reads the RTC timer (reusing `RtcTime`), programs the wakeup alarm `ticks` ahead,
  enables the timer wakeup source and powers the chip down (does not return; it
  resets on wake). Pairs with `ResetReason` (see `examples/deep_sleep/`).
  **Build-only**: a live deep sleep powers the chip down.
- `hal.GpioEdge(pin_reg, mask, status_reg, clr_reg)` — poll-based edge detection:
  latches rising/falling edges in the GPIO event-status register so a loop catches
  transitions without interrupts (`takeEdge`), complementing `Input` (see
  `examples/gpio_edge/`).
- `hal.ClockGate(clk_en_reg, rst_en_reg, mask)` — ungate (`enable`) and reset
  (`reset`) a peripheral's bus clock through the system clock-control registers
  (`regs.DPORT.PERIP_CLK_EN` / `PERIP_RST_EN` on ESP32), the explicit form of the
  clock bring-up the boot ROM performs for the peripherals the other drivers assume
  are already running (see `examples/clock_gate/`). **Build-only**.
- `hal.Brownout(brown_out_reg)` — RTC brownout detector (`regs.RTC_CNTL.BROWN_OUT`):
  `arm(level)` enables detection at trip `level` (0..7) and resets the chip on a
  supply sag, preserving the register's aliased RTC-memory-CRC bits; `detected()`
  reads the live flag (see `examples/brownout/`). **Build-only**: QEMU has no analog
  supply model to trip it.
- `hal.Touch(P, pad_reg, nr, out_reg)` — capacitive touch sensor (ESP32):
  software-forces a measurement of touch pad `nr` and returns its raw count (lower
  = touched). Pads share result registers two-up (pad 2n/2n+1 → `SAR_TOUCH_OUT_n`,
  even in the low half / odd in the high), so the caller passes the pad's
  `RTC_IO.TOUCH_PADn`, its number and the matching `SAR_TOUCH_OUT_*` (see
  `examples/touch/`). **Build-only**: QEMU has no touch model.

Every driver is **comptime-parameterized on its register addresses** (the I2C
driver on the peripheral namespace), so the MMIO accesses stay provably
aligned/non-null and emit no panic path. Bit fields are expressed through the
comptime helpers in `src/reg.zig` (`reg.bit(n)`, `reg.Field(lsb, width)`), so the
drivers name each field (`divider.set(div)`, not `value << 13`) instead of
hand-shifting magic numbers — and it all folds to the same code at comptime.

## Connectivity and wireless

The Wi-Fi and Bluetooth radios are intentionally out of scope. Their RF, PHY and
MAC layers are driven by closed-source vendor firmware blobs — the same reason
the QEMU fork does not emulate them — so a from-scratch, blob-free register HAL
cannot bring up the radio itself. Drawing that boundary explicitly is a design
decision, not a missing feature.

What the HAL does provide is the register-level groundwork a connectivity stack
builds on, plus the wireless protocols that *are* pure registers:

- the 48-bit factory MAC every radio interface derives from (`hal.Efuse`);
- the hardware RNG a TLS layer seeds from (`hal.Rng`);
- the wired buses that peripherals hang off (`hal.I2c`, `hal.Spi`, `hal.I2s`,
  plus the LEDC and MCPWM timers); and
- single-wire, line-coded protocols clocked out of the RMT peripheral —
  infrared remote control (`hal.Rmt`) and WS2812/NeoPixel addressable RGB
  (`hal.Ws2812`).
