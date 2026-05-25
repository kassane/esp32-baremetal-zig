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

### ESP32-S3 SIMD (PIE)

`src/dsp.zig` (imported as `dsp`) holds portable DSP kernels. `dotProductS16`
computes a signed-16-bit dot product using the LX7's Processor Instruction
Extensions (Espressif's 128-bit vector unit: eight `q0`–`q7` registers, a 40-bit
multiply-accumulate `ACCX`) and falls back to a scalar loop on chips without
them. `esp32s3/main.zig` calls it on two 8-lane `int16` vectors (Σ i² = 204) and
drives the blink period from the result. Notes:

- **Portable via comptime:** the SIMD branch is chosen with
  `comptime dsp.has_simd` (`std.Target.xtensa.featureSetHas(…, .esp32s3ops)`), so
  the inactive branch is never analysed and `ee.*` never reaches the LX6
  assembler — the same module builds for esp32, esp32s2 and esp32s3.
- **Inline required:** the kernels are `inline` because the prebuilt xtensa
  backend does not emit cross-module (far) calls; inlining keeps everything in
  the caller (this is also why `mmio`'s helpers are `inline`).
- Inline-asm clobbers use the Zig 0.16 struct form, e.g.
  `: .{ .q0 = true, .q1 = true }` — needs a `zig-espressif-bootstrap` build new
  enough to expose the `q*` clobbers.
- 128-bit loads (`ee.vld.128.ip`) need 16-byte-aligned operands. Prefer separate
  load/MAC instructions over the fused `ee.*.ld/st.incp` forms, which have had
  buggy LLVM encodings.
- Verified in QEMU: `ee.zero.accx` / `ee.vmulas.s16.accx` / `rur.accx_0` execute
  and the result reads back correctly (e.g. 204, and 11440 for a 32-element
  vector).

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
- [esp-rs/esp-hal](https://github.com/esp-rs/esp-hal)
</content>
