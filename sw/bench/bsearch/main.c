// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// bsearch: 4096 binary searches over a sorted table of 8192 keys.
// Character: the "go left / go right" branch is essentially a coin flip (worst case for any
// direction predictor); scattered loads across a 32 KiB table.

#include "perf.h"
#include "platform.h"

#define N 8192
#define QUERIES 4096

static uint32_t table[N];

static int find(uint32_t key) {
  int lo = 0, hi = N - 1;
  while (lo <= hi) {
    int mid = (lo + hi) >> 1;
    uint32_t v = table[mid];
    if (v == key) return mid;
    if (v < key) lo = mid + 1;
    else         hi = mid - 1;
  }
  return -1;
}

int main(void) {
  for (int i = 0; i < N; i++) table[i] = (uint32_t)i * 3 + 1;  // sorted, gaps for misses

  uint32_t rng = 99;
  int found = 0;
  uint32_t idx_sum = 0;

  perf_start();
  for (int q = 0; q < QUERIES; q++) {
    uint32_t key = xorshift32(&rng) % (3 * N);
    int r = find(key);
    if (r >= 0) {
      found++;
      idx_sum += (uint32_t)r;
    }
  }
  perf_finish("bsearch");

  // Reference: key k is present iff k % 3 == 1, at index k / 3
  uint32_t rng2 = 99, ref_idx = 0;
  int ref_found = 0;
  for (int q = 0; q < QUERIES; q++) {
    uint32_t key = xorshift32(&rng2) % (3 * N);
    if (key % 3 == 1) {
      ref_found++;
      ref_idx += key / 3;
    }
  }
  CHECK(found == ref_found);
  CHECK(idx_sum == ref_idx);
  tb_printf("bsearch: PASS (%d hits)\n", found);
  return 0;
}
