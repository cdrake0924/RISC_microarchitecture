// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Function call / return / indirect-jump test for the return address stack and the BTB.
//
//   deep recursion      24 levels, three times the RAS depth: overflow loses the oldest return
//                       addresses, so the outermost returns mispredict and must be repaired
//   mutual recursion    alternating call sites
//   alternate link reg  calls through x5 (t0) instead of ra (push/pop with the other link register)
//   co-routine swap     `jalr t0, 0(ra)`: rd and rs1 are different link registers -> pop then push
//   function pointers   an indirect call site whose target changes: BTB hits, misses, wrong targets
//   jump table          a dense switch compiled to an indirect jump through a table
//
// Every result is compared with a value computed in closed form; the testbench's RVFI and redirect
// checkers verify every retired control transfer and every pipeline redirect.

#include "perf.h"
#include "platform.h"

// The empty asm makes the recursive result opaque, so GCC cannot turn the recursion into a loop
// (tail-recursion elimination with an accumulator) and every level is a real call and return.
#define OPAQUE(x) __asm__ volatile("" : "+r"(x))

__attribute__((noinline)) static uint32_t sum_rec(uint32_t n) {
  if (n == 0) return 0;
  uint32_t r = sum_rec(n - 1);
  OPAQUE(r);
  return n + r;
}

__attribute__((noinline)) static uint32_t is_odd(uint32_t n);
__attribute__((noinline)) static uint32_t is_even(uint32_t n) {
  if (n == 0) return 1;
  uint32_t r = is_odd(n - 1);
  OPAQUE(r);
  return r;
}
__attribute__((noinline)) static uint32_t is_odd(uint32_t n) {
  if (n == 0) return 0;
  uint32_t r = is_even(n - 1);
  OPAQUE(r);
  return r;
}

typedef uint32_t (*op_fn)(uint32_t, uint32_t);
__attribute__((noinline)) static uint32_t op_add(uint32_t a, uint32_t b) { return a + b; }
__attribute__((noinline)) static uint32_t op_sub(uint32_t a, uint32_t b) { return a - b; }
__attribute__((noinline)) static uint32_t op_xor(uint32_t a, uint32_t b) { return a ^ b; }
__attribute__((noinline)) static uint32_t op_mul(uint32_t a, uint32_t b) { return a * b; }
static op_fn const ops[4] = {op_add, op_sub, op_xor, op_mul};

__attribute__((noinline)) static uint32_t jump_table(uint32_t sel, uint32_t x) {
  switch (sel) {
    case 0: return x + 11;
    case 1: return x * 3;
    case 2: return x ^ 0x5a5a;
    case 3: return x - 7;
    case 4: return x << 2;
    case 5: return x >> 1;
    case 6: return ~x;
    case 7: return x * x;
    case 8: return x | 0x100;
    case 9: return x & 0xff;
    default: return 0;
  }
}

// Call a leaf through the alternate link register x5: `jal t0, leaf` ... `jr t0`
static uint32_t call_via_t0(uint32_t v) {
  uint32_t r;
  __asm__ volatile(
      "mv   a0, %1\n"
      "jal  t0, 1f\n"
      "j    2f\n"
      "1:\n"
      "addi a0, a0, 3\n"
      "jr   t0\n"
      "2:\n"
      "mv   %0, a0\n"
      : "=r"(r)
      : "r"(v)
      : "a0", "t0");
  return r;
}

// Co-routine style control transfer: `jalr t0, 0(ra)` returns to the caller (pop) while saving
// its own continuation (push); the caller then resumes it with `jr t0` (pop).
static uint32_t coroutine_swap(uint32_t v) {
  uint32_t r;
  __asm__ volatile(
      "mv   a0, %1\n"
      "jal  ra, 1f\n"      // call the co-routine (push L1)
      "addi a0, a0, 5\n"   // L1: back from the swap
      "jr   t0\n"          // resume the co-routine (pop L2)
      "1:\n"
      "jalr t0, 0(ra)\n"   // swap: jump to L1 (pop), continuation L2 in t0 (push)
      "addi a0, a0, 7\n"   // L2
      "mv   %0, a0\n"
      : "=r"(r)
      : "r"(v)
      : "a0", "t0", "ra");
  return r;
}

int main(void) {
  perf_start();

  // Co-routine swaps
  for (uint32_t v = 0; v < 20; v++) CHECK(coroutine_swap(v) == v + 12);

  // Deep recursion (overflows an 8-entry RAS three times over)
  for (uint32_t n = 1; n <= 24; n++) CHECK(sum_rec(n) == n * (n + 1) / 2);

  // Mutual recursion
  for (uint32_t n = 0; n < 40; n++) CHECK(is_even(n) == ((n & 1) == 0));

  // Alternate link register
  for (uint32_t v = 0; v < 50; v++) CHECK(call_via_t0(v) == v + 3);

  // Function pointers: the same call site calls a changing target
  uint32_t rng = 7, acc = 0, ref = 0;
  for (uint32_t i = 0; i < 400; i++) {
    uint32_t sel = (i < 200) ? (i >> 6) & 3 : xorshift32(&rng) & 3;  // runs, then random
    uint32_t a = i, b = i * 3 + 1;
    acc += ops[sel](a, b);
    ref += sel == 0 ? a + b : sel == 1 ? a - b : sel == 2 ? (a ^ b) : a * b;
  }
  CHECK(acc == ref);

  // Jump table
  uint32_t jt = 0, jt_ref = 0;
  for (uint32_t i = 0; i < 300; i++) {
    uint32_t sel = (i * 7) % 11, x = i + 1;
    jt += jump_table(sel, x);
    switch (sel) {
      case 0: jt_ref += x + 11; break;
      case 1: jt_ref += x * 3; break;
      case 2: jt_ref += x ^ 0x5a5a; break;
      case 3: jt_ref += x - 7; break;
      case 4: jt_ref += x << 2; break;
      case 5: jt_ref += x >> 1; break;
      case 6: jt_ref += ~x; break;
      case 7: jt_ref += x * x; break;
      case 8: jt_ref += x | 0x100; break;
      case 9: jt_ref += x & 0xff; break;
      default: break;
    }
  }
  CHECK(jt == jt_ref);

  perf_finish("call_return");
  tb_printf("call_return: PASS\n");
  return 0;
}
