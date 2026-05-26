# esp32-baremetal-zig

A bare-metal hardware abstraction layer for the Xtensa ESP32 family, written in
pure Zig — no vendor SDK, no RTOS, no libc, no C. Firmware boots directly on
ESP32, ESP32-S2 and ESP32-S3 from a generated linker script, reaches the silicon
through SVD-generated register definitions, and is exercised in the Espressif
QEMU fork on every CI run.

Three reference applications anchor the HAL: the ESP32 verifies its hardware
SHA-1/256 and AES-128/256 engines against `std.crypto` live in QEMU, the ESP32-S2
runs a fixed-point FFT spectrum analyzer, and the ESP32-S3 drives its PIE/SIMD
vector unit.

### Highlights

- **Generated register access.** `tools/svd2zig.zig` compiles vendored CMSIS-SVD
  into a typed `@import("regs")` at build time — `regs.GPIO.OUT_W1TS`, never a
  hardcoded address.
- **A comptime register HAL.** Every peripheral driver is parameterized on its
  register addresses, so each MMIO access is provably aligned and non-null and
  emits no panic path on this backend. Bit fields are named via `src/reg.zig`,
  not hand-shifted.
- **Fixed-point DSP.** Saturating add, dot product, FIR and a radix-2 Q15 FFT,
  with ESP32-S3 PIE vector kernels selected at comptime and a scalar fallback.
- **Freestanding-safe runtime.** Watchdogs are cleared at boot; a custom panic
  handler and a `std.log` backend render over UART without pulling in `std.fmt`
  (whose formatter will not link on this backend).
- **Consumable as a package.** `zig fetch` the repository and import the modules;
  every example under `examples/` is a standalone package that does exactly that.
- **Continuously tested.** A Linux/macOS/Windows CI matrix builds every target
  and boots the QEMU-capable chips on each push.

The flash and QEMU linker scripts are generated in `build.zig` — there are no
`.ld` files to hand-edit.

---

## Toolchain requirement

This project **requires the Espressif LLVM fork of Zig** (`zig-espressif-bootstrap`).
Upstream Zig does **not** expose `esp32` / `esp32s2` / `esp32s3` CPU models in
`std.Target.xtensa.cpu`.

| Item | Value |
|---|---|
| Toolchain | `zig-espressif-bootstrap` prebuilt, tag `0.16.0-xtensa` (reports `zig version` → `0.16.0`) |
| Download | <https://github.com/kassane/zig-espressif-bootstrap/releases> |

Unpack it anywhere and put its directory on `PATH`:

```bash
curl -L -o zig.tar.xz \
  https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz
tar -xJf zig.tar.xz
export PATH="$PWD/zig-relsafe-x86_64-linux-musl-baseline:$PATH"
```

Everything else is plain `zig build` — there is no build script and no
hand-maintained linker script (both the flash and QEMU `.ld` files are
generated in `build.zig` via `b.addWriteFiles`).

---

## How to build

```bash
# Build all chips (default) → zig-out/bin/
zig build --summary all

# Build a single chip
zig build esp32
zig build esp32s2
zig build esp32s3

# Release build
zig build -Doptimize=ReleaseSmall
```

Per chip this installs an `<chip>_baremetal_zig` ELF plus a raw
`<chip>_baremetal_zig.bin` (see the flashing note below about its size).

Every example under [`examples/`](examples/) is also a standalone package: its
`build.zig` consumes the repo root (`esp32_hal`) as a local path dependency for
the shared modules, generated registers and linker scripts, so you can build one
example on its own:

```bash
cd examples/esp32 && zig build           # → zig-out/bin/esp32_baremetal_zig(.bin)
cd examples/esp32 && zig build run       # launch it in QEMU (esp32, esp32s3)
cd examples/esp32 && zig build smoke     # non-interactive boot test (esp32, esp32s3)
```

