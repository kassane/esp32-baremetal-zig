# Getting started

From a fresh checkout to firmware running in QEMU and on hardware.

## 1. Install the toolchain

This project needs the **Espressif LLVM fork of Zig** — upstream Zig has no
`esp32` / `esp32s2` / `esp32s3` CPU models. Grab the `0.16.0-xtensa` build for your
host and put it on `PATH`:

```bash
curl -L -o zig.tar.xz \
  https://github.com/kassane/zig-espressif-bootstrap/releases/download/0.16.0-xtensa/zig-relsafe-x86_64-linux-musl-baseline.tar.xz
tar -xJf zig.tar.xz
export PATH="$PWD/zig-relsafe-x86_64-linux-musl-baseline:$PATH"
zig version   # → 0.16.0
```

(macOS and Windows builds are on the same releases page.)

## 2. Build

```bash
zig build                          # all chips → zig-out/bin/
zig build esp32                    # just one chip (esp32 / esp32s2 / esp32s3)
zig build -Doptimize=ReleaseSmall  # size-optimized
```

### Build-time configuration

A few HAL knobs are set at build time as typed `-D` options (exposed to the code
as `@import("config")`, wired in by `hal.Console`):

| Option          | Type             | Default | Effect                                                              |
| --------------- | ---------------- | ------- | ------------------------------------------------------------------- |
| `-Dlog-level`   | err/warn/info/debug | `info`  | Minimum `std.log` level compiled in (lower levels are dropped).     |
| `-Dpanic-trace` | bool             | `true`  | Print a UART stack backtrace from the panic handler; `false` shrinks the panic path. |

```bash
zig build esp32 -Dlog-level=debug      # compile in debug-level logging
zig build esp32 -Dpanic-trace=false    # drop the backtrace walk
```

## 3. Run it in QEMU (optional)

Install the Espressif QEMU fork from <https://github.com/espressif/qemu/releases>
and put `qemu-system-xtensa` on `PATH` (on Linux it also needs `libsdl2` and
`libslirp`). Then:

```bash
zig build run-esp32   # launch the esp32 firmware interactively
zig build smoke       # boot every QEMU-capable chip and assert no CPU faults
zig build demo        # boot + print each chip's UART output
```

## 4. Try an example

Every folder under `examples/` is a standalone package:

```bash
cd examples/esp32     && zig build demo   # hardware SHA/AES vs std.crypto, live in QEMU
cd examples/rsa       && zig build demo   # RSA known-answer modexp, live in QEMU
cd examples/heap      && zig build demo   # bump-arena allocation, live in QEMU
cd examples/blink     && zig build        # build-only GPIO blink
```

The full list is in the [README](../README.md#how-to-build).

## 5. Write your own firmware

A minimal `main.zig` that blinks GPIO2:

```zig
const mmio = @import("mmio");
const hal = @import("hal");
const init = @import("init");
const regs = @import("regs");
const startup = @import("startup");

fn onPanic(msg: []const u8, ret: ?usize) noreturn {
    mmio.panic(regs.UART0.FIFO, msg, ret);
}
pub const panic = @import("panic").Handler(onPanic);

const led: u32 = @as(u32, 1) << 2; // GPIO2
const Led = hal.Output(regs.GPIO.ENABLE_W1TS, regs.GPIO.OUT, regs.GPIO.OUT_W1TS, regs.GPIO.OUT_W1TC, led);

export fn main() callconv(.c) noreturn {
    init.disableWatchdogs(regs); // or the chip resets within seconds on real hardware
    Led.init();
    mmio.blink(regs.GPIO.OUT_W1TS, regs.GPIO.OUT_W1TC, led, 480_000);
}

export fn Reset() callconv(.naked) noreturn {
    asm volatile (startup.vector());
}
```

Copy `examples/blink/build.zig` as a starting `build.zig`, or consume the repo as a
package — see [Use it as a dependency](../README.md#use-it-as-a-dependency-zig-fetch).
Reach for a driver from [docs/hal.md](hal.md) and pass it the matching `regs.*`
registers.

## 6. Flash to hardware

See [Flashing to hardware](../README.md#flashing-to-hardware): use `espflash`
(ELF-aware) or `esptool.py elf2image`, with the vendor second-stage bootloader and
partition table already on flash.

## Where next

- [docs/hal.md](hal.md) — the full peripheral driver reference.
- [docs/internals.md](internals.md) — generated registers, startup, panic/`std.log`.
- [docs/dsp.md](dsp.md) — fixed-point DSP + the ESP32-S3 PIE/SIMD path.
- [docs/heap.md](heap.md) — the bump-arena allocator.
