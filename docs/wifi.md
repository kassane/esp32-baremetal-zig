# Wi-Fi, Bluetooth and the radio

**Short answer: the radio is out of scope for this project, by design.** This page
explains why, what it would take, and which register-level groundwork the HAL does
provide — so the boundary is an informed decision, not a hand-wave.

## Why there is no pure-bare-metal Wi-Fi driver

The Wi-Fi / Bluetooth / 802.15.4 radios are not driven by registers you can program
from scratch. Three things stand between firmware and a connected radio, and two of
them are exactly what this project sets out *not* to need:

1. **Closed binary blobs.** The RF front-end, PHY and lower MAC ship only as
   precompiled vendor libraries — there is no register-level documentation to
   reimplement them; you link the blobs or you have no radio. (This is also why the
   QEMU fork does not emulate the radio — there is nothing register-level to
   emulate.)

2. **A scheduler.** The blobs call out to an OS-adapter layer — dynamic allocation,
   semaphores, mutexes, queues, software timers and interrupt enable/disable — so
   they require tasks and a scheduler. That is precisely the RTOS layer this project
   omits: it is poll/blocking, enables no interrupts, and ships no allocator beyond a
   small bump arena.

3. **RF init, interrupts and a timebase.** Bringing the radio up calibrates the PHY,
   installs a timer interrupt, enables interrupts and services an event loop,
   claiming a hardware timer for itself.

So Wi-Fi is not a missing driver — it is a closed-blob radio stack plus a small
scheduler plus an interrupt-driven init sequence, none of which is verifiable in
QEMU. Adding it would invert the project's two tenets (blob-free, no-RTOS), so it
stays out of scope here.

## What the HAL *does* provide (the groundwork a stack sits on)

- the 48-bit factory MAC every radio interface derives from — `hal.Efuse`;
- the hardware RNG a TLS layer seeds from — `hal.Rng`;
- the peripheral clock-gating a radio bring-up touches — `hal.ClockGate`;
- the wired buses, plus the pure-register *wireless* protocols that need no blob:
  infrared remote control (`hal.Rmt`) and WS2812/NeoPixel addressable RGB
  (`hal.Ws2812`).

## How you *would* add it (accepting the blobs and a scheduler)

This is a large effort, but the shape is:

1. **Vendor the blobs** and link the precompiled libraries into the firmware
   alongside the chip's ROM symbols.
2. **Implement the OS adapter** — the stub set the blobs call into (allocate/free,
   semaphores, mutexes, queues, tasks, software timers, interrupt mask/restore). This
   is a minimal cooperative scheduler; `hal.Critical` is the interrupt-mask primitive
   it would build on.
3. **Bring up the PHY** (RF calibration), initialise the radio, and service its
   event loop on a hardware timer plus an interrupt.
