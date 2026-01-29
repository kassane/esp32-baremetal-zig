/* Minimal bare-metal linker script for ESP32-S3 */

ENTRY(call_start_cpu0)

MEMORY
{
  /* IRAM - Instruction RAM */
  iram0_0_seg (RX) : ORIGIN = 0x40370000, LENGTH = 0x10000  /* 64KB */
  
  /* DRAM - Data RAM */
  dram0_0_seg (RW) : ORIGIN = 0x3FC88000, LENGTH = 0x78000  /* 480KB */
  
  /* External Flash - Read-only code and data */
  irom0_0_seg (RX) : ORIGIN = 0x42000000, LENGTH = 0x400000 /* 4MB */
  drom0_0_seg (R)  : ORIGIN = 0x3C000000, LENGTH = 0x400000 /* 4MB */
  
  /* RTC RAM */
  rtc_iram_seg (RWX) : ORIGIN = 0x600fe000, LENGTH = 0x2000 /* 8KB */
  rtc_dram_seg (RW)  : ORIGIN = 0x600fe000, LENGTH = 0x2000 /* 8KB */
}

SECTIONS
{
  /* Code in IRAM */
  .iram0.text :
  {
    _iram_start = ABSOLUTE(.);
    *(.iram1 .iram1.*)
    *(.iram0.literal .iram.literal .iram.text.literal .iram0.text .iram.text)
    *libgcc.a:(.literal .text .literal.* .text.*)
    _iram_end = ABSOLUTE(.);
  } > iram0_0_seg

  /* Data in DRAM */
  .dram0.data :
  {
    _data_start = ABSOLUTE(.);
    *(.data .data.*)
    *(.dram1 .dram1.*)
    _data_end = ABSOLUTE(.);
  } > dram0_0_seg

  /* BSS in DRAM */
  .dram0.bss (NOLOAD) :
  {
    _bss_start = ABSOLUTE(.);
    *(.bss .bss.*)
    *(COMMON)
    _bss_end = ABSOLUTE(.);
  } > dram0_0_seg

  /* Code in Flash */
  .flash.text :
  {
    _stext = .;
    *(.literal .text .literal.* .text.* .stub)
    *(.gnu.linkonce.literal.* .gnu.linkonce.t.*.literal .gnu.linkonce.t.*)
    *(.irom0.text)
    _etext = .;
  } > irom0_0_seg

  /* Read-only data in Flash */
  .flash.rodata :
  {
    _rodata_start = ABSOLUTE(.);
    *(.rodata .rodata.*)
    *(.gnu.linkonce.r.*)
    *(.rodata1)
    _rodata_end = ABSOLUTE(.);
  } > drom0_0_seg

  /* Heap */
  .heap :
  {
    _heap_start = ABSOLUTE(.);
    . = . + 0x10000; /* 64KB heap */
    _heap_end = ABSOLUTE(.);
  } > dram0_0_seg

  /* Stack at the end of DRAM */
  _stack_end = ORIGIN(dram0_0_seg) + LENGTH(dram0_0_seg);
  _stack_start = _stack_end - 0x4000; /* 16KB stack */
}