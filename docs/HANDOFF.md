# Handoff

State of the work on branch `claude/gallant-mayer-cNt8c`, the esp-rs/esp-idf
research that drove it, and what a follow-up session should pick up. The deep
"why" lives in [internals.md](internals.md) and [hal.md](hal.md); this file is
the map, not the territory.

## What this branch changed

Themed, oldest-first (see `git log main..HEAD`):

- **Real-hardware boot parity** — `init.runtimeInit()` is a proper crt0 (`.bss`
  zero + `.data` copy from the flash LMA to DRAM); `src/init.zig` also emits an
  ESP-IDF `esp_app_desc_t` in its own 1 KB-aligned `.flash.appdesc` section so
  `esptool`/`espflash`/OTA tooling recognise the image. Cross-checked against
  esp-idf and esp-rs/esp-hal. Detail: [internals.md](internals.md) "Startup".
- **The `-fstrip` fix** — the project's "inline-only" rule was a workaround for
  compile-time `-fstrip` stripping local symbols while call relocations remained
  (`undefined symbol`), **not** an Xtensa-backend limit. `mod.strip = false`
  lifts it; non-inline (direct and vtable) calls now link. Verified two ways
  (`zig build-obj`, and `zig cc` on the same LLVM backend). `std.mem.Allocator`
  now links in Release as a result.
- **Build-time config knobs** — `-Dlog-level` / `-Dpanic-trace` via
  `b.addOptions` → `@import("config")`, forwarded by every example's `build.zig`.
- **Cooperative scheduler** — `hal.runTasks` (comptime-composed inline tasks),
  the right *inline* adaptation while deep calls remain gated (below).
- **Two new examples** — `cffi` (link a precompiled C blob, FFI both directions)
  and `crc` (software CRC-32 via `std.hash.Crc32`, since the ROM CRC isn't mapped
  under QEMU `-kernel`). Both QEMU-verified and in CI.
- **Docs** — reframed the inline rationale, recorded the deep-call investigation,
  and added the PSRAM status note.

Local builds are green: root firmware (esp32/-s2/-s3, Debug + ReleaseSmall),
`zig build regs`, and all 42 examples. CI only runs on PRs / pushes to `main`,
so a feature-branch push gets no CI signal on its own.

## The one gating issue: deep non-inline call chains

This is the blocker for WiFi/RTOS and the most important thing to understand.

Linking is solved (`-fstrip`, above). A separate **runtime** limit remains at
the first windowed-ABI **register-window overflow** (~6 nested calls). A
controlled experiment (this session) pinned it down precisely:

- **`-kernel` lacks the ROM window handlers.** `VECBASE=0x40000000` but `-kernel`
  doesn't map the ROM, so its overflow vectors are all-zero — the first overflow
  jumps into zeroed memory. (QEMU warns it ignores the `-bios` ROM under
  `-kernel`.)
- **Boot through the ROM (QEMU flash-boot) and *direct* deep calls work.** Wrap
  the IRAM-only QEMU ELF with esptool `elf2image`, write at flash `0x1000`, boot
  with `-drive file=flash.bin,if=mtd` and **no** `-kernel`: the ROM runs and the
  real handlers are present (`OF8` reads back as `s32e`). A direct `call8` chain
  then runs **40 deep** and returns correctly.
- **Indirect (`callx8`) deep calls still hang — a QEMU bug.** Same ROM boot: an
  indirect chain survives ≤5 deep and hangs at ~6–7. Direct-vs-indirect is the
  only variable, so QEMU mis-handles overflow *triggered by* `callx8`. Real
  silicon handles both (esp-idf/esp-rs run deep indirect calls everywhere).

Full write-up + reproduction: [internals.md](internals.md) "Why everything is
`inline`". The inline HAL + `hal.runTasks` stays correct; a real WiFi/RTOS port
needs silicon (the indirect-dispatch hang has no QEMU answer), plus the RF blobs
and an interrupt-driven context switch.

## Verified in QEMU vs. silicon-deferred

| Capability | Status | Why |
|---|---|---|
| Crypto (SHA/AES), RNG, RSA, HMAC, DSP/SIMD | QEMU-verified | on-chip peripherals modelled |
| GPIO, timers, RTC, eFuse, critical sections, heap, FFI, CRC | QEMU-verified | — |
| i2c/spi/rmt/twai/mcpwm/i2s/dac/adc/… | build-only | no QEMU model for the bus |
| Deep **direct** call chains | QEMU via ROM flash-boot | `-kernel` lacks ROM handlers; flash-boot restores them (40 deep verified) |
| Deep **indirect** (`callx8`) calls / interrupts / async | **silicon** | QEMU `callx8`+window-overflow bug (above), no QEMU workaround |
| WiFi / BT / RTOS | **silicon** | need RF blobs + scheduler (deep indirect dispatch) + interrupt context switch |
| PSRAM | **deferred** | cache/MMU + SPIRAM bring-up is bootloader/silicon work — [internals.md](internals.md) bootloader section |
| CPU clock 160/240 MHz | **deferred** | analog `regi2c`/BBPLL writes unvalidatable in QEMU |

