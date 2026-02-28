# esp32-baremetal-zig

Bare-metal Zig firmware for ESP32 and ESP32-S3.
No IDF runtime, no OS, no libc – pure Zig on Xtensa hardware.

---

## Toolchain requirement

This project **requires the Espressif LLVM fork of Zig** (`zig-espressif-bootstrap`).
Upstream Zig does **not** expose `esp32` / `esp32s2` / `esp32s3` CPU models in
`std.Target.xtensa.cpu`.

| Item | Value |
|---|---|
| Toolchain | `zig-espressif-bootstrap` prebuilt |
| Download | <https://github.com/kassane/zig-espressif-bootstrap/releases> |

---

## How to build

```bash
# Build all chips (default)
./build.sh

# Build only ESP32
./build.sh esp32

# Build only ESP32-S3
./build.sh esp32s3

# Release build
./build.sh -Doptimize=ReleaseSmall

# Directly via zig (after sourcing the correct zig into PATH)
zig build --summary all
```

Artifacts land in `zig-out/bin/`:
- `esp32_baremetal_zig`
- `esp32s3_baremetal_zig`

### QEMU build + run shortcuts (build.sh)

```bash
# Build QEMU ELF then launch emulator (build.sh subcommands)
./build.sh run-qemu-esp32       # ESP32: build qemu-esp32 ELF + launch QEMU
./build.sh run-qemu-esp32s3     # ESP32-S3: build qemu-esp32s3 ELF + launch QEMU
./build.sh run-qemu             # build both QEMU ELFs + launch QEMU for ESP32-S3

# Build QEMU ELFs only (no launch)
./build.sh qemu                 # both chips
./build.sh qemu-esp32           # ESP32 only
./build.sh qemu-esp32s3         # ESP32-S3 only

# Extra flags are forwarded to zig build before QEMU starts
./build.sh run-qemu-esp32 -Doptimize=ReleaseSmall
```

QEMU artifacts: `zig-out/bin/esp32_qemu`, `zig-out/bin/esp32s3_qemu`.

---

## Flashing to hardware

> **Note:** The flat `.bin` produced by `zig build` via `objcopy` is **~97 MB**
> because objcopy zero-fills the gap between `drom_seg` (`0x3C000020`) and
> `irom_seg` (`0x42000020`).  Use one of the methods below instead.

Hardware flashing requires the IDF second-stage **bootloader** and **partition
table** to be present on flash (they initialise the flash-cache MMU so the app's
`irom_seg` at `0x42xxxxxx` becomes accessible).  Extract them from any IDF build:

```
$IDF_PATH/build/bootloader/bootloader.bin  → flash offset 0x0
$IDF_PATH/build/partition_table/partition-table.bin → flash offset 0x8000
```

### espflash (alternative 1)

[espflash](https://github.com/esp-rs/espflash) is a Rust CLI that works
directly with ELF files and avoids the large-binary problem.

```bash
# Install
cargo install espflash

# Generate a properly-sized flash image (no zero-fill gap):
espflash save-image \
    --chip esp32s3 \
    --flash-mode dio \
    --flash-size 8mb \
    --skip-padding \
    --merge \
    zig-out/bin/esp32s3_baremetal_zig \
    firmware_flash.bin \
    --bootloader bootloader.bin \
    --partition-table partition-table.bin \
    --partition-table-offset 0x8000

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

# ESP32 (same flow, different chip flag):
esptool.py --chip esp32 elf2image --output firmware.bin zig-out/bin/esp32_baremetal_zig
esptool.py --chip esp32 write_flash 0x10000 firmware.bin
```

---

## QEMU testing

### Build steps

```bash
# Build QEMU-specific ELFs (all code in IRAM – no flash-cache init needed)
./build.sh qemu            # both chips
./build.sh qemu-esp32      # ESP32 only
./build.sh qemu-esp32s3    # ESP32-S3 only
```

Artifacts: `zig-out/bin/esp32_qemu`, `zig-out/bin/esp32s3_qemu`.

### Linker scripts (QEMU-only)

| File | IRAM origin | DRAM origin |
|---|---|---|
| `esp32/qemu.ld` | `0x40080000`, 1 MB | `0x3FFB0000`, 176 KB |
| `esp32s3/qemu.ld` | `0x40370000`, 1 MB | `0x3FC88000`, 300 KB |

IRAM is extended to 1 MB (real hw: 128 KB / 400 KB) to accommodate Debug builds.
All `.text` sections land in IRAM so QEMU can execute without flash-cache MMU init.

### Running

Preferred – use the `build.sh` shortcuts (build + run in one step):

```bash
./build.sh run-qemu-esp32       # ESP32
./build.sh run-qemu-esp32s3     # ESP32-S3
```

### Stack addresses used in startup prologue

| Chip | DRAM top | Computation |
|---|---|---|
| ESP32 | `0x3FFDC200` | `0x40000000 − 0x23E00` (`0x23E` << 8) |
| ESP32-S3 | `0x3FCD3000` | `0x40000000 − 0x32D000` (`0x32D` << 12) |

Both are within the valid DRAM range on real hardware, so the same source file
works for hardware and QEMU builds without conditional compilation.

---

## References

- [zig-espressif-bootstrap](https://github.com/kassane/zig-espressif-bootstrap)
- [esp-rs/xtensa-lx](https://github.com/esp-rs/xtensa-lx) – linker script origin
- [kubo39/esp32-baremetal-ldc](https://github.com/kubo39/esp32-baremetal-ldc) – inspiration
- [georgik/swift-xtensa](https://github.com/georgik/swift-xtensa) – flashing workflow reference (espflash, --flash-mode dio)
- [esp-rs/espflash](https://github.com/esp-rs/espflash) – Rust-based flash tool (ELF-aware, `--skip-padding`)
- [esp-rs/esp-hal](https://github.com/esp-rs/esp-hal)
