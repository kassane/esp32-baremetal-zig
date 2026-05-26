# DSP kernels (`src/dsp.zig`)

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
