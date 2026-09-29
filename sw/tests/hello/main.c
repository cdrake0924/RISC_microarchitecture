// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Smoke test: console output, configuration register and HPM readout.

#include "perf.h"
#include "platform.h"

int main(void) {
  static const char *bp_names[] = {"none",    "static (BTFN)", "1-bit",
                                   "bimodal", "gshare",        "tournament"};
  uint32_t cfg = MMIO32(TB_CONFIG_ADDR);

  perf_start();
  tb_printf("Hello from the extended Ibex core complex!\n");
  tb_printf("  branch predictor : %s%s%s\n", bp_names[TB_CFG_BP_MODE(cfg)],
            TB_CFG_RAS_EN(cfg) ? " + RAS" : "", TB_CFG_BTB_EN(cfg) ? " + BTB" : "");
  tb_printf("  L1 I-cache       : %s%s\n", TB_CFG_ICACHE_EN(cfg) ? "enabled" : "disabled",
            TB_CFG_PREFETCH(cfg) ? " + next-line prefetch" : "");
  tb_printf("  L1 D-cache       : %s\n",
            TB_CFG_DCACHE_EN(cfg) ? (TB_CFG_DC_WT(cfg) ? "write-through" : "write-back")
                                  : "disabled");
  perf_finish("hello");
  return 0;
}
