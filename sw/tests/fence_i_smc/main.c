// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Self-modifying code / FENCE.I coherence test.
//
// With a write-back D-cache and a separate I-cache, newly written instructions can be (a) still in
// a dirty D-cache line and (b) shadowed by a stale I-cache line. FENCE.I must fix both. The test
// repeatedly rewrites a small function, executes FENCE.I and calls it, so every iteration needs the
// D-cache clean *and* the I-cache invalidate to have worked. A second, multi-line function checks
// code that spans several cache lines.

#include "perf.h"
#include "platform.h"

typedef uint32_t (*fn_t)(uint32_t);

// RV32I encodings
#define ADDI(rd, rs1, imm) ((((uint32_t)(imm)&0xfff) << 20) | ((rs1) << 15) | (0 << 12) | ((rd) << 7) | 0x13)
#define ADD(rd, rs1, rs2)  (((rs2) << 20) | ((rs1) << 15) | (0 << 12) | ((rd) << 7) | 0x33)
#define RET                0x00008067u  // jalr x0, 0(x1)
#define A0 10
#define A1 11

static uint32_t code_small[16] __attribute__((aligned(64)));
static uint32_t code_large[128] __attribute__((aligned(64)));

static inline void fence_i(void) { __asm__ volatile("fence.i" ::: "memory"); }

int main(void) {
  perf_start();

  // 1. Small function: a0 = a0 + k; ret. Rewritten 64 times with a different k.
  for (uint32_t k = 1; k <= 64; k++) {
    code_small[0] = ADDI(A0, A0, k);
    code_small[1] = RET;
    fence_i();
    uint32_t r = ((fn_t)(uintptr_t)code_small)(1000);
    if (r != 1000 + k) {
      tb_printf("small function iteration %u returned %u, expected %u\n", k, r, 1000 + k);
      return 1;
    }
  }

  // 2. Large function spanning many cache lines: a straight-line chain of 100 adds.
  for (uint32_t round = 0; round < 4; round++) {
    uint32_t n = 0;
    code_large[n++] = ADDI(A1, 0, round + 1);  // a1 = round + 1
    for (int i = 0; i < 100; i++) code_large[n++] = ADD(A0, A0, A1);
    code_large[n++] = RET;
    fence_i();
    uint32_t r = ((fn_t)(uintptr_t)code_large)(7);
    uint32_t expect = 7 + 100 * (round + 1);
    if (r != expect) {
      tb_printf("large function round %u returned %u, expected %u\n", round, r, expect);
      return 1;
    }
  }

  perf_finish("fence_i_smc");
  tb_printf("fence_i_smc: PASS\n");
  return 0;
}
