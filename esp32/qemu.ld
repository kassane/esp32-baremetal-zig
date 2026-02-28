/* QEMU-only linker script for ESP32 (Xtensa LX6).
 *
 * Places ALL code and read-only data in IRAM so that qemu-system-xtensa
 * can execute the ELF directly via -kernel without needing the ROM bootloader
 * or flash-cache MMU initialisation.
 *
 * Correct ESP32 IRAM base: 0x40080000 (IDF bootloader.ld.in / memory.ld.in).
 * IRAM is sized to 1 MB here (real hw: 128 KB) to accommodate Debug builds.
 * Do NOT use this script for real-hardware flashing.
 */

ENTRY(Reset)

MEMORY
{
  /* ESP32 IRAM – directly executable, no cache init required.
     Real hardware: 0x40080000, 128 KB; QEMU: extended to 1 MB. */
  iram_seg (RX) : ORIGIN = 0x40080000, LENGTH = 1M

  /* DRAM – real addresses, 176 KB as per IDF. */
  dram_seg (RW) : ORIGIN = 0x3FFB0000, LENGTH = 0x2C200
}

SECTIONS
{
  .text : ALIGN(4)
  {
    _stext = .;
    *(.literal .text .literal.* .text.*)
    _etext = .;
  } > iram_seg

  .rodata : ALIGN(4)
  {
    _rodata_start = ABSOLUTE(.);
    *(.rodata .rodata.*)
    _rodata_end = ABSOLUTE(.);
  } > dram_seg

  .data : ALIGN(4)
  {
    _data_start = ABSOLUTE(.);
    *(.data .data.*)
    _data_end = ABSOLUTE(.);
  } > dram_seg

  .bss (NOLOAD) : ALIGN(4)
  {
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    _bss_end = ABSOLUTE(.);
  } > dram_seg
}
