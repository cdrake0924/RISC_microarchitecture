// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// D-cache stress test.
//
// Works on a 32 KiB region (16x the default D-cache) with access patterns chosen to provoke
// conflict misses, dirty evictions and partial-word writes. Each phase checks an invariant that
// does not depend on cache behaviour; the testbench's memory scoreboard additionally checks every
// individual load against a reference memory.

#include "perf.h"
#include "platform.h"

#define REGION_BYTES (32 * 1024)
#define REGION_WORDS (REGION_BYTES / 4)

static uint32_t region[REGION_WORDS] __attribute__((aligned(64)));

static inline uint32_t hash32(uint32_t x) {
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

int main(void) {
  volatile uint8_t *bytes = (volatile uint8_t *)region;
  volatile uint16_t *halves = (volatile uint16_t *)region;
  uint32_t rng = 0x12345678;

  perf_start();

  // Phase 1: word writes with a large power-of-two stride so consecutive accesses map to the same
  // set (conflict misses, every eviction dirty).
  for (uint32_t stride = 1024; stride >= 1; stride >>= 1) {
    for (uint32_t base = 0; base < stride; base++) {
      for (uint32_t i = base; i < REGION_WORDS; i += stride) region[i] = hash32(i);
    }
    if (stride == 64) break;  // enough coverage, keep runtime reasonable
  }

  // Phase 2: read back in reverse order.
  for (int32_t i = REGION_WORDS - 1; i >= 0; i--) CHECK(region[i] == hash32((uint32_t)i));

  // Phase 3: byte read-modify-write, then verify.
  for (uint32_t i = 0; i < REGION_BYTES; i += 3) bytes[i] ^= (uint8_t)(i * 7);
  for (uint32_t i = 0; i < REGION_WORDS; i++) {
    uint32_t expect = hash32(i);
    for (uint32_t b = 0; b < 4; b++) {
      uint32_t byte_addr = i * 4 + b;
      if (byte_addr % 3 == 0) expect ^= (uint32_t)(uint8_t)(byte_addr * 7) << (8 * b);
    }
    CHECK(region[i] == expect);
  }

  // Phase 4: halfword writes, then misaligned word accesses (Ibex splits them into two bus
  // transactions, which may land in two different cache lines).
  for (uint32_t i = 0; i < REGION_BYTES / 2; i += 5) halves[i] = (uint16_t)(i ^ 0xa5a5);
  for (uint32_t i = 0; i < REGION_BYTES / 2; i += 5) CHECK(halves[i] == (uint16_t)(i ^ 0xa5a5));

  for (uint32_t off = 1; off < 4; off++) {
    for (uint32_t i = 0; i < 256; i++) {
      volatile uint32_t *p = (volatile uint32_t *)((uintptr_t)region + i * 60 + off);
      *p = 0xc0de0000u | (i << 2) | off;
    }
    for (uint32_t i = 0; i < 256; i++) {
      volatile uint32_t *p = (volatile uint32_t *)((uintptr_t)region + i * 60 + off);
      CHECK(*p == (0xc0de0000u | (i << 2) | off));
    }
  }

  // Phase 5: random read-modify-write. The sum of the region must equal its initial sum plus the
  // sum of every increment, independent of the order in which lines were evicted.
  uint32_t sum0 = 0;
  for (uint32_t i = 0; i < REGION_WORDS; i++) sum0 += region[i];
  uint32_t added = 0;
  for (uint32_t n = 0; n < 20000; n++) {
    uint32_t r = xorshift32(&rng);
    uint32_t idx = r % REGION_WORDS;
    uint32_t inc = r >> 7;
    region[idx] += inc;
    added += inc;
  }
  uint32_t sum1 = 0;
  for (uint32_t i = 0; i < REGION_WORDS; i++) sum1 += region[i];
  CHECK(sum1 == sum0 + added);

  perf_finish("cache_stress");
  tb_printf("cache_stress: PASS\n");
  return 0;
}
