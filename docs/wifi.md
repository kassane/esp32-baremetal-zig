# Wi-Fi, Bluetooth and the radio (deep dive)

**Short answer: the radio is out of scope for this project, by design.** This page
explains *why*, what it would actually take, and which register-level groundwork the
HAL does provide — so the boundary is an informed decision, not a hand-wave.

## Why there is no pure-bare-metal Wi-Fi driver

The Wi-Fi / Bluetooth / 802.15.4 radios are not driven by registers you can program
from scratch. Three things stand between firmware and a connected radio, and two of
them are exactly what this project sets out *not* to need:

1. **Closed binary blobs.** The RF front-end, PHY and lower MAC are shipped only as
   precompiled libraries — `libphy`, `libpp`, `libnet80211`, `libcore` (and
   `libbt`/`libble` for Bluetooth) — from [espressif/esp32-wifi-lib][wifi-lib].
   There is no register-level documentation to reimplement them; you link the `.a`
   files or you have no radio. (This is also why the QEMU fork does not emulate the
   radio — there is nothing register-level to emulate.)

2. **An OS adapter.** The blobs call out to ~30 stub functions — `wifi_calloc`,
   `wifi_thread_semphr_get`, `queue_send`, `task_ms_to_tick`, `wifi_int_disable` /
   `wifi_int_restore`, task create/yield, software timers — the *OS adapter*
   (`esp_wifi_os_adapter`). It does not require FreeRTOS specifically, but it does
   require a **scheduler**: tasks, semaphores, queues, timers and interrupt
   management. That is precisely the RTOS layer this project omits (it is
   poll/blocking, enables no interrupts, and ships no allocator beyond the bump
   arena in [heap.md](heap.md)).

3. **PHY init + interrupts + a timebase.** `esp_wifi_init` calibrates the PHY,
   installs a timer ISR (`setup_timer_isr`), enables interrupts, and drives an event
   loop. On the Xtensa parts the reference stack claims TIMG1/TIMER0 and `CCOMPARE0`
   for itself, and runs single-core.

So Wi-Fi is not a missing driver — it is a closed-blob radio stack plus a small RTOS
plus an interrupt-driven init sequence, none of which is verifiable in QEMU. Adding
it would invert the project's two stated tenets (blob-free, no-RTOS), so it stays
out of scope here.

## What the HAL *does* provide (the groundwork a stack sits on)

- the 48-bit factory MAC every radio interface derives from — `hal.Efuse`;
- the hardware RNG a TLS layer seeds from — `hal.Rng`;
- the peripheral clock-gating a bring-up touches — `hal.ClockGate` (e.g. the
  `DPORT.WIFI_CLK_EN` domain);
- the wired buses and the pure-register *wireless* protocols that need no blob:
  infrared remote control (`hal.Rmt`) and WS2812/NeoPixel addressable RGB
  (`hal.Ws2812`).

## How you *would* add it (if you accept the blobs + a scheduler)

This is a large effort (the reference `esp-wifi` is thousands of lines on top of the
blobs), but the shape is:

1. **Vendor the blobs.** Pull [esp32-wifi-lib][wifi-lib] in as a dependency
   (`zig fetch --save=<pkg> git+<url>` for a packaged mirror, or vendor the `.a`
   files directly) and link them with `module.addObjectFile` / `exe.linkLibrary`,
   plus the chip's ROM `.ld` symbols.
2. **Implement the OS adapter** — the `esp_wifi_os_adapter` stub set (malloc/free,
   semaphores, mutexes, queues, tasks, software timers, `int_disable`/`restore`).
   This is a minimal cooperative scheduler; `hal.Critical` is the interrupt-mask
   primitive it would build on. See [esp-radio-rtos-driver][rtos-driver] for the
   exact function list.
3. **Bring up the PHY** (RF calibration) and call `esp_wifi_init`, then service the
   event loop; wire a timer (TIMG1) + interrupt for the scheduler tick.

The Rust [esp-wifi][esp-wifi] / [esp-wifi-sys][esp-wifi-sys] crates are the
reference implementation of exactly this on bare metal.

## References

- [espressif/esp32-wifi-lib][wifi-lib] — the precompiled Wi-Fi/BT blobs (`libphy`, `libpp`, `libnet80211`, …)
- [esp-rs/esp-wifi][esp-wifi] & [esp-rs/esp-wifi-sys][esp-wifi-sys] — Wi-Fi/BT/ESP-NOW on bare-metal Rust (the OS-adapter approach, single-core)
- [esp-radio-rtos-driver][rtos-driver] — the scheduler interface the blobs require
- [ESP-IDF Wi-Fi driver guide][idf-wifi] — `esp_wifi_init`, the OS adapter, the event model

[wifi-lib]: https://github.com/espressif/esp32-wifi-lib
[esp-wifi]: https://github.com/esp-rs/esp-wifi
[esp-wifi-sys]: https://github.com/esp-rs/esp-wifi-sys
[rtos-driver]: https://github.com/esp-rs/esp-hal/tree/main/esp-radio-rtos-driver
[idf-wifi]: https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/wifi.html
