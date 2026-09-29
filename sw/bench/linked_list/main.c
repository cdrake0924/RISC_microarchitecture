// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// linked_list: pointer chasing through a randomly permuted singly linked list.
// Character: every load depends on the previous one and lands on an unpredictable line; the 32 KiB
// node pool is 16x the default D-cache, so this measures miss latency almost directly.

#include "perf.h"
#include "platform.h"

#define NODES 2048
#define PASSES 4

typedef struct node {
  struct node *next;
  uint32_t value;
  uint32_t pad[2];  // 16-byte nodes: one node per default cache line
} node_t;

static node_t pool[NODES] __attribute__((aligned(16)));
static uint16_t order[NODES];

int main(void) {
  // Random permutation (Fisher-Yates) defines the traversal order
  uint32_t rng = 2024;
  for (int i = 0; i < NODES; i++) order[i] = (uint16_t)i;
  for (int i = NODES - 1; i > 0; i--) {
    int j = (int)(xorshift32(&rng) % (uint32_t)(i + 1));
    uint16_t t = order[i];
    order[i] = order[j];
    order[j] = t;
  }
  for (int i = 0; i < NODES; i++) {
    pool[order[i]].next = &pool[order[(i + 1) % NODES]];
    pool[order[i]].value = (uint32_t)order[i] * 2654435761u;
  }

  perf_start();
  uint32_t sum = 0;
  node_t *p = &pool[order[0]];
  for (int pass = 0; pass < PASSES; pass++) {
    for (int i = 0; i < NODES; i++) {
      sum += p->value;
      p = p->next;
    }
  }
  perf_finish("linked_list");

  uint32_t ref = 0;
  for (int i = 0; i < NODES; i++) ref += (uint32_t)i * 2654435761u;
  CHECK(sum == ref * PASSES);
  CHECK(p == &pool[order[0]]);
  tb_printf("linked_list: PASS\n");
  return 0;
}
