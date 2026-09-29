// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Hardware performance counter test.
//
// Runs small assembly kernels whose event counts are known exactly and checks every new HPM event
// (branch mispredicts, I/D-cache accesses/misses, write-backs, uncached accesses) plus the upstream
// ones they are derived from. Expected values depend on the configuration under test, which the
// program reads from the testbench configuration register.

#include "perf.h"
#include "platform.h"

static uint32_t word_var = 5;
static uint32_t store_buf[1024] __attribute__((aligned(64)));

static int errors;

#define EXPECT(name, got, cond)                                                              \
  do {                                                                                       \
    uint64_t _g = (got);                                                                     \
    if (!(cond)) {                                                                           \
      tb_printf("  FAIL %-28s = %llu  (expected %s)\n", name, _g, #cond);                     \
      errors++;                                                                              \
    } else {                                                                                 \
      tb_printf("  ok   %-28s = %llu\n", name, _g);                                           \
    }                                                                                        \
  } while (0)

int main(void) {
  uint32_t cfg = MMIO32(TB_CONFIG_ADDR);
  uint32_t bp = TB_CFG_BP_MODE(cfg);
  uint32_t ic = TB_CFG_ICACHE_EN(cfg);
  uint32_t dc = TB_CFG_DCACHE_EN(cfg);
  uint32_t ras = TB_CFG_RAS_EN(cfg);
  uint32_t btb = TB_CFG_BTB_EN(cfg);
  uint32_t wt = TB_CFG_DC_WT(cfg);  // write-through D-cache: never dirty, never writes back
  uint32_t line = TB_CFG_DC_LINE(cfg);
  uint32_t stride = line > 64 ? line : 64;
  perf_counters_t p;
  uint64_t g;

  tb_printf("HPM test: bp_mode=%u ras=%u btb=%u icache=%u dcache=%u dcache_wt=%u dcache_line=%u\n",
            bp, ras, btb, ic, dc, wt, line);

  // ---- 1. Branches: countdown loop, exactly 1000 conditional branches, 999 taken ----
  perf_start();
  __asm__ volatile(
      "li   t0, 1000\n"
      "1:\n"
      "addi t0, t0, -1\n"
      "bnez t0, 1b\n" ::: "t0");
  perf_stop();
  perf_read(&p);
  tb_printf("[branch loop]\n");
  EXPECT("branches", g = p.hpm[HPM_BRANCHES], g == 1000);
  EXPECT("taken branches", g = p.hpm[HPM_TAKEN], g == 999);
  if (bp == BP_NONE) {
    // No predictor: every taken branch is a mispredict (implicit not-taken prediction)
    EXPECT("mispredicts", g = p.hpm[HPM_BR_MISPRED], g == 999);
    EXPECT("mispredicts (pred. taken)", g = p.hpm[HPM_BR_MISPRED_T], g == 0);
  } else if (bp == BP_STATIC) {
    // BTFN: backward branch always predicted taken, only the loop exit mispredicts
    EXPECT("mispredicts", g = p.hpm[HPM_BR_MISPRED], g == 1);
    EXPECT("mispredicts (pred. taken)", g = p.hpm[HPM_BR_MISPRED_T], g == 1);
  } else {
    // Dynamic (1-bit, bimodal, gshare, tournament): a few warm-up mispredicts (gshare walks through
    // new history values first), then only the loop exit, which is predicted taken
    EXPECT("mispredicts", g = p.hpm[HPM_BR_MISPRED], g >= 1 && g <= 16);
    EXPECT("mispredicts (pred. taken)", g = p.hpm[HPM_BR_MISPRED_T], g == 1);
  }
  EXPECT("I-cache accesses", g = p.hpm[HPM_IC_ACCESS], ic ? g > 0 : g == 0);
  EXPECT("I-cache misses", g = p.hpm[HPM_IC_MISS], ic ? g <= p.hpm[HPM_IC_ACCESS] : g == 0);

  // ---- 2. Loads: 100 loads of the same word ----
  // Clean the D-cache first: the load may miss and evict a line dirtied by tb_printf's stack
  // traffic, which would (correctly) count a write-back.
  __asm__ volatile("fence.i" ::: "memory");
  perf_start();
  __asm__ volatile(
      "li   t0, 100\n"
      "1:\n"
      "lw   t1, 0(%0)\n"
      "addi t0, t0, -1\n"
      "bnez t0, 1b\n" ::"r"(&word_var)
      : "t0", "t1");
  perf_stop();
  perf_read(&p);
  tb_printf("[load loop]\n");
  EXPECT("loads", g = p.hpm[HPM_LOADS], g == 100);
  EXPECT("stores", g = p.hpm[HPM_STORES], g == 0);
  EXPECT("D-cache accesses", g = p.hpm[HPM_DC_ACCESS], dc ? g == 100 : g == 0);
  EXPECT("D-cache misses", g = p.hpm[HPM_DC_MISS], dc ? g <= 1 : g == 0);
  EXPECT("D-cache write-backs", g = p.hpm[HPM_DC_WRITEBACK], g == 0);

  // ---- 3. Stores to 16 distinct lines, then FENCE.I cleans exactly those 16 dirty lines ----
  // (write-through: the stores already went to memory, so there is nothing to write back)
  __asm__ volatile("fence.i" ::: "memory");  // start with a clean D-cache
  perf_start();
  __asm__ volatile(
      "li   t0, 16\n"
      "mv   t1, %0\n"
      "1:\n"
      "sw   t0, 0(t1)\n"
      "add  t1, t1, %1\n"
      "addi t0, t0, -1\n"
      "bnez t0, 1b\n"
      "fence.i\n" ::"r"(store_buf),
      "r"(stride)
      : "t0", "t1", "memory");
  perf_stop();
  perf_read(&p);
  tb_printf("[store + fence.i]\n");
  EXPECT("stores", g = p.hpm[HPM_STORES], g == 16);
  // Every cacheable data access is counted exactly once (the compiler may schedule a reload of an
  // operand inside the region, so compare against loads + stores rather than a constant).
  EXPECT("D-cache accesses", g = p.hpm[HPM_DC_ACCESS],
         dc ? g == p.hpm[HPM_LOADS] + p.hpm[HPM_STORES] : g == 0);
  EXPECT("D-cache write-backs", g = p.hpm[HPM_DC_WRITEBACK], (dc && !wt) ? g == 16 : g == 0);

  // ---- 4. Uncached (MMIO) accesses and jumps ----
  perf_start();
  __asm__ volatile(
      "li   t0, %0\n"
      "li   t1, 46\n"  // '.'
      "sw   t1, 0(t0)\n"
      "sw   t1, 0(t0)\n"
      "sw   t1, 0(t0)\n"
      "sw   t1, 0(t0)\n"
      "j    1f\n"
      "1: j 2f\n"
      "2: j 3f\n"
      "3:\n" ::"i"(TB_PUTCHAR_ADDR)
      : "t0", "t1", "memory");
  perf_stop();
  perf_read(&p);
  tb_printf("\n[mmio + jumps]\n");
  EXPECT("stores", g = p.hpm[HPM_STORES], g == 4);
  EXPECT("uncached accesses", g = p.hpm[HPM_DC_BYPASS], dc ? g == 4 : g == 0);
  EXPECT("D-cache accesses", g = p.hpm[HPM_DC_ACCESS], g == 0);
  EXPECT("jumps", g = p.hpm[HPM_JUMPS], g == 3);

  // ---- 5. Calls and returns: 100 calls of a leaf whose FIRST instruction is `ret` ----
  // The RAS is updated when the call enters ID, so even a return fetched right behind its call is
  // predicted from the RAS (100 correct predictions, no target mispredicts).
  perf_start();
  __asm__ volatile(
      "li   t0, 100\n"
      "1:\n"
      "jal  ra, 2f\n"
      "addi t0, t0, -1\n"
      "bnez t0, 1b\n"
      "j    3f\n"
      "2:\n"
      "ret\n"
      "3:\n" ::: "t0", "ra");
  perf_stop();
  perf_read(&p);
  tb_printf("[call/return]\n");
  EXPECT("jumps", g = p.hpm[HPM_JUMPS], g == 201);
  EXPECT("register-indirect jumps", g = p.hpm[HPM_JALR], g == 100);
  EXPECT("RAS predictions", g = p.hpm[HPM_RAS_PRED], ras ? g == 100 : g == 0);
  EXPECT("BTB predictions", g = p.hpm[HPM_BTB_PRED], g == 0);
  EXPECT("JALR target mispredicts", g = p.hpm[HPM_JALR_MISPRED], g == 0);

  // ---- 6. Indirect calls through a function pointer (not returns: BTB territory) ----
  // 100 `jalr ra, 0(t1)` to the same target: the BTB misses once, then predicts every call; the
  // returns come from the RAS.
  perf_start();
  __asm__ volatile(
      "la   t1, 2f\n"
      "li   t0, 100\n"
      "1:\n"
      "jalr ra, 0(t1)\n"
      "addi t0, t0, -1\n"
      "bnez t0, 1b\n"
      "j    3f\n"
      "2:\n"
      "addi t2, t2, 1\n"
      "ret\n"
      "3:\n" ::: "t0", "t1", "t2", "ra");
  perf_stop();
  perf_read(&p);
  tb_printf("[indirect calls]\n");
  EXPECT("register-indirect jumps", g = p.hpm[HPM_JALR], g == 200);
  EXPECT("BTB predictions", g = p.hpm[HPM_BTB_PRED], btb ? (g >= 98 && g <= 100) : g == 0);
  EXPECT("RAS predictions", g = p.hpm[HPM_RAS_PRED], ras ? g == 100 : g == 0);
  EXPECT("JALR target mispredicts", g = p.hpm[HPM_JALR_MISPRED], g == 0);

  if (errors) {
    tb_printf("hpm_counters: %d check(s) FAILED\n", errors);
    return 1;
  }
  tb_printf("hpm_counters: PASS\n");
  return 0;
}
