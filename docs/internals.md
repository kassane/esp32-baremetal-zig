# Internals

How the firmware generates its register map, survives boot, and reports failures
without `std.fmt`.

## Register access (svd2zig)

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
Zig for **every** esp32* target.

To prove that breadth, the vendored set includes the RISC-V **ULP-coprocessor**
SVDs (`svd/esp32s2-ulp.svd`, `svd/esp32s3-ulp.svd`) alongside the three Xtensa
chips. The ULP cores aren't firmware targets here (this is an Xtensa project), but
`zig build regs` generates their register modules too and runs `zig ast-check` on
each — so svd2zig's output is verified valid Zig across both architectures, in CI.
`examples/ulp_s2` goes one step further: a real `riscv32imc` ULP program that
imports the generated ULP registers and the shared `hal`/`mmio`/`startup` modules
(the register drivers are arch-agnostic; `startup.ulpVector` is the RISC-V reset
prologue) — build-only, since QEMU does not run the ULP core.

```bash
zig build regs    # emit every module into zig-out/gen/ and ast-check it
```

Using the SVD also surfaces the `*_W1TS` / `*_W1TC` (write-1-to-set / -clear)
registers, so set/clear GPIO is a single atomic store — no read-modify-write.

## Startup

The naked `Reset` entry runs `startup.vector()`: it enables the windowed-register
ABI, points the stack at the top of DRAM, and `call8 main` (a same-module near
call — this backend emits no far calls). `main`'s first two statements complete
the boot:

- **`init.runtimeInit()`** is the C runtime init — it zeroes `.bss` and copies
  `.data` from its load address (in flash, reached through the DROM cache) to its
  run address in DRAM, using the bounds the linker scripts export
  (`_bss_start`/`_bss_end`, `_sidata`/`_data_start`/`_data_end`). On real hardware
  SRAM powers up with garbage, so globals are undefined until this runs; QEMU
  loads segments directly into already-zeroed RAM (`_sidata == _data_start`), so
  it's a no-op there. The word-wide loops are `volatile` so the compiler can't
  fold them into a `memset`/`memcpy` call (a far call that wouldn't link), and the
  routine sets `@setRuntimeSafety(false)` — the linker addresses are `ALIGN(4)`,
  but the per-iteration alignment/bounds checks would otherwise pull in a panic
  path that doesn't link.
- **`init.disableWatchdogs()`** clears the TIMG0/TIMG1 (and RTC) watchdogs via the
  generated register addresses — a second-stage bootloader leaves the TIMG0
  flash-boot watchdog running, so an app that neither feeds nor disables it is
  reset within seconds on real hardware. The RTC watchdog is only touched on chips
  whose `regs` expose the unlock register under the expected name (resolved with
  `comptime @hasDecl`), so one routine is correct for every target.

### What the bootloader handles, and what we rely on

The boot chain is ROM → ESP-IDF second-stage bootloader → this app. Cross-checked
against esp-idf and esp-rs/esp-hal, the bootloader has already done the following
by the time the app's reset vector runs, so the app must *not* redo them:

- **Flash cache / MMU** mapping, so `irom_seg`/`drom_seg` are addressable (this is
  why hardware flashing needs the vendor bootloader — see the README).
- **Initial CPU clock** — a valid frequency (default ~80 MHz). Reconfiguring it to
  160/240 MHz is optional; esp-hal does it through analog `regi2c`/BBPLL writes,
  which can't be validated in QEMU, so this project leaves the clock as the
  bootloader set it and asks `hal.Delay` callers to pass the matching `cpu_hz`.
- **The exception/interrupt vector base (`VECBASE`)** points at the ROM vector
  table, which carries the windowed-ABI overflow/underflow handlers that register
  spills depend on. The app deliberately does *not* install its own `VECBASE`:
  doing so without re-providing those window handlers would crash on the first
  deep call chain. The trade-off is that a genuine CPU exception is handled by the
  ROM (reset), not routed to `mmio.panic`; our panic path is for explicit/`std`
  panics, which are called directly, not dispatched through a vector.

So the mandatory app-side init reduces to exactly what `main` already does:
`runtimeInit()` (`.bss`/`.data`) and `disableWatchdogs()`. The interrupt
controller and an app-owned vector table are intentionally left out — they're only
needed for interrupt-driven drivers.

For ecosystem compatibility `src/init.zig` also emits an **ESP-IDF application
descriptor** (`esp_app_desc_t`, magic `0xABCD5432`) — a 256-byte record the
linker scripts `KEEP` at the very start of `drom_seg`, i.e. the start of the DROM
mapping where `esptool`/`espflash`/idf-monitor and the OTA machinery look for it.
It isn't required to boot (the second-stage bootloader checks the image header,
not this), but it lets the vendor tooling read the firmware's version/project
metadata and makes the image OTA-shaped.

