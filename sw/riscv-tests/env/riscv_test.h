// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// riscv-tests target environment for the Ibex core-complex testbench.
//
// Replaces the upstream "p" environment (HTIF tohost/fromhost + ecall) with the testbench's
// memory-mapped exit register, following the CV32E40P example-testbench convention:
//   pass -> write 0 to TB_EXIT_ADDR
//   fail -> write (TESTNUM << 1) | 1 to TB_EXIT_ADDR  (always non-zero, encodes the failing case)
// Every exit is preceded by FENCE.I so dirty D-cache lines reach memory before the testbench
// inspects it.

#ifndef _ENV_IBEX_CC_RISCV_TEST_H
#define _ENV_IBEX_CC_RISCV_TEST_H

#include "platform.h"

#define RVTEST_RV64U .macro init; .endm
#define RVTEST_RV32U .macro init; .endm

#define TESTNUM gp

// Vectors at boot_addr (0x0); Ibex starts executing at boot_addr + 0x80.
#define RVTEST_CODE_BEGIN                                                 \
  .section .vectors, "ax";                                                \
  .option push;                                                           \
  .option norvc;                                                          \
  .org 0x00;                                                              \
  .rept 32;                                                               \
  j trap_vector;                                                          \
  .endr;                                                                  \
  .org 0x80;                                                              \
  j reset_handler;                                                        \
  .option pop;                                                            \
  .section .text.start, "ax";                                             \
  .align 2;                                                               \
trap_vector:                                                              \
  /* Any trap is unexpected in the user-level ISA tests: exit(0xfff) */   \
  fence.i;                                                                \
  li t0, TB_EXIT_ADDR;                                                    \
  li t1, 0xfff;                                                           \
  sw t1, 0(t0);                                                           \
  j trap_vector;                                                          \
  .global reset_handler;                                                  \
reset_handler:                                                            \
  li x1, 0;  li x2, 0;  li x3, 0;  li x4, 0;  li x5, 0;  li x6, 0;       \
  li x7, 0;  li x8, 0;  li x9, 0;  li x10, 0; li x11, 0; li x12, 0;      \
  li x13, 0; li x14, 0; li x15, 0; li x16, 0; li x17, 0; li x18, 0;      \
  li x19, 0; li x20, 0; li x21, 0; li x22, 0; li x23, 0; li x24, 0;      \
  li x25, 0; li x26, 0; li x27, 0; li x28, 0; li x29, 0; li x30, 0;      \
  li x31, 0;                                                              \
  init;

#define RVTEST_CODE_END                                                   \
  unimp

#define RVTEST_PASS                                                       \
  fence.i;                                                                \
  li t0, TB_EXIT_ADDR;                                                    \
  sw zero, 0(t0);                                                         \
1:                                                                        \
  j 1b;

#define RVTEST_FAIL                                                       \
  fence.i;                                                                \
  slli a0, TESTNUM, 1;                                                    \
  ori a0, a0, 1;                                                          \
  li t0, TB_EXIT_ADDR;                                                    \
  sw a0, 0(t0);                                                           \
1:                                                                        \
  j 1b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                                 \
  EXTRA_DATA                                                              \
  .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END                                                   \
  .align 4; .global end_signature; end_signature:

#endif
