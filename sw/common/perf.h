// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Hardware performance monitor (HPM) access for the extended Ibex core.
//
// Event map (keep in sync with rtl/ibex_uarch_pkg.sv and docs/performance_counters.md):
//
//   mcycle          cycles
//   minstret        instructions retired
//   mhpmcounter3    cycles waiting for data memory            (upstream Ibex)
//   mhpmcounter4    cycles waiting for instruction fetch       (upstream Ibex)
//   mhpmcounter5    loads                                      (upstream Ibex)
//   mhpmcounter6    stores                                     (upstream Ibex)
//   mhpmcounter7    jumps (JAL/JALR)                           (upstream Ibex)
//   mhpmcounter8    conditional branches                       (upstream Ibex)
//   mhpmcounter9    taken conditional branches                 (upstream Ibex)
//   mhpmcounter10   compressed instructions retired            (upstream Ibex)
//   mhpmcounter11   multiply wait cycles                       (upstream Ibex)
//   mhpmcounter12   divide wait cycles                         (upstream Ibex)
//   mhpmcounter13   branch direction mispredicts               (new)
//   mhpmcounter14   ... of which predicted taken               (new)
//   mhpmcounter15   register-indirect jumps (JALR) executed    (new)
//   mhpmcounter16   ... predicted by the return address stack  (new)
//   mhpmcounter17   ... predicted by the BTB                   (new)
//   mhpmcounter18   ... predicted with a wrong target          (new)
//   mhpmcounter19   I-cache accesses                           (new)
//   mhpmcounter20   I-cache misses                             (new)
//   mhpmcounter21   I-cache lines prefetched                   (new)
//   mhpmcounter22   I-cache refills served by the prefetcher   (new)
//   mhpmcounter23   D-cache accesses                           (new)
//   mhpmcounter24   D-cache misses                             (new)
//   mhpmcounter25   D-cache dirty write-backs                  (new)
//   mhpmcounter26   uncached (MMIO) data accesses              (new)

#ifndef PERF_H
#define PERF_H

#include "platform.h"

#define PERF_NUM_HPM 24  // mhpmcounter3..mhpmcounter26

// Index into perf_counters_t.hpm[] (= mhpmcounter number - 3)
enum {
  HPM_DSIDE_WAIT = 0,
  HPM_ISIDE_WAIT,
  HPM_LOADS,
  HPM_STORES,
  HPM_JUMPS,
  HPM_BRANCHES,
  HPM_TAKEN,
  HPM_COMPRESSED,
  HPM_MUL_WAIT,
  HPM_DIV_WAIT,
  HPM_BR_MISPRED,
  HPM_BR_MISPRED_T,
  HPM_JALR,
  HPM_RAS_PRED,
  HPM_BTB_PRED,
  HPM_JALR_MISPRED,
  HPM_IC_ACCESS,
  HPM_IC_MISS,
  HPM_IC_PF_ISSUE,
  HPM_IC_PF_HIT,
  HPM_DC_ACCESS,
  HPM_DC_MISS,
  HPM_DC_WRITEBACK,
  HPM_DC_BYPASS
};

typedef struct {
  uint64_t cycles;
  uint64_t instret;
  uint64_t hpm[PERF_NUM_HPM];  // hpm[i] = mhpmcounter(i+3)
} perf_counters_t;

// Event names in counter order, used for the machine-readable PERF report line.
static const char *const perf_hpm_names[PERF_NUM_HPM] = {
    "dside_wait", "iside_wait",   "loads",       "stores",     "jumps",     "branches",
    "taken",      "compressed",   "mul_wait",    "div_wait",   "br_mispred", "br_mispred_t",
    "jalr",       "ras_pred",     "btb_pred",    "jalr_mispred",
    "ic_access",  "ic_miss",      "ic_pf_issue", "ic_pf_hit",
    "dc_access",  "dc_miss",      "dc_writeback", "dc_bypass"};

