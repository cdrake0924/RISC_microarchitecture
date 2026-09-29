// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// fib: naive recursive Fibonacci.
// Character: call/return dominated (JAL/JALR every few instructions), a base-case branch whose
// outcome follows the recursion tree, heavy stack traffic with excellent locality.

#include "perf.h"
#include "platform.h"

__attribute__((noinline)) static uint32_t fib(uint32_t n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}

int main(void) {
  perf_start();
  uint32_t r = fib(20);
  perf_finish("fib");

  CHECK(r == 6765);
  tb_printf("fib: PASS\n");
  return 0;
}
