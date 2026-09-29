// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// stream: STREAM-style copy / scale / add / triad kernels on 3 arrays of 2048 words (24 KiB).
// Character: unit-stride streaming, so every miss is followed by (line_words - 1) hits; stores
// dirty every line, so evictions generate a steady write-back stream.

#include "perf.h"
#include "platform.h"

#define N 2048

static int32_t a[N], b[N], c[N];

int main(void) {
  for (int i = 0; i < N; i++) {
    a[i] = i;
    b[i] = 2 * i;
    c[i] = 0;
  }
  const int32_t s = 3;

  perf_start();
  for (int i = 0; i < N; i++) c[i] = a[i];             // copy
  for (int i = 0; i < N; i++) b[i] = s * c[i];         // scale
  for (int i = 0; i < N; i++) c[i] = a[i] + b[i];      // add
  for (int i = 0; i < N; i++) a[i] = b[i] + s * c[i];  // triad
  perf_finish("stream");

  // After the kernels: c = a0 + 3 a0 = 4i, b = 3i, a = 3i + 3*4i = 15i
  for (int i = 0; i < N; i++) {
    CHECK(b[i] == 3 * i);
    CHECK(c[i] == 4 * i);
    CHECK(a[i] == 15 * i);
  }
  tb_printf("stream: PASS\n");
  return 0;
}
