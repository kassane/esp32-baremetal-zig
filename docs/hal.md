# HAL reference (`src/hal.zig`)

A small register driver layer over `mmio` (imported as `hal`):

| Driver | What it does | Chip(s) | Status |
|---|---|---|---|
| `Output` / `Input` / `Level` | push-pull / read-only GPIO pin over atomic W1TS/W1TC | any | QEMU-verified |
| `GpioEdge(pin, mask, status, clr)` | poll-based rising/falling edge latch | any | build-only |
| `IoMux(pad)` | pad pull / input-enable / drive-strength config | any | build-only |
| `Delay(cpu_hz)` | cycle-accurate busy delay (Xtensa `CCOUNT` / RISC-V `cycle`) | any | QEMU-verified |
| `Timer(cfg, upd, lo)` | Timer-Group free-running up-counter | any | QEMU-verified |
| `SysTimer(P)` | always-on 52-bit system timer | ESP32-S3 | QEMU-verified |
| `RtcTime(P)` | always-on 48-bit RTC main timer (survives sleep) | ESP32 | QEMU-verified |
| `Uart(fifo, status)` | full-duplex UART (TX + RX FIFO) | any | QEMU-verified |
| `Rng(data)` | hardware RNG sample | any | QEMU |
| `Efuse(lo, hi)` | 48-bit factory base-MAC from eFuse | any | QEMU (blank on emu) |
| `Sha(...)` | single-block SHA-1 / SHA-256 | ESP32 | QEMU-verified vs `std.crypto` |
| `Aes(...)` | AES-128/192/256 ECB block | ESP32 | QEMU-verified vs `std.crypto` |
| `Rsa(P, words)` | RSA modular exponentiation | ESP32 | QEMU-verified (known-answer) |
| `Hmac(P)` | HMAC-SHA256, eFuse-keyed | ESP32-S2/-S3 | build-only |
| `I2c(P)` | I2C master `write` + `read` | any | build-only |
| `Spi(P)` | SPI master `write` (MOSI) + `read` (MISO) | any | build-only |
| `I2s(P)` | I2S master TX, single-data mode | any | build-only |
| `Rmt(...)` | RMT symbol stream (IR remote, WS2812 timing) | ESP32 | build-only |
| `Ws2812(...)` | WS2812 / NeoPixel addressable RGB (built on `Rmt`) | ESP32 | build-only |
| `Pwm(...)` | LEDC PWM timer + channel | any | build-only |
| `Mcpwm(P)` | motor-control PWM (edge-aligned) | any | build-only |
| `Pcnt(...)` | pulse counter (encoders / frequency) | ESP32 | build-only |
| `Dac(pad)` | 8-bit RTC DAC analog output | ESP32 | build-only |
| `Adc(meas)` | SAR ADC software one-shot | any | build-only |
| `TempSensor(ctrl)` | on-chip temperature sensor | ESP32-S2/-S3 | build-only |
| `Touch(...)` | capacitive touch pad read | ESP32 | build-only |
| `UsbSerial(ep1, conf)` | USB Serial/JTAG CDC-ACM console TX | ESP32-S3 | build-only |
| `Twai(P)` | TWAI (CAN 2.0) standard-frame TX | any | build-only |
| `ClockGate(clk, rst, mask)` | peripheral bus-clock enable + reset | any | build-only |
| `Watchdog(P)` | Timer-Group watchdog (arm / feed) | any | build-only |
| `ResetReason(reg)` | PRO-CPU reset cause | any | QEMU |
| `softwareReset(reg)` | immediate full software reset | any | build-only |
| `RtcStore(reg)` | RTC retention scratch word read/write | any | QEMU-verified |
| `Brownout(reg)` | supply brownout detector | ESP32 | build-only |
| `DeepSleep(P)` | deep sleep with RTC-timer wakeup | ESP32 | build-only |
| `StackMonitor(P)` | stack-overflow monitor (ASSIST_DEBUG) | ESP32-S3 | build-only |
| `FlashRom(addr)` | SPI-flash read via the chip ROM | ESP32 | build-only |
| `Critical` | interrupt-masking critical section | any | QEMU-verified |

*"any" = register-parameterized, so it works on any chip exposing those registers.
"QEMU-verified" runs and is checked in QEMU; "build-only" is compiled and matched to
the SVD/TRM but exercised on real hardware. The `///` doc comments in `src/hal.zig`
carry the full per-driver detail (registers, caveats).*

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
