/* QEMU-only linker script for ESP32-S3.
 *
 * Places all code and read-only data in IRAM so that qemu-system-xtensa can
 * execute the ELF directly via -kernel without needing the ROM bootloader or
 * flash-cache MMU initialisation.  The IRAM region is sized larger than real
 * hardware (1 MB) to accommodate Debug builds; do NOT use this script for
 * real-hardware flashing.
 */

ENTRY(call_start_cpu0)

MEMORY
{
  /* IRAM – directly executable by the CPU, no cache needed.
     Sized to 1 MB for QEMU (real hw: ~400 KB). */
  iram0_0_seg (RX) : ORIGIN = 0x40370000, LENGTH = 1M

  /* DRAM – data/BSS */
  dram0_0_seg (RW) : ORIGIN = 0x3FC88000, LENGTH = 300K
}

SECTIONS
{
  .text : ALIGN(4)
  {
    _stext = .;
    *(.iram1 .iram1.*)
    *(.iram0.literal .iram.literal .iram.text.literal .iram0.text .iram.text)
    *(.literal .text .literal.* .text.*)
    _etext = .;
  } > iram0_0_seg

  .rodata : ALIGN(4)
  {
    _rodata_start = ABSOLUTE(.);
    *(.rodata .rodata.*)
    _rodata_end = ABSOLUTE(.);
  } > dram0_0_seg

  .data : ALIGN(4)
  {
    _data_start = ABSOLUTE(.);
    *(.data .data.*)
    _data_end = ABSOLUTE(.);
  } > dram0_0_seg AT > dram0_0_seg

  .bss (NOLOAD) : ALIGN(4)
  {
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.* COMMON)
    *(COMMON)
    _bss_end = ABSOLUTE(.);
  } > dram0_0_seg

  _stack_end   = ORIGIN(dram0_0_seg) + LENGTH(dram0_0_seg);
  _stack_start = _stack_end - 0x4000;
}
