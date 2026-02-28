/* ESP32 (Xtensa LX6) memory map.
 *
 * Addresses verified against:
 *   - ESP-IDF v6.0 components/esp_system/ld/esp32/memory.ld.in
 *   - ESP-IDF v6.0 components/bootloader/subproject/main/ld/esp32/bootloader.ld.in
 *   - ESP32 Technical Reference Manual rev 3.7, section "System Memory Map"
 *
 * NOTE: Earlier versions of this file incorrectly used ESP32-S3 addresses
 * (0x40370000 / 0x42000020 / 0x3C000020). Those are fixed here.
 */

MEMORY
{
  /* Instruction SRAM 0 + SRAM 1 (directly executable, no cache needed)
     IDF: iram0_0_seg org = 0x40080000, len = 0x20000 (128 KB).
     SRAM 1 instruction portion starts at 0x400A0000 (when enabled). */
  iram_seg  (RX)  : ORIGIN = 0x40080000, LENGTH = 0x20000  /* 128 KB */

  /* Shared D/IRAM viewed as DRAM (data bus side)
     IDF: dram0_0_seg org = 0x3FFB0000, len = 0x2c200 (~176 KB, no BT reserve). */
  dram_seg  (RW)  : ORIGIN = 0x3FFB0000, LENGTH = 0x2C200

  /* External Flash – instruction side (mapped via ICache at 0x400C0000-0x40BFFFFF)
     IDF: iram0_2_seg org = 0x400D0020, len = 0x330000-0x20 (~3.2 MB).
     0x20 offset: aligns flash cache MMU constraint paddr%64KB == vaddr%64KB. */
  irom_seg  (RX)  : ORIGIN = 0x400D0020, LENGTH = 0x330000 - 0x20

  /* External Flash – data side (mapped via DCache at 0x3F400000-0x3F7FFFFF)
     IDF: drom0_0_seg org = 0x3F400020, len = 0x400000-0x20 (4 MB). */
  drom_seg  (R)   : ORIGIN = 0x3F400020, LENGTH = 0x400000 - 0x20

  /* RTC fast memory – instruction side, executable, persists over deep sleep.
     IDF: rtc_iram_seg org = 0x400C0000, len = 0x2000. */
  rtc_fast_seg (RWX) : ORIGIN = 0x400C0000, LENGTH = 0x2000  /* 8 KB */

  /* RTC slow memory – data side, persists over deep sleep.
     IDF: rtc_slow_seg org = 0x50000000, len = 0x2000. */
  rtc_slow_seg (RW)  : ORIGIN = 0x50000000, LENGTH = 0x2000  /* 8 KB */
}

REGION_ALIAS("ROTEXT",       irom_seg);
REGION_ALIAS("RWTEXT",       iram_seg);
REGION_ALIAS("RODATA",       drom_seg);
REGION_ALIAS("RWDATA",       dram_seg);
REGION_ALIAS("RTC_FAST_RWTEXT", rtc_fast_seg);
REGION_ALIAS("RTC_FAST_RWDATA", rtc_fast_seg);
