// Copyright (c) 2026 Matheus C. França
// SPDX-License-Identifier: Apache-2.0

//! Bare-metal startup helpers. `inline` for the same reason as `mmio`: the
//! prebuilt xtensa backend can't emit cross-module far calls.

const mmio = @import("mmio");
const reg = @import("reg");

/// C-runtime init: zero `.bss` and copy `.data` from its load address to its run
/// address. Call it as the first statement of `main` — on real hardware SRAM
/// powers up with garbage, so globals are undefined until this runs (the reset
/// vector only sets up the window ABI + stack). The linker scripts export the
/// segment bounds. The loops are word-wide and `volatile`, both so they stay
/// panic-free and so the compiler can't fold them into a `memset`/`memcpy` call
/// (a cross-module far call this backend can't emit). Idempotent in QEMU, where
/// segments load directly into already-zeroed RAM and `_sidata == _data_start`.
pub inline fn runtimeInit() void {
    // Runtime pointers from linker addresses would emit alignment/null checks
    // whose panic path doesn't link here; the bounds are `ALIGN(4)`, so skip them.
    @setRuntimeSafety(false);
    const bss_start = @intFromPtr(@extern([*]u8, .{ .name = "_bss_start" }));
    const bss_end = @intFromPtr(@extern([*]u8, .{ .name = "_bss_end" }));
    const data_start = @intFromPtr(@extern([*]u8, .{ .name = "_data_start" }));
    const data_end = @intFromPtr(@extern([*]u8, .{ .name = "_data_end" }));
    const sidata = @intFromPtr(@extern([*]u8, .{ .name = "_sidata" }));

    var d = bss_start;
    while (d < bss_end) : (d +%= 4) @as(*volatile u32, @ptrFromInt(d)).* = 0;

    var s = sidata;
    d = data_start;
    while (d < data_end) : (d +%= 4) {
        @as(*volatile u32, @ptrFromInt(d)).* = @as(*const volatile u32, @ptrFromInt(s)).*;
        s +%= 4;
    }
}

/// Disable the timer-group and RTC watchdogs. A second-stage bootloader leaves
/// the TIMG0 "flash boot" watchdog (and others) running, so an app that neither
/// feeds nor disables them is reset within seconds on real hardware.
///
/// `R` is the chip's generated `regs` module. The RTC watchdog is only touched
/// when that peripheral exposes the unlock register under this name (it differs
/// on some chips), so the same code is correct for every target.
pub inline fn disableWatchdogs(comptime R: type) void {
    const unlock = reg.wdt_wprotect_key; // *_WDTWPROTECT unlock key

    inline for (.{ R.TIMG0, R.TIMG1 }) |tg| {
        mmio.writeReg(tg.WDTWPROTECT, unlock); // unlock
        mmio.writeReg(tg.WDTCONFIG0, 0); // clear enable + all stage actions
        mmio.writeReg(tg.WDTWPROTECT, 0); // re-lock
    }

    if (@hasDecl(R.RTC_CNTL, "WDTWPROTECT")) {
        mmio.writeReg(R.RTC_CNTL.WDTWPROTECT, unlock);
        mmio.writeReg(R.RTC_CNTL.WDTCONFIG0, 0);
        mmio.writeReg(R.RTC_CNTL.WDTWPROTECT, 0);
    }
}

// ── ESP-IDF application descriptor ──────────────────────────────────────────
// The ESP-IDF image format expects a 256-byte `esp_app_desc_t` at the start of
// the DROM mapping (image offset 0x20, right after the image + first-segment
// headers). It isn't needed to boot — the second-stage bootloader checks the
// image header — but emitting it makes the firmware introspectable by the
// vendor tooling (`esptool image_info`, `espflash`, idf-monitor) and OTA-ready.
// The linker scripts place `.rodata_desc` first in `drom_seg` and `KEEP` it.

const EspAppDesc = extern struct {
    magic_word: u32, // ESP_APP_DESC_MAGIC_WORD
    secure_version: u32,
    reserv1: [2]u32,
    version: [32]u8,
    project_name: [32]u8,
    time: [16]u8,
    date: [16]u8,
    idf_ver: [32]u8,
    app_elf_sha256: [32]u8, // filled in by the image tool
    min_efuse_blk_rev_full: u16,
    max_efuse_blk_rev_full: u16,
    mmu_page_size: u8, // log2(page) — 64 KiB on every chip here
    reserv3: [3]u8,
    reserv2: [18]u32,
};

/// A `[n]u8` holding `s`, zero-padded (a C string field). Comptime only.
fn cField(comptime n: usize, comptime s: []const u8) [n]u8 {
    var a = [_]u8{0} ** n;
    for (s, 0..) |c, i| a[i] = c;
    return a;
}

/// Emitted into every flash firmware (kept by the linker's `KEEP`). `export` so
/// the tooling can find it by name as well as by offset.
pub export const esp_app_desc: EspAppDesc linksection(".rodata_desc") = .{
    .magic_word = 0xABCD_5432,
    .secure_version = 0,
    .reserv1 = .{ 0, 0 },
    .version = cField(32, "0.1.0"),
    .project_name = cField(32, "esp32-baremetal-zig"),
    .time = cField(16, ""),
    .date = cField(16, ""),
    .idf_ver = cField(32, ""),
    .app_elf_sha256 = [_]u8{0} ** 32,
    .min_efuse_blk_rev_full = 0,
    .max_efuse_blk_rev_full = 0,
    .mmu_page_size = 16,
    .reserv3 = .{ 0, 0, 0 },
    .reserv2 = [_]u32{0} ** 18,
};
