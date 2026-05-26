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

```bash
zig build regs    # emit every module into zig-out/gen/ and ast-check it
```

Using the SVD also surfaces the `*_W1TS` / `*_W1TC` (write-1-to-set / -clear)
registers, so set/clear GPIO is a single atomic store — no read-modify-write.

## Startup

`src/init.zig` `disableWatchdogs()` clears the TIMG0/TIMG1 (and RTC) watchdogs
at boot via the generated register addresses — a second-stage bootloader leaves
the TIMG0 flash-boot watchdog running, so an app that neither feeds nor disables
it is reset within seconds on real hardware. The RTC watchdog is only touched on
chips whose `regs` expose the unlock register under the expected name (resolved
with `comptime @hasDecl`), so one routine is correct for every target.

## Panic handler & `std.log`

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
