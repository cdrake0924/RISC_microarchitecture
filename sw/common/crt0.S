# Copyright lowRISC contributors (vector-table layout from ibex/examples/sw/simple_system).
# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Start-up code for programs running on the Ibex core-complex testbench.
#
# Ibex boots at boot_addr + 0x80 and uses a vectored mtvec: exceptions enter at mtvec + 0x00 and
# interrupt N at mtvec + 4*N. boot_addr = 0x0, so the vector table lives at address 0.

#include "platform.h"

  .section .vectors, "ax"
  .option push
  .option norvc
  .global _vectors
_vectors:
  .org 0x00
  j trap_entry                # exceptions
  .rept 6
  j trap_entry                # interrupts 1..6 (unused)
  .endr
  .org 0x1c
  j irq_entry                 # 7: machine timer interrupt
  .rept 23
  j trap_entry                # interrupts 8..30
  .endr
  .org 0x7c
  j trap_entry                # 31: NMI
  .org 0x80
  j reset_handler             # reset vector
  .option pop

  .section .text.start, "ax"
  .global reset_handler
reset_handler:
  .option push
  .option norelax
  la    gp, __global_pointer$
  .option pop
  la    sp, _stack_top

  # Clear .bss
  la    t0, _bss_start
  la    t1, _bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:
  call  main

  # exit(main()) - FENCE.I first so every dirty D-cache line reaches memory before the testbench
  # inspects it (and so every program exercises the FENCE.I coherence sequence once).
  mv    s0, a0
  fence.i
  li    t0, TB_EXIT_ADDR
  sw    s0, 0(t0)
3:
  wfi
  j     3b

# -----------------------------------------------------------------------------------------------
# Trap entry: save caller-saved registers, call the C handler, restore, return.
#   uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) -> new mepc
#   void     irq_handler(uint32_t mcause)
# Both are weak in platform.c and may be overridden by a test.
# -----------------------------------------------------------------------------------------------
  .macro SAVE_CONTEXT
  addi  sp, sp, -64
  sw    ra,  0(sp)
  sw    t0,  4(sp)
  sw    t1,  8(sp)
  sw    t2, 12(sp)
  sw    a0, 16(sp)
  sw    a1, 20(sp)
  sw    a2, 24(sp)
  sw    a3, 28(sp)
  sw    a4, 32(sp)
  sw    a5, 36(sp)
  sw    a6, 40(sp)
  sw    a7, 44(sp)
  sw    t3, 48(sp)
  sw    t4, 52(sp)
  sw    t5, 56(sp)
  sw    t6, 60(sp)
  .endm

  .macro RESTORE_CONTEXT
  lw    ra,  0(sp)
  lw    t0,  4(sp)
  lw    t1,  8(sp)
  lw    t2, 12(sp)
  lw    a0, 16(sp)
  lw    a1, 20(sp)
  lw    a2, 24(sp)
  lw    a3, 28(sp)
  lw    a4, 32(sp)
  lw    a5, 36(sp)
  lw    a6, 40(sp)
  lw    a7, 44(sp)
  lw    t3, 48(sp)
  lw    t4, 52(sp)
  lw    t5, 56(sp)
  lw    t6, 60(sp)
  addi  sp, sp, 64
  .endm

trap_entry:
  SAVE_CONTEXT
  csrr  a0, mcause
  csrr  a1, mepc
  csrr  a2, mtval
  call  trap_handler
  csrw  mepc, a0
  RESTORE_CONTEXT
  mret

irq_entry:
  SAVE_CONTEXT
  csrr  a0, mcause
  call  irq_handler
  RESTORE_CONTEXT
  mret
