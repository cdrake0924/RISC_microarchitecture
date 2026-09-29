// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// matmul: 40x40 integer matrix multiply, C = A * B.
// Character: highly regular loop branches (easy to predict), multiply-heavy, 3 x 6.4 KiB matrices
// with a column-strided access to B (poor spatial locality for B, strong temporal reuse of A rows).

#include "perf.h"
#include "platform.h"

#define N 40

static int32_t A[N][N], B[N][N], C[N][N];

int main(void) {
  uint32_t rng = 7;
  for (int i = 0; i < N; i++) {
    for (int j = 0; j < N; j++) {
      A[i][j] = (int32_t)(xorshift32(&rng) & 0xff) - 128;
      B[i][j] = (int32_t)(xorshift32(&rng) & 0xff) - 128;
    }
  }

  perf_start();
  for (int i = 0; i < N; i++) {
    for (int j = 0; j < N; j++) {
      int32_t acc = 0;
      for (int k = 0; k < N; k++) acc += A[i][k] * B[k][j];
      C[i][j] = acc;
    }
  }
  perf_finish("matmul");

  // Check: sum over C equals (column sums of A) . (row sums of B)
  int32_t sum_c = 0, check = 0;
  for (int i = 0; i < N; i++)
    for (int j = 0; j < N; j++) sum_c += C[i][j];
  for (int k = 0; k < N; k++) {
    int32_t col_a = 0, row_b = 0;
    for (int i = 0; i < N; i++) col_a += A[i][k];
    for (int j = 0; j < N; j++) row_b += B[k][j];
    check += col_a * row_b;
  }
  CHECK(sum_c == check);
  tb_printf("matmul: PASS\n");
  return 0;
}