## Picking up the work

```bash
git switch claude/gallant-mayer-cNt8c
zig build --summary all                  # root firmware, 3 chips
zig build smoke                          # QEMU boot test (esp32, esp32s3)
cd examples/<name> && zig build demo      # run one example's UART output
```

Toolchain: the `zig-espressif-bootstrap` 0.16.0-xtensa fork + Espressif QEMU
(versions pinned in `.github/workflows/ci.yml`). No esp-idf / `IDF_PATH` needed.

## Continuing on silicon (esp32 / -s2 / -s3)

Where the deferred items get validated. Flash with the README's espflash/esptool
flow (the image is already hardware-shaped: app descriptor, IRAM/flash layout).
Validate in this order — each unblocks the next:

1. **Deep *indirect* calls — check this first; it gates everything else.** QEMU
   hangs an indirect (`callx8`) chain at the window-overflow point (~6–7) while
   *direct* calls work (see [internals.md](internals.md)); silicon's hardware
   window overflow should handle both. Flash a probe and watch UART:

   ```zig
   const FnPtr = *const fn (u32) callconv(.c) u32;
   var tab: [64]FnPtr = undefined;
   fn ind(n: u32) callconv(.c) u32 {
       if (n == 0) return 0;
       return tab[n & 63](n - 1) +% n; // indirect callx8, non-tail
   }
   // in main, after init: fill tab[*]=&ind through an asm("") barrier so LLVM
   // can't devirtualise, then print @call(.never_inline, ind, .{40}) — expect 820.
   ```

   If `ind(40)` returns **820** on-device, the limit was purely QEMU's emulation
   and the whole WiFi/RTOS deep-dispatch path is viable. If it faults, it's a real
   startup/ABI issue (chase the bootloader-set `VECBASE` window handlers / `PS`).
2. **crt0** — on real SRAM `.bss`/`.data` actually matter (QEMU pre-zeroes RAM, so
   `init.runtimeInit()` is a no-op there). Confirm a `.data` global keeps its
   initialiser and a `.bss` global reads zero after boot.
3. **Watchdogs** — the TIMG0 flash-boot WDT really resets on silicon; confirm
   `init.disableWatchdogs()` holds (app runs >10 s without a reset).
4. **CPU clock** 160/240 MHz (analog `regi2c`/BBPLL — [internals.md](internals.md)),
   then **PSRAM** (cache/MMU + SPIRAM bring-up).
5. **WiFi**: provide the ESP-IDF OSI shim (esp-rs `esp-wifi`'s `os_adapter` is the
   reference for the ~100 funcs — FreeRTOS task/queue/sem/mutex, heap, timers,
   interrupt alloc, NVS calibration), link the `espressif/esp32-wifi-lib` blobs,
   and stand up a preemptive RTOS + interrupt context switch first. This is the
   real bring-up; QEMU can't host it (no radio model + the indirect-call hang).

## esp-rs ecosystem map (for further exploration)

What the esp-rs workspace contributes and where it landed (or why not):

- **esp-pacs** → vendored `svd/*.svd`, register access generated by
  `tools/svd2zig.zig`. **Harvested.**
- **esp-hal** → register sequences cross-checked (touch, RTC, ULP, app
  descriptor). Driver-by-driver parity in [hal.md](hal.md). **Ongoing reference.**
- **esp-config / esp-metadata** → modelled by the `b.addOptions` config knobs.
  **Harvested.**
- **esp-rom-sys** → ROM functions at fixed addresses (CRC, MD5, SPI flash). The
  ROM is **not mapped under `-kernel`** (reads as zero), so these are unreachable
  there; `crc` ships the software substitute. They *would* be reachable under ROM
  flash-boot (the ROM is present), an avenue if a flash-boot target is added.
- **esp-backtrace / esp-println** → covered by `mmio.panic` (Xtensa windowed
  backtrace) and the `std.log` UART shim. **Harvested.**
- **esp-storage** → partial: `flash` reads via the ROM SPI path (build-only).
  Partition-table/NVS parsing would build but not run under `-kernel`.
- **esp-radio/esp-phy, esp-rtos, esp-hal-embassy** → need the proprietary RF
  blobs + deep **indirect** dispatch (QEMU-blocked, see gating issue) + an
  interrupt context switch. **Silicon-gated.**

Natural next targets, in rough priority: (1) optionally a **QEMU flash-boot
target** (esptool `elf2image` → flash `0x1000`, boot via `-drive …,if=mtd`) — it
boots through the ROM and unblocks deep *direct* calls in QEMU, a more realistic
test substrate (a Zig image-gen tool would keep the toolchain esptool-free); (2)
on **silicon**, an interrupt-driven timer + minimal preemptive switch (the deep
*indirect* path has no QEMU answer); (3) then a radio/RTOS bring-up. WiFi/RTOS
proper is gated on (2)–(3); (1) only widens what QEMU can exercise.