| Source | Chip | CPU | LED | Demo |
|---|---|---|---|---|
| `examples/esp32/main.zig`   | ESP32    | Xtensa LX6 | GPIO2  | hardware SHA-1/256 + AES-128/256 (vs `std.crypto`) + RNG |
| `examples/esp32s2/main.zig` | ESP32-S2 | Xtensa LX7 | GPIO18 | fixed-point FFT spectrum + TIMG timer |
| `examples/esp32s3/main.zig` | ESP32-S3 | Xtensa LX7 | GPIO48 | PIE/SIMD vector kernels |

Single-feature programs live alongside them, each its own package you build with
`cd examples/<name> && zig build`:

- `blink` (GPIO + Delay), `button` (GPIO in→out), `efuse` (factory MAC) on ESP32
- **Run in QEMU** (`zig build demo`): `efuse` (ESP32 — factory MAC over UART),
  `rtc_store` (ESP32 — RTC scratch-register round-trip) and `systimer` (ESP32-S3 —
  system-timer uptime over UART)
- **Build-only**: `pwm` (LEDC) on ESP32-S2; `i2c` (I2C master), `spi` (SPI master),
  `rmt` (IR remote transmit), `ws2812` (addressable RGB over RMT), `rsa` (RSA
  modular exponentiation), `twai` (CAN 2.0 transmit), `mcpwm` (motor-control PWM),
  `i2s` (I2S master TX), `dac` (analog output), `adc` (analog input), `iomux` (pad
  pull/drive config), `watchdog` (TIMG WDT), `reset_reason` (reset cause),
  `sw_reset` (software reset), `gpio_edge` (poll-based edge detection) and
  `clock_gate` (peripheral clock gating) on ESP32; `usb_serial` (USB CDC-ACM
  console) and `tsens` (temperature sensor) on ESP32-S3

Shared register/timing helpers live in `src/mmio.zig` (imported as `mmio`).

---

## Use it as a dependency (`zig fetch`)

The repo root is itself a Zig package (`esp32_hal`) that publishes its
building blocks — so you can pull them into your own firmware instead of copying
files around. Add it:

```bash
zig fetch --save=esp32_hal git+https://github.com/kassane/esp32-baremetal-zig
```

`--save=esp32_hal` pins the dependency key so `b.dependency("esp32_hal", .{})`
below resolves regardless of the repo's URL basename.

Then wire the modules into your `build.zig`:

```zig
const esp = b.dependency("esp32_hal", .{});

const fw = b.addExecutable(.{ .name = "fw", .root_module = b.createModule(.{
    .root_source_file = b.path("main.zig"),
    .target = b.resolveTargetQuery(.{
        .cpu_arch = .xtensa,
        .os_tag = .esp32,
        .abi = .none,
    }),
}) });
fw.root_module.addImport("mmio", esp.module("mmio"));        // MMIO + UART + memcpy
fw.root_module.addImport("hal", esp.module("hal"));          // Output / Input / Delay
fw.root_module.addImport("dsp", esp.module("dsp"));          // FFT / FIR / SIMD kernels
fw.root_module.addImport("init", esp.module("init"));        // watchdog disable
fw.root_module.addImport("panic", esp.module("panic"));      // freestanding panic
fw.root_module.addImport("startup", esp.module("startup"));  // shared reset vector
fw.root_module.addImport("regs", esp.module("esp32_regs"));  // or esp32s2_regs / esp32s3_regs
fw.setLinkerScript(esp.namedLazyPath("esp32.ld"));           // flash; or "esp32-qemu.ld"
fw.bundle_compiler_rt = false;
```

The packages under `examples/` *are* this pattern in miniature — they consume the
root over a local `.path` dependency, so copy one as a working starting point.

---

## Under the hood

### Register access (svd2zig)

Peripheral register addresses are **not** hardcoded — they're generated from
CMSIS-SVD by `tools/svd2zig.zig` (a host tool run automatically by `build.zig`).
For each chip, build.zig runs `svd2zig svd/<chip>.svd <chip>_regs.zig` and
imports the result as `@import("regs")`; firmware uses e.g. `regs.GPIO.OUT_W1TS`.

