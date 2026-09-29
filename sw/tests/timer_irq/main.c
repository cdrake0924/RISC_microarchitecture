// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Interrupt test: timer interrupts arriving while branchy, memory-heavy code runs must not disturb
// program results. Interrupts land at arbitrary points (including between a predicted-taken branch
// and its target and during cache refills), so this covers asynchronous flushes of the predictor
// and cache pipelines.

#include "perf.h"
#include "platform.h"

#define NUM_TICKS 20

static volatile uint32_t ticks;
static uint32_t data[512];

void irq_handler(uint32_t mcause) {
  if (mcause != 0x80000007u) {
    tb_printf("unexpected interrupt cause 0x%08x\n", mcause);
    tb_exit(1);
  }
  ticks++;
  if (ticks < NUM_TICKS) {
    tb_timer_arm(1500 + (ticks * 977) % 3000);  // irregular intervals
  } else {
    tb_timer_disable();
  }
}

int main(void) {
  uint32_t rng = 42, checksum = 0, rounds = 0;

  perf_start();
  tb_timer_arm(300);
  tb_irq_enable();

  while (ticks < NUM_TICKS) {
    for (uint32_t i = 0; i < 512; i++) data[i] = xorshift32(&rng);
    for (uint32_t i = 0; i < 512; i++) {
      if (data[i] & 1) checksum += data[i];
      else             checksum ^= data[i] >> 3;
    }
    rounds++;
  }

  // Recompute the same number of rounds with interrupts disabled and compare.
  tb_irq_disable();
  uint32_t rng2 = 42, checksum2 = 0;
  for (uint32_t r = 0; r < rounds; r++) {
    for (uint32_t i = 0; i < 512; i++) data[i] = xorshift32(&rng2);
    for (uint32_t i = 0; i < 512; i++) {
      if (data[i] & 1) checksum2 += data[i];
      else             checksum2 ^= data[i] >> 3;
    }
  }
  CHECK(checksum == checksum2);
  CHECK(ticks == NUM_TICKS);

  // WFI wake-up. Arm with mstatus.MIE clear so the interrupt cannot be taken before the WFI; WFI
  // wakes on a pending enabled interrupt regardless of MIE, then enabling MIE takes it.
  MMIO32(TB_TIMER_CTRL_ADDR) = 1u << 7;
  MMIO32(TB_TIMER_CNT_ADDR) = 200;
  set_csr(mie, 1u << 7);
  __asm__ volatile("wfi");
  tb_irq_enable();
  __asm__ volatile("nop; nop; nop; nop");
  CHECK(ticks == NUM_TICKS + 1);

  perf_finish("timer_irq");
  tb_printf("timer_irq: PASS (%u interrupts over %u rounds)\n", ticks, rounds);
  return 0;
}
