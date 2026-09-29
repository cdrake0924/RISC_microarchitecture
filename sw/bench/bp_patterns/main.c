// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// bp_patterns: branch-predictor microbenchmarks.
//
// Each kernel is written in inline assembly so the compiler cannot if-convert the measured branch.
// The kernels isolate what each predictor can and cannot learn:
//
//   bp_always     branch always taken                 -> every predictor learns it
//   bp_alternate  T,NT,T,NT,...                       -> needs history (gshare); bimodal thrashes
//   bp_period4    T,T,T,NT repeating                  -> bimodal ~75%, gshare ~100%
//   bp_period8    8-long irregular pattern            -> needs >= 8 bits of history
//   bp_random     independent random outcomes         -> ~50% for every predictor
//   bp_correlated two branches on the same random bit -> 2nd is predictable only from history
//
// Every kernel also contains the loop back-edge branch (taken until exit), which all dynamic
// predictors learn; its effect is identical across kernels.

#include "perf.h"
#include "platform.h"

#define ITERS 4096

static uint8_t random_bits[ITERS];

// Branch on bit (i % period) of `pattern`; returns the number of iterations where the bit was 1.
static uint32_t pattern_kernel(uint32_t iters, uint32_t pattern, uint32_t period_mask) {
  uint32_t ones;
  __asm__ volatile(
      "li   t1, 0\n"
      "li   %0, 0\n"
      "1:\n"
      "and  t3, t1, %3\n"
      "srl  t4, %2, t3\n"
      "andi t4, t4, 1\n"
      "beqz t4, 2f\n"  // measured branch
      "addi %0, %0, 1\n"
      "2:\n"
      "addi t1, t1, 1\n"
      "bne  t1, %1, 1b\n"
      : "=&r"(ones)
      : "r"(iters), "r"(pattern), "r"(period_mask)
      : "t1", "t3", "t4");
  return ones;
}

// Branch on a stream of random bits.
static uint32_t random_kernel(uint32_t iters, const uint8_t *bits) {
  uint32_t ones;
  __asm__ volatile(
      "li   t1, 0\n"
      "li   %0, 0\n"
      "mv   t2, %2\n"
      "1:\n"
      "lbu  t3, 0(t2)\n"
      "beqz t3, 2f\n"  // measured branch
      "addi %0, %0, 1\n"
      "2:\n"
      "addi t2, t2, 1\n"
      "addi t1, t1, 1\n"
      "bne  t1, %1, 1b\n"
      : "=&r"(ones)
      : "r"(iters), "r"(bits)
      : "t1", "t2", "t3", "memory");
  return ones;
}

// Two branches on the same random bit: the second is fully determined by the first.
static uint32_t correlated_kernel(uint32_t iters, const uint8_t *bits) {
  uint32_t acc;
  __asm__ volatile(
      "li   t1, 0\n"
      "li   %0, 0\n"
      "mv   t2, %2\n"
      "1:\n"
      "lbu  t3, 0(t2)\n"
      "beqz t3, 2f\n"  // branch A: random
      "addi %0, %0, 1\n"
      "2:\n"
      "beqz t3, 3f\n"  // branch B: same outcome as A
      "addi %0, %0, 2\n"
      "3:\n"
      "addi t2, t2, 1\n"
      "addi t1, t1, 1\n"
      "bne  t1, %1, 1b\n"
      : "=&r"(acc)
      : "r"(iters), "r"(bits)
      : "t1", "t2", "t3", "memory");
  return acc;
}

static uint32_t popcount_pattern(uint32_t pattern, uint32_t period, uint32_t iters) {
  uint32_t ones = 0;
  for (uint32_t i = 0; i < iters; i++) ones += (pattern >> (i % period)) & 1;
  return ones;
}

int main(void) {
  uint32_t rng = 31337, random_ones = 0;
  for (int i = 0; i < ITERS; i++) {
    random_bits[i] = (uint8_t)(xorshift32(&rng) >> 31);
    random_ones += random_bits[i];
  }

  struct {
    const char *name;
    uint32_t pattern, period;
  } pats[] = {
      {"bp_always", 0x0, 1},
      {"bp_alternate", 0x1, 2},
      {"bp_period4", 0x1, 4},
      {"bp_period8", 0x5b, 8},
  };

  for (unsigned k = 0; k < sizeof(pats) / sizeof(pats[0]); k++) {
    perf_start();
    uint32_t ones = pattern_kernel(ITERS, pats[k].pattern, pats[k].period - 1);
    perf_finish(pats[k].name);
    CHECK(ones == popcount_pattern(pats[k].pattern, pats[k].period, ITERS));
  }

  perf_start();
  uint32_t r = random_kernel(ITERS, random_bits);
  perf_finish("bp_random");
  CHECK(r == random_ones);

  perf_start();
  uint32_t c = correlated_kernel(ITERS, random_bits);
  perf_finish("bp_correlated");
  CHECK(c == 3 * random_ones);

  tb_printf("bp_patterns: PASS\n");
  return 0;
}
