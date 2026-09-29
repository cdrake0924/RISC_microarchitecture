// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// interp: a small stack-machine bytecode interpreter, run with two dispatch schemes.
//
//   interp_switch    `switch (op)` in a loop: every bytecode dispatches through ONE indirect jump
//                    (jump table), whose target changes almost every time - the worst case for a
//                    last-target BTB
//   interp_threaded  "threaded code" with computed goto: every handler ends with its OWN indirect
//                    jump, so each jump sees a narrower, more repetitive set of successors
//
// Character: indirect-jump dominated. The program computes sum(i^2, i = 1..N) with a loop of nine
// bytecodes per iteration.

#include "perf.h"
#include "platform.h"

enum { OP_PUSH, OP_LOAD, OP_STORE, OP_ADD, OP_MUL, OP_DEC, OP_JNZ, OP_HALT };

#define N 1000
#define EXPECTED ((uint32_t)N * (N + 1) * (2 * N + 1) / 6)

static const uint16_t program[] = {
    OP_PUSH, N,    // 0: i = N
    OP_STORE, 0,   // 2
    OP_PUSH, 0,    // 4: acc = 0
    OP_STORE, 1,   // 6
    OP_LOAD, 0,    // 8: loop: acc += i * i
    OP_LOAD, 0,    // 10
    OP_MUL,        // 12
    OP_LOAD, 1,    // 13
    OP_ADD,        // 15
    OP_STORE, 1,   // 16
    OP_DEC, 0,     // 18: i--
    OP_LOAD, 0,    // 20
    OP_JNZ, 8,     // 22: while (i)
    OP_LOAD, 1,    // 24
    OP_HALT        // 26
};

__attribute__((noinline)) static uint32_t run_switch(const uint16_t *code) {
  uint32_t stack[16], vars[4];
  uint32_t sp = 0, pc = 0;
  for (;;) {
    switch (code[pc]) {
      case OP_PUSH:  stack[sp++] = code[pc + 1]; pc += 2; break;
      case OP_LOAD:  stack[sp++] = vars[code[pc + 1]]; pc += 2; break;
      case OP_STORE: vars[code[pc + 1]] = stack[--sp]; pc += 2; break;
      case OP_ADD:   sp--; stack[sp - 1] += stack[sp]; pc += 1; break;
      case OP_MUL:   sp--; stack[sp - 1] *= stack[sp]; pc += 1; break;
      case OP_DEC:   vars[code[pc + 1]]--; pc += 2; break;
      case OP_JNZ:   pc = stack[--sp] ? code[pc + 1] : pc + 2; break;
      case OP_HALT:  return stack[sp - 1];
      default:       return 0xdead;
    }
  }
}

__attribute__((noinline)) static uint32_t run_threaded(const uint16_t *code) {
  static const void *const table[] = {&&op_push, &&op_load, &&op_store, &&op_add,
                                      &&op_mul,  &&op_dec,  &&op_jnz,   &&op_halt};
  uint32_t stack[16], vars[4];
  uint32_t sp = 0, pc = 0;
#define DISPATCH() goto *table[code[pc]]
  DISPATCH();
op_push:  stack[sp++] = code[pc + 1]; pc += 2; DISPATCH();
op_load:  stack[sp++] = vars[code[pc + 1]]; pc += 2; DISPATCH();
op_store: vars[code[pc + 1]] = stack[--sp]; pc += 2; DISPATCH();
op_add:   sp--; stack[sp - 1] += stack[sp]; pc += 1; DISPATCH();
op_mul:   sp--; stack[sp - 1] *= stack[sp]; pc += 1; DISPATCH();
op_dec:   vars[code[pc + 1]]--; pc += 2; DISPATCH();
op_jnz:   pc = stack[--sp] ? code[pc + 1] : pc + 2; DISPATCH();
op_halt:  return stack[sp - 1];
#undef DISPATCH
}

int main(void) {
  perf_start();
  uint32_t a = run_switch(program);
  perf_finish("interp_switch");

  perf_start();
  uint32_t b = run_threaded(program);
  perf_finish("interp_threaded");

  CHECK(a == EXPECTED);
  CHECK(b == EXPECTED);
  tb_printf("interp: PASS (%u)\n", a);
  return 0;
}
