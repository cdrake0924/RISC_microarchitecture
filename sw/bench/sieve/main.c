// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// sieve: Sieve of Eratosthenes up to 64000 over a byte array.
// Character: byte stores with growing strides over a 62.5 KiB array (large D-cache footprint,
// many dirty evictions); the "is still prime?" test branch becomes increasingly biased.

#include "perf.h"
#include "platform.h"

#define LIMIT 64000

static uint8_t composite[LIMIT];

int main(void) {
  perf_start();
  uint32_t count = 0;
  for (uint32_t i = 2; i < LIMIT; i++) {
    if (!composite[i]) {
      count++;
      for (uint32_t j = i * i; j < LIMIT; j += i) composite[j] = 1;
    }
  }
  perf_finish("sieve");

  CHECK(count == 6413);  // pi(64000)
  tb_printf("sieve: PASS (%u primes)\n", count);
  return 0;
}
