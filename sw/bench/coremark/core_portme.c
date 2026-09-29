// Copyright lowRISC contributors (derived from ibex/examples/sw/benchmarks/coremark/ibex).
// Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC)
// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "coremark.h"
#include "core_portme.h"
#include "perf.h"
#include "platform.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

// CoreMark reports CRC mismatches with ee_printf("...ERROR!...") / "Errors detected" but still
// returns 0 from main; remember them so the run fails.
static int coremark_error_seen;

int ee_printf(const char *fmt, ...) {
  const char *keys[] = {"ERROR", "Errors detected"};
  for (unsigned k = 0; k < 2; k++) {
    for (const char *s = fmt; *s; s++) {
      const char *a = s, *b = keys[k];
      while (*a && *b && *a == *b) {
        a++;
        b++;
      }
      if (!*b) coremark_error_seen = 1;
    }
  }
  va_list ap;
  va_start(ap, fmt);
  int n = tb_vprintf(fmt, ap);
  va_end(ap);
  return n;
}

static perf_counters_t timed;

void start_time(void) { perf_start(); }

void stop_time(void) {
  perf_stop();
  perf_read(&timed);
}

CORE_TICKS get_time(void) { return (CORE_TICKS)timed.cycles; }

// Ticks are core cycles; report "seconds" for a nominal 1 MHz clock so iterations/sec is readable.
#define EE_TICKS_PER_SEC 1000000u
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / EE_TICKS_PER_SEC); }

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  p->portable_id = 1;
}

void portable_fini(core_portable *p) {
  p->portable_id = 0;
  perf_report("coremark", &timed);
  // CoreMark/MHz x 1000 = ITERATIONS * 1e9 / cycles, computed without 64-bit division
  uint32_t cycles = (uint32_t)timed.cycles;
  uint32_t per_iter = cycles / ITERATIONS;
  tb_printf("CoreMark: %u iterations in %u cycles (%u cycles/iteration)\n", (uint32_t)ITERATIONS,
            cycles, per_iter);
  if (coremark_error_seen) {
    tb_printf("coremark: FAILED (CRC mismatch)\n");
    tb_exit(1);
  }
  tb_printf("coremark: PASS\n");
}
