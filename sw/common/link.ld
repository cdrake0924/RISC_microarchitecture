/* Copyright 2026 RISC_microarchitecture contributors.
   Licensed under the Apache License, Version 2.0, see LICENSE for details.
   SPDX-License-Identifier: Apache-2.0

   Linker script for the Ibex core-complex testbench: 1 MiB of RAM at 0x0 (cacheable).
   Vectors at 0x0 (boot_addr), reset entry at 0x80, stack grows down from the top of RAM. */

OUTPUT_ARCH(riscv)
ENTRY(reset_handler)

MEMORY
{
  ram (rwx) : ORIGIN = 0x00000000, LENGTH = 1M
}

_stack_top = ORIGIN(ram) + LENGTH(ram);

SECTIONS
{
  .vectors 0x0 :
  {
    KEEP(*(.vectors))
  } > ram

  .text :
  {
    . = ALIGN(4);
    KEEP(*(.text.start))
    *(.text .text.*)
  } > ram

  .rodata :
  {
    . = ALIGN(4);
    *(.srodata .srodata.*)
    *(.rodata .rodata.*)
  } > ram

  .data :
  {
    . = ALIGN(4);
    __DATA_BEGIN__ = .;
    *(.data .data.*)
    __SDATA_BEGIN__ = .;
    *(.sdata .sdata.*)
  } > ram

  .bss (NOLOAD) :
  {
    . = ALIGN(4);
    _bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > ram

  _end = .;
  __global_pointer$ = MIN(__SDATA_BEGIN__ + 0x800, MAX(__DATA_BEGIN__ + 0x800, _bss_end - 0x800));

  /DISCARD/ : { *(.note.GNU-stack) *(.comment) *(.riscv.attributes) }
}
