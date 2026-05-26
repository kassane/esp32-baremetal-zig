# Porting status

Where this HAL stands against the peripheral surface of the upstream Rust HAL it
tracks. The guiding rule: a driver ships only when it is **grounded in the
SVD/TRM register layout** and either **verified in QEMU** or a **faithful
register sequence** that runs on hardware. Drivers that can't be made correct
without on-silicon validation are listed as deferred rather than guessed at.

## Implemented (`src/hal.zig`, unless noted)

| Peripheral | Driver(s) here | Verification |
|---|---|---|
| GPIO | `Output` / `Input` / `GpioEdge` / `IoMux` | QEMU (ESP32) |
| Timer Group | `Timer`, `Watchdog`, `init.disableWatchdogs` | QEMU (boot) |
| System Timer | `SysTimer` | QEMU (ESP32-S3) |
| UART | `Uart` (TX + RX) | QEMU |
| RNG | `Rng` | QEMU |
| SHA | `Sha` (SHA-1 / SHA-256) | QEMU, checked vs `std.crypto` |
| AES | `Aes` (128 / 192 / 256, ECB) | QEMU, checked vs `std.crypto` |
| RSA | `Rsa` (modexp) | build-only |
| eFuse | `Efuse` (factory MAC) | QEMU (reads blank silicon) |
| I2C | `I2c` (master write + read) | build-only |
| SPI | `Spi` (master write + read) | build-only |
| I2S | `I2s` (master TX, single-data) | build-only |
| LEDC | `Pwm` | build-only |
| MCPWM | `Mcpwm` | build-only |
| RMT | `Rmt`, `Ws2812` | build-only |
| ADC / DAC | `Adc`, `Dac` | build-only |
| Temp sensor | `TempSensor` | build-only |
| TWAI (CAN) | `Twai` | build-only |
| USB Serial/JTAG | `UsbSerial` | build-only |
| System (clocks) | `ClockGate` | build-only |
| RTC control | `ResetReason`, `softwareReset`, `RtcStore`, `Brownout` | `RtcStore` QEMU-verified; rest build-only |
| DSP (`src/dsp.zig`) | `addSatS16`, `dotProductS16`, `firS16`, `fft` | QEMU (PIE + scalar) |

"Build-only" means QEMU does not model the peripheral, so the driver is compiled
(Debug + ReleaseSmall) and matched to the SVD/TRM register layout, but exercised
only on real hardware. See [hal.md](hal.md) for the per-driver detail.

## Out of scope (by design)

A from-scratch, blob-free, poll/blocking bare-metal HAL deliberately stops at the
following — they require vendor firmware blobs or subsystems this project does not
attempt:

- **Wi-Fi / Bluetooth / 802.15.4 radio** — the RF, PHY and MAC layers are closed
  vendor blobs (also why the QEMU fork does not emulate them). See the
  connectivity section in [hal.md](hal.md).
- **DMA (GDMA/PDMA)** — the descriptor engine the streaming peripheral paths
  (I2S/SPI/parallel) build on.
- **Interrupt controller / async executor** — the HAL is poll/blocking by design;
  `GpioEdge` is the poll-based stand-in for pin interrupts.
- **Ethernet (EMAC)** — needs an external PHY and a large MAC driver.
- **USB OTG, LCD/camera, parallel I/O, PSRAM** — large peripheral subsystems
  outside the register-HAL scope.

## Deferred (pure-register, not yet shipped)

These are register-only and in scope in principle, but can't be made
**verifiably** correct here — QEMU does not model them, and their register
sequences are intricate enough that on-silicon validation is required before they
meet the bar above:

- **Capacitive touch** — the RTC touch FSM plus a per-pad result-register mapping
  that needs hardware to confirm.
- **RTC deep sleep / wakeup** — a long power-domain configuration sequence with no
  QEMU model to exercise it.
- **HMAC** — keyed from an eFuse block, so not demonstrable on QEMU's blank eFuse.
- **PCNT (pulse counter)** — the vendored ESP32 SVD omits the counter-mode fields
  (its command-register names collide), so it can't be driven correctly from the
  generated registers.
- **ECC** — not present in the Xtensa esp-pacs SVDs (a RISC-V-chip peripheral).
- **ETM, assist-debug, trace** — niche debug/interconnect blocks; pure-register but
  unverifiable here.
