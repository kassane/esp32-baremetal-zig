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

## Contents

- [Toolchain requirement](#toolchain-requirement)
- [How to build](#how-to-build)
- [Use it as a dependency (`zig fetch`)](#use-it-as-a-dependency-zig-fetch)
- [Documentation](#documentation)
- [QEMU testing](#qemu-testing)
  - [Memory layout](#memory-layout-qemu-iram-only)
  - [Stack addresses](#stack-addresses-used-in-startup-prologue)
- [Flashing to hardware](#flashing-to-hardware)
  - [espflash](#espflash-alternative-1)
  - [esptool.py](#esptoolpy-alternative-2)
- [References](#references)
- [License](#license)

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
  `rtc_store` (ESP32 — RTC scratch round-trip), `rsa` (ESP32 — known-answer modexp
  on the RSA accelerator), `heap` (ESP32 — typed bump-arena allocation),
  `rtc_time` (ESP32 — RTC main-timer uptime), `critical` (ESP32 — interrupt-masking
  critical section) and `systimer` (ESP32-S3 — system-timer uptime over UART)
- **Build-only**: `pwm` (LEDC) on ESP32-S2; `i2c` (I2C master), `spi` (SPI master),
  `rmt` (IR remote transmit), `ws2812` (addressable RGB over RMT), `twai`
  (CAN 2.0 transmit), `mcpwm` (motor-control PWM),
  `i2s` (I2S master TX), `dac` (analog output), `adc` (analog input), `iomux` (pad
  pull/drive config), `watchdog` (TIMG WDT), `reset_reason` (reset cause),
  `sw_reset` (software reset), `gpio_edge` (poll-based edge detection),
  `clock_gate` (peripheral clock gating), `brownout` (supply brownout detector) and
  `touch` (capacitive touch sensor), `deep_sleep` (timer-wakeup deep sleep) and
  `pcnt` (pulse counter) and `flash` (SPI-flash read via ROM) on ESP32; `usb_serial`
  (USB CDC-ACM console), `tsens`
  (temperature sensor),
  `hmac` (HMAC-SHA256 accelerator) and `stack_monitor` (ASSIST_DEBUG
  stack-overflow monitor) on ESP32-S3
- **ULP coprocessor** (RISC-V, build-only): `ulp_s2` — an ESP32-S2 ULP program
  built for `riscv32imc` that drives an RTC GPIO through the generated ULP
  registers (`svd/esp32s2-ulp.svd`) and heartbeats the main core via shared RTC
  memory. A separate firmware the main core loads and starts (loader out of scope).

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
fw.root_module.addImport("heap", esp.module("heap"));        // typed bump arena
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

## Documentation

Guides and implementation notes live under [`docs/`](docs/):

- **[docs/getting-started.md](docs/getting-started.md)** — from a fresh checkout to
  firmware running in QEMU and on hardware, plus a minimal-firmware skeleton.
- **[docs/hal.md](docs/hal.md)** — the `hal` driver reference: every peripheral
  driver, what it does, and which run in QEMU vs. are build-only — plus the
  connectivity / wireless boundary.
- **[docs/internals.md](docs/internals.md)** — generated register access
  (`svd2zig`), boot/startup, and the freestanding panic + `std.log` shim.
- **[docs/dsp.md](docs/dsp.md)** — the fixed-point DSP kernels and the ESP32-S3
  PIE/SIMD vector path.
- **[docs/heap.md](docs/heap.md)** — the bare-metal typed bump arena, and why the
  std allocator interface doesn't lower on this backend.

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
- [esp-rs/esp-hal](https://github.com/esp-rs/esp-hal) — the Rust HAL whose register sequences (touch, RTC sleep/timer, ULP, bootloader app-descriptor) this project's drivers are cross-checked against

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
