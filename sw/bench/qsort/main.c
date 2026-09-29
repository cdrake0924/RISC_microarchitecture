// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// qsort: recursive quicksort of 4096 pseudo-random integers.
// Character: data-dependent comparison branches (hard to predict), recursion (calls/returns),
// 16 KiB working set (larger than the default L1 D-cache).

#include "perf.h"
#include "platform.h"

#define N 4096

static int32_t data[N];

static void quicksort(int32_t *a, int lo, int hi) {
  while (lo < hi) {
    int32_t pivot = a[lo + (hi - lo) / 2];
    int i = lo, j = hi;
    while (i <= j) {
      while (a[i] < pivot) i++;
      while (a[j] > pivot) j--;
      if (i <= j) {
        int32_t t = a[i];
        a[i] = a[j];
        a[j] = t;
        i++;
        j--;
      }
    }
    // Recurse into the smaller half, loop on the larger one (bounded stack depth)
    if (j - lo < hi - i) {
      quicksort(a, lo, j);
      lo = i;
    } else {
      quicksort(a, i, hi);
      hi = j;
    }
  }
}

int main(void) {
  uint32_t rng = 0xdeadbeef;
  uint32_t sum_before = 0, sum_after = 0;
  for (int i = 0; i < N; i++) {
    data[i] = (int32_t)(xorshift32(&rng) >> 1) - (1 << 30);
    sum_before += (uint32_t)data[i];
  }

  perf_start();
  quicksort(data, 0, N - 1);
  perf_finish("qsort");

  for (int i = 0; i < N; i++) {
    sum_after += (uint32_t)data[i];
    if (i > 0) CHECK(data[i - 1] <= data[i]);
  }
  CHECK(sum_before == sum_after);
  tb_printf("qsort: PASS\n");
  return 0;
}