The vendored `svd/*.svd` are the **full** [esp-rs/esp-pacs](https://github.com/esp-rs/esp-pacs)
SVDs, patched with that project's `xtask` (clone esp-pacs, `cargo xtask patch
<chip>`, copy `<chip>/svd/<chip>.svd`). svd2zig handles them in full: it expands
`<dim>` arrays, flattens nested `<cluster>`s to prefixed names
(`CH_0_IN_INT_RAW`) with accumulated offsets, follows `derivedFrom` (TIMG1
inherits TIMG0), and suffixes any residual name clash — so it generates valid
Zig for **every** esp32* target (Xtensa *and* RISC-V), verified by `ast-check`.

```bash
zig build regs    # emit the generated modules into zig-out/gen/ to inspect
```

Using the SVD also surfaces the `*_W1TS` / `*_W1TC` (write-1-to-set / -clear)
registers, so set/clear GPIO is a single atomic store — no read-modify-write.

### Startup

`src/init.zig` `disableWatchdogs()` clears the TIMG0/TIMG1 (and RTC) watchdogs
at boot via the generated register addresses — a second-stage bootloader leaves
the TIMG0 flash-boot watchdog running, so an app that neither feeds nor disables
it is reset within seconds on real hardware. The RTC watchdog is only touched on
chips whose `regs` expose the unlock register under the expected name (resolved
with `comptime @hasDecl`), so one routine is correct for every target.

### Panic handler & `std.log`

Both avoid `std.fmt` — its formatter (`Io.Writer`) references the same panic
path that doesn't link here. A tiny comptime formatter in `src/mmio.zig`
(`format`/`printU32`/`printHex`) renders `{s}`/`{d}`/`{x}` to UART instead.

- **`std.log` override.** Each root sets `pub const std_options = .{ .logFn = … }`
  routing through `mmio.log` → UART0 (the `demo` prints an `[info]` line). Calling
  `std.log.*` directly won't link — its non-inline helpers need cross-module far
  calls this backend can't emit — so the firmware calls `mmio.log` (inline).
- **Panic namespace.** `pub const panic = @import("panic").Handler(onPanic)`
  replaces std's `FullPanic` (which would pull `std.fmt`); `onPanic` forwards to
  `mmio.panic`, which prints `!! PANIC: <msg>` plus a best-effort Xtensa
  windowed-ABI backtrace, then halts. Because the backend emits no non-inline
  (far) calls, a compiler-*dispatched* panic can't be lowered (the firmware
  elides all safety checks accordingly); faults are reported by calling
  `mmio.panic` directly — verified in QEMU on a ReleaseSmall build. The backtrace
  is shallow since every call is inlined.

### HAL (`src/hal.zig`)

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
  `r = 2^(2·bits) mod M`), so the driver computes nothing in software (see
  `examples/rsa/`). **Build-only** for now; the Espressif QEMU *does* model RSA, so
  a value-checked run against a comptime `std.math.big` reference is a natural next step.
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
- `hal.GpioEdge(pin_reg, mask, status_reg, clr_reg)` — poll-based edge detection:
  latches rising/falling edges in the GPIO event-status register so a loop catches
  transitions without interrupts (`takeEdge`), complementing `Input` (see
  `examples/gpio_edge/`).
- `hal.ClockGate(clk_en_reg, rst_en_reg, mask)` — ungate (`enable`) and reset
  (`reset`) a peripheral's bus clock through the system clock-control registers
  (`regs.DPORT.PERIP_CLK_EN` / `PERIP_RST_EN` on ESP32), the explicit form of the
  clock bring-up the boot ROM performs for the peripherals the other drivers assume
  are already running (see `examples/clock_gate/`). **Build-only**.

Every driver is **comptime-parameterized on its register addresses** (the I2C
driver on the peripheral namespace), so the MMIO accesses stay provably
aligned/non-null and emit no panic path. Bit fields are expressed through the
comptime helpers in `src/reg.zig` (`reg.bit(n)`, `reg.Field(lsb, width)`), so the
drivers name each field (`divider.set(div)`, not `value << 13`) instead of
hand-shifting magic numbers — and it all folds to the same code at comptime.

### Connectivity and wireless

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

### DSP kernels (`src/dsp.zig`)

`src/dsp.zig` (imported as `dsp`) is a small int16 DSP library:

- `addSatS16` — saturating vector add
- `dotProductS16` — dot product / correlation / energy
- `firS16` — FIR filter (Q15 convolution)
- `fft` — in-place radix-2 Q15 complex FFT (port of esp-dsp's fixed-point FFT;
  comptime twiddle table, no FPU or compiler-rt)

The vector kernels (`addSatS16`, `dotProductS16`) run on the **ESP32-S3 PIE unit
via inline asm** (`ee.vadds.s16`, `ee.vmulas.s16.accx`) when `esp32s3ops` is
present, with a scalar fallback otherwise — chosen at comptime.

**Comptime-generated clobbers (`dsp.qClobbers`).** Instead of hand-writing
`: .{ .q0 = true, .q1 = true }` on every `ee.*` block, the clobber set is built
at comptime from a register list:

```zig
asm volatile (… : … : … : qClobbers(.{ 0, 1, 2 }, true)); // q0,q1,q2 + memory
```

`qClobbers` sets the `q*` fields of `std.builtin.assembly.Clobbers` by comptime
field name (`"q" ++ …`, **not** `std.fmt` — pulling its formatting machinery into
a freestanding image references the unlinkable panic path). Verified in QEMU:
the demo executes real `ee.*` instructions and computes Σ x² = 816.

`examples/esp32s3/main.zig` is the PIE example (mix → energy → blink). The **FFT
spectral-analysis demo lives in `examples/esp32s2/main.zig`** (`fft` is portable scalar
code; the LX7 has no PIE) and prints the magnitude spectrum over UART. They are
split across chips because an `ee.*` instruction is an optimization barrier that
un-elides Debug safety-check panics in surrounding code — so a PIE function and
the higher-level UART/FFT code can't share a build here.

- **Inline required:** kernels are `inline` because the prebuilt xtensa backend
  can't emit cross-module (far) calls (same reason `mmio` is inline).
- Q15 math uses `[*]` indexing + wrapping arithmetic so Debug builds emit no
  bounds-check / overflow / divide panic path (which don't link here).

> Atomics (`@atomicRmw`/`@cmpxchg`) compile and lower correctly to the Xtensa
> `s32c1i` CAS, but the Espressif QEMU esp32s3 machine does not faithfully model
> the store-conditional, so an atomic spins forever under emulation (works on
> real silicon). They are therefore not used in the QEMU-tested firmware.

---

## QEMU testing

ESP32 and ESP32-S3 have machine models in the Espressif QEMU fork; **ESP32-S2
does not**, so it is build-only. QEMU firmware places all code in IRAM so
`qemu-system-xtensa -kernel <elf>` runs without the ROM bootloader initialising
the flash cache.

```bash
# Build the QEMU ELFs (IRAM-only) → zig-out/bin/esp32_qemu, esp32s3_qemu
zig build qemu

# Build + launch QEMU interactively
zig build run-esp32
zig build run-esp32s3

# Non-interactive boot test: boot each QEMU-capable chip and assert no CPU
# faults (this is what CI runs).
zig build smoke
zig build smoke -Dsmoke-seconds=10

# Show the example's UART output (captured from QEMU via `-serial file:`):
zig build demo          # all QEMU-capable chips
zig build demo-esp32    # just the ESP32 crypto example
```

The firmware writes to UART0 (`regs.UART0.FIFO`); `demo` routes that to a file
and prints it. **`esp32` is the crypto demo** — it runs SHA-1/256 and AES-128/256-ECB
on the hardware accelerators and checks each against `std.crypto`'s comptime
reference (`esp32s3` is the PIE/SIMD example and drives the LED rather than
printing):

```
ESP32 bare-metal Zig — hardware crypto demo
[info] SHA-1("abc") HW vs std.crypto: OK
[info] SHA-256("abc") HW vs std.crypto: OK
[info] AES-128-ECB HW vs std.crypto: OK
[info] AES-256-ECB HW vs std.crypto: OK
[info] rng sample 3160650498, GPIO0 low
```

`build.zig` finds `qemu-system-xtensa` on `PATH`; override it with
`-Dqemu=/path/to/qemu-system-xtensa`. The smoke test boots each chip for
`-Dsmoke-seconds` (default 5) and fails if the CPU raises a fault or QEMU exits
before the timeout — the blink loop never returns, so "still running at the
timeout" is the pass condition.

Install the emulator from the Espressif QEMU releases
(<https://github.com/espressif/qemu/releases>); on Linux it also needs
`libsdl2` and `libslirp` at runtime.

### Memory layout (QEMU, IRAM-only)

| Chip | IRAM origin | DRAM origin |
|---|---|---|
| ESP32    | `0x40080000`, 1 MB | `0x3FFB0000`, 176 KB |
| ESP32-S3 | `0x40370000`, 1 MB | `0x3FC88000`, 300 KB |

IRAM is extended to 1 MB (real hw: 128 KB / 400 KB) to accommodate Debug builds.

### Stack addresses used in startup prologue

| Chip | DRAM top | Computation |
|---|---|---|
| ESP32    | `0x3FFDC200` | `0x40000000 − 0x23E00` (`0x23E` << 8) |
| ESP32-S2 | `0x3FFDE000` | `0x40000000 − 0x22000` (`0x220` << 8) |
| ESP32-S3 | `0x3FCD3000` | `0x40000000 − 0x32D000` (`0x32D` << 12) |

Each value is within the valid DRAM range on real hardware, so the same source
file works for both hardware and QEMU builds without conditional compilation.

---

## Flashing to hardware

> **Note:** The flat `.bin` produced by `zig build` via `objcopy` is large
> (tens of MB) because objcopy zero-fills the gap between the DROM and IROM
> segments. Use one of the methods below instead.

Hardware flashing requires the standard second-stage **bootloader** and
**partition table** to already be present on flash (they initialise the
flash-cache MMU so the app's `irom_seg` becomes accessible). Take them from any
build of the vendor SDK:

```
bootloader.bin       → flash offset 0x0
partition-table.bin  → flash offset 0x8000
```

### espflash (alternative 1)

[espflash](https://github.com/esp-rs/espflash) is a Rust CLI that works
directly with ELF files and avoids the large-binary problem.

```bash
cargo install espflash

# Flash application only (bootloader + partition-table already on device):
espflash flash --chip esp32s3 --baud 460800 zig-out/bin/esp32s3_baremetal_zig

# Serial monitor:
espflash monitor --chip esp32s3
```

### esptool.py (alternative 2)

```bash
# Convert ELF → correct-sized image (reads load segments, no zero-fill):
esptool.py --chip esp32s3 elf2image \
    --flash_mode dio --flash_size 8MB \
    --output firmware.bin zig-out/bin/esp32s3_baremetal_zig

# Flash (bootloader + partition-table must already be on device):
esptool.py --chip esp32s3 write_flash 0x10000 firmware.bin

# ESP32 / ESP32-S2 (same flow, different chip flag):
esptool.py --chip esp32   elf2image --output firmware.bin zig-out/bin/esp32_baremetal_zig
esptool.py --chip esp32s2 elf2image --output firmware.bin zig-out/bin/esp32s2_baremetal_zig
```

---

## References

- [zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap) — the Zig toolchain (Espressif LLVM fork) this project builds with
- [esp-rs/esp-pacs](https://github.com/esp-rs/esp-pacs) — upstream of the vendored `svd/*.svd`; register access is generated from these by `tools/svd2zig.zig`
- [espressif/esp-dsp](https://github.com/espressif/esp-dsp) — reference for the fixed-point FFT/DSP algorithms ported into `src/dsp.zig`
- [esp-rs/espflash](https://github.com/esp-rs/espflash) — ELF-aware flashing tool used in the hardware-flashing instructions above

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
