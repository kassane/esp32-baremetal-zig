# esp32-baremetal-zig

Bare-metal Zig firmware for ESP32, ESP32-S2 and ESP32-S3.
No IDF runtime, no OS, no libc – pure Zig on Xtensa hardware.

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

| Source | Chip | CPU | Onboard LED |
|---|---|---|---|
| `esp32/main.zig`   | ESP32    | Xtensa LX6 | GPIO2  |
| `esp32s2/main.zig` | ESP32-S2 | Xtensa LX7 | GPIO18 |
| `esp32s3/main.zig` | ESP32-S3 | Xtensa LX7 | GPIO48 |

Shared register/timing helpers live in `src/mmio.zig` (imported as `mmio`).

### Register access (svd2zig)

Peripheral register addresses are **not** hardcoded — they're generated from
CMSIS-SVD by `tools/svd2zig.zig` (a host tool run automatically by `build.zig`).
For each chip, build.zig runs `svd2zig svd/<chip>.svd <chip>_regs.zig` and
imports the result as `@import("regs")`; firmware uses e.g.
`regs.GPIO.OUT_W1TS`. The vendored `svd/*.svd` are the GPIO, TIMG0/TIMG1 and
RTC_CNTL peripherals extracted from [esp-rs/esp-pacs](https://github.com/esp-rs/esp-pacs)
(fields stripped to keep them small); the generator expands `<dim>` arrays and
`derivedFrom` peripherals (e.g. TIMG1 inherits TIMG0's registers), and handles
the full 2.4 MB SVDs too.

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

### DSP kernels (`src/dsp.zig`)

`src/dsp.zig` (imported as `dsp`) is a small int16 DSP library:

- `addSatS16` — saturating vector add
- `dotProductS16` — dot product / correlation / energy
- `firS16` — FIR filter (Q15 convolution)
- `fft` — in-place radix-2 Q15 complex FFT (port of esp-dsp's fixed-point FFT;
  comptime twiddle table, no FPU or compiler-rt)

The vector kernels (`addSatS16`, `dotProductS16`) use Zig's native `@Vector` —
one portable, clobber-free implementation that builds and runs on every chip
(`a +| b`, `@reduce(.Add, va *% vb)`). `esp32s3/main.zig` is a spectral-analysis
example: it generates a Q15 cosine at bin 5, runs `fft`, finds the dominant bin,
and blinks at a rate proportional to it (verified in QEMU: peak bin = 5). Notes:

- **`@Vector` vs PIE asm (researched):** the prebuilt LLVM-xtensa backend
  *scalarizes* `@Vector` — it does not auto-vectorize to the ESP32-S3 PIE
  (`ee.*`) instructions (confirmed via QEMU `-d in_asm`: zero `ee.*` emitted).
  So `@Vector` is portable and idiomatic but not hardware-vectorized; driving the
  PIE unit still requires inline asm with `q*` register clobbers
  (`: .{ .q0 = true }`, Zig 0.16 form). Results are identical and verified
  (dot = 120, saturating add lane 0 = 9).
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
zig build demo            # all QEMU-capable chips
zig build demo-esp32s3    # just the FFT spectrum example
```

The firmware writes to UART0 (`regs.UART0.FIFO`); `demo` routes that to a file
and prints it. `esp32`/`esp32s2` print a hello banner, and **`esp32s3` renders
the FFT magnitude spectrum of a two-tone signal** as ASCII bars:

```
ESP32-S3 FFT magnitude spectrum (tones @ bins 4 and 12):
bin  4 |##############################################
bin 12 |#######################
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

Hardware flashing requires the IDF second-stage **bootloader** and **partition
table** to be present on flash (they initialise the flash-cache MMU so the app's
`irom_seg` becomes accessible). Extract them from any IDF build:

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

- [zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
- [esp-rs/xtensa-lx](https://github.com/esp-rs/xtensa-lx) – linker script origin
- [kubo39/esp32-baremetal-ldc](https://github.com/kubo39/esp32-baremetal-ldc) – inspiration
- [georgik/swift-xtensa](https://github.com/georgik/swift-xtensa) – flashing workflow reference (espflash, --flash-mode dio)
- [esp-rs/espflash](https://github.com/esp-rs/espflash) – Rust-based flash tool (ELF-aware, `--skip-padding`)
- [esp-rs/esp-hal](https://github.com/esp-rs/esp-hal) – HAL design reference
- [esp-rs/esp-pacs](https://github.com/esp-rs/esp-pacs) – source of the vendored `svd/*.svd` (register access generated by `tools/svd2zig.zig`)
- [espressif/esp-dsp](https://github.com/espressif/esp-dsp) – the fixed-point FFT/DSP algorithms ported into `src/dsp.zig`