#define HPM_CSR_READ(n, lo, hi)                                   \
  do {                                                            \
    __asm__ volatile("csrr %0, mhpmcounter" #n : "=r"(lo));      \
    __asm__ volatile("csrr %0, mhpmcounter" #n "h" : "=r"(hi));  \
  } while (0)

#define HPM_CSR_CLEAR(n)                                    \
  do {                                                      \
    __asm__ volatile("csrw mhpmcounter" #n ", zero");       \
    __asm__ volatile("csrw mhpmcounter" #n "h, zero");      \
  } while (0)

// perf_start/perf_stop/perf_read are force-inlined so that no call/return instructions of the
// helpers themselves fall inside the measured region.
#define PERF_INLINE static inline __attribute__((always_inline))

// Freeze all counters (mcountinhibit: bit 0 = mcycle, bit 2 = minstret, bits 3.. = HPM)
PERF_INLINE void perf_stop(void) { write_csr(mcountinhibit, 0xffffffffu); }

// Zero every counter and start counting.
PERF_INLINE void perf_start(void) {
  perf_stop();
  write_csr(mcycle, 0);
  write_csr(mcycleh, 0);
  write_csr(minstret, 0);
  write_csr(minstreth, 0);
  HPM_CSR_CLEAR(3);  HPM_CSR_CLEAR(4);  HPM_CSR_CLEAR(5);  HPM_CSR_CLEAR(6);
  HPM_CSR_CLEAR(7);  HPM_CSR_CLEAR(8);  HPM_CSR_CLEAR(9);  HPM_CSR_CLEAR(10);
  HPM_CSR_CLEAR(11); HPM_CSR_CLEAR(12); HPM_CSR_CLEAR(13); HPM_CSR_CLEAR(14);
  HPM_CSR_CLEAR(15); HPM_CSR_CLEAR(16); HPM_CSR_CLEAR(17); HPM_CSR_CLEAR(18);
  HPM_CSR_CLEAR(19); HPM_CSR_CLEAR(20); HPM_CSR_CLEAR(21); HPM_CSR_CLEAR(22);
  HPM_CSR_CLEAR(23); HPM_CSR_CLEAR(24); HPM_CSR_CLEAR(25); HPM_CSR_CLEAR(26);
  write_csr(mcountinhibit, 0);
}

// Read all counters (call after perf_stop() so the 64-bit halves are consistent).
PERF_INLINE void perf_read(perf_counters_t *p) {
  uint32_t lo, hi;
  __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
  __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
  p->cycles = ((uint64_t)hi << 32) | lo;
  __asm__ volatile("csrr %0, minstret" : "=r"(lo));
  __asm__ volatile("csrr %0, minstreth" : "=r"(hi));
  p->instret = ((uint64_t)hi << 32) | lo;
#define HPM_SLOT(n)                                   \
  HPM_CSR_READ(n, lo, hi);                            \
  p->hpm[(n)-3] = ((uint64_t)hi << 32) | lo;
  HPM_SLOT(3)  HPM_SLOT(4)  HPM_SLOT(5)  HPM_SLOT(6)  HPM_SLOT(7)  HPM_SLOT(8)
  HPM_SLOT(9)  HPM_SLOT(10) HPM_SLOT(11) HPM_SLOT(12) HPM_SLOT(13) HPM_SLOT(14)
  HPM_SLOT(15) HPM_SLOT(16) HPM_SLOT(17) HPM_SLOT(18) HPM_SLOT(19) HPM_SLOT(20)
  HPM_SLOT(21) HPM_SLOT(22) HPM_SLOT(23) HPM_SLOT(24) HPM_SLOT(25) HPM_SLOT(26)
#undef HPM_SLOT
}

// Print one machine-readable line, parsed by scripts/regress.py and scripts/evaluate.py:
//   PERF name=<name> cycles=<n> instret=<n> dside_wait=<n> ...
static inline void perf_report(const char *name, const perf_counters_t *p) {
  tb_printf("PERF name=%s cycles=%llu instret=%llu", name, p->cycles, p->instret);
  for (int i = 0; i < PERF_NUM_HPM; i++) {
    tb_printf(" %s=%llu", perf_hpm_names[i], p->hpm[i]);
  }
  tb_printf("\n");
}

// Convenience: stop, read and report.
PERF_INLINE void perf_finish(const char *name) {
  perf_counters_t p;
  perf_stop();
  perf_read(&p);
  perf_report(name, &p);
}

#endif  // PERF_H
