// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Exception-path test: bus errors must propagate through the (uncached) cache bypass path and
// raise precise access-fault exceptions; ECALL and illegal instructions must trap as well.
// Also exercises the RVFI checker's trap handling (control flow resumes in the handler).

#include "perf.h"
#include "platform.h"

static volatile uint32_t trap_count;
static volatile uint32_t last_cause, last_tval, last_epc;
static volatile uint32_t resume_pc;  // where to resume after an instruction access fault

#define MCAUSE_INSTR_ACCESS 1
#define MCAUSE_ILLEGAL      2
#define MCAUSE_LOAD_ACCESS  5
#define MCAUSE_STORE_ACCESS 7
#define MCAUSE_ECALL_M      11

uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  trap_count++;
  last_cause = mcause;
  last_tval = mtval;
  last_epc = mepc;
  if (mcause == MCAUSE_INSTR_ACCESS) return resume_pc;
  // Skip the faulting instruction (2 or 4 bytes)
  uint16_t lo = *(volatile uint16_t *)mepc;
  return mepc + (((lo & 3) == 3) ? 4 : 2);
}

int main(void) {
  volatile uint32_t *bad = (volatile uint32_t *)TB_UNMAPPED_ADDR;

  perf_start();

  // Load access fault
  uint32_t v = *bad;
  (void)v;
  CHECK(trap_count == 1);
  CHECK(last_cause == MCAUSE_LOAD_ACCESS);
  CHECK(last_tval == TB_UNMAPPED_ADDR);

  // Store access fault
  *bad = 0xdeadbeef;
  CHECK(trap_count == 2);
  CHECK(last_cause == MCAUSE_STORE_ACCESS);
  CHECK(last_tval == TB_UNMAPPED_ADDR);

  // ECALL from M-mode
  __asm__ volatile("ecall");
  CHECK(trap_count == 3);
  CHECK(last_cause == MCAUSE_ECALL_M);

  // Illegal instruction: a 32-bit custom-0 opcode (not implemented by Ibex). Note that the
  // all-zero word would be *two* illegal 16-bit instructions (0x0000 is the reserved RVC encoding).
  __asm__ volatile(".4byte 0x0000000b");
  CHECK(trap_count == 4);
  CHECK(last_cause == MCAUSE_ILLEGAL);
  CHECK(last_tval == 0x0000000b);

  // Instruction access fault: jump into unmapped space, resume at label 1
  __asm__ volatile(
      "la   t0, 1f\n"
      "sw   t0, %0\n"
      "li   t1, %1\n"
      "jalr ra, 0(t1)\n"
      "1:\n"
      : "=m"(resume_pc)
      : "i"(TB_UNMAPPED_ADDR)
      : "t0", "t1", "ra", "memory");
  CHECK(trap_count == 5);
  CHECK(last_cause == MCAUSE_INSTR_ACCESS);
  CHECK(last_epc == TB_UNMAPPED_ADDR);

  perf_finish("bus_error");
  tb_printf("bus_error: PASS\n");
  return 0;
}