## Panic handler & `std.log`

Both avoid `std.fmt` — its formatter (`Io.Writer`) references the same panic
path that doesn't link here. A tiny comptime formatter in `src/mmio.zig`
(`format`/`printU32`/`printHex`) renders `{s}`/`{d}`/`{x}` to UART instead.

- **`std.log` override.** Each root sets `pub const std_options` — usually the
  drop-in `hal.Console(fifo).options` — routing through `mmio.log` → UART0 (the
  `demo` prints an `[info]` line), with the minimum level fixed at build time by
  `-Dlog-level`. Calling `std.log.*` directly won't link — its non-inline helpers
  need cross-module far calls this backend can't emit — so the firmware calls
  `mmio.log` (inline).
- **Panic namespace.** `pub const panic = @import("panic").Handler(onPanic)`
  replaces std's `FullPanic` (which would pull `std.fmt`); `onPanic` forwards to
  `mmio.panic`, which prints `!! PANIC: <msg>` plus a best-effort Xtensa
  windowed-ABI backtrace, then halts. Because the backend emits no non-inline
  (far) calls, a compiler-*dispatched* panic can't be lowered (the firmware
  elides all safety checks accordingly); faults are reported by calling
  `mmio.panic` directly — verified in QEMU on a ReleaseSmall build. The backtrace
  is shallow since every call is inlined, and is dropped entirely with
  `-Dpanic-trace=false`.

## Why everything is `inline` — and the WiFi/RTOS ceiling

The prebuilt `zig-espressif-bootstrap` Xtensa backend emits **no callable body for
a normal Zig function call**. This was verified exhaustively: a plain `fn`, a
`pub fn`, and even an `export fn`, when called from Zig, all fail to link with
`undefined symbol: <name>`. Only three things work — `inline` functions (folded
into the caller), the compiler-runtime builtins (`memcpy`/`memset`/`memmove`,
which compiler-generated code references), and `main`/`Reset` reached through the
hand-written `call8` in `startup.vector()`. That is why the entire HAL is
`inline`, drivers are comptime-parameterised on their register addresses, and
`hal.runTasks` requires its tasks to be `inline`.

This sets a hard ceiling on what can be ported from esp-hal / esp-idf / microzig:

- **WiFi** needs to *call into* precompiled blob libraries and hand them callbacks
  — i.e. ordinary (non-inline) cross-module calls, which don't link here. It also
  needs a general heap (`std.mem.Allocator` dispatches through a vtable — an
  indirect call) and a preemptive scheduler. None are reachable.
- **A preemptive RTOS** needs a tick-interrupt-driven context switch through an
  app-owned vector table; the project instead relies on the ROM `VECBASE` (which
  carries the windowed-ABI window handlers), and a forced context switch would be
  a non-inline call besides.

So the feasible adaptation of the RTOS idea is the *cooperative* `hal.runTasks`
super-loop (inline tasks, no preemption). Full WiFi/RTOS in Zig is demonstrated by
**microzig — but only on the RISC-V esp32 chips** (e.g. esp32-c3), whose standard
LLVM backend emits ordinary far calls; reaching parity here would require those
chips or a far-call-capable Xtensa backend, not this fork.
