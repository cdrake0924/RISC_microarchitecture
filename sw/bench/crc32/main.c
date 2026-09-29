// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// crc32: bitwise (table-less) CRC-32 over a 6 KiB buffer.
// Character: a tight inner loop whose data-dependent branch is taken ~50% of the time at random,
// plus a perfectly predictable loop branch; tiny instruction footprint, streaming data.

#include "perf.h"
#include "platform.h"

#define LEN 6144

static uint8_t buf[LEN];

static uint32_t crc32_bitwise(const uint8_t *p, uint32_t n) {
  uint32_t crc = 0xffffffffu;
  while (n--) {
    crc ^= *p++;
    for (int k = 0; k < 8; k++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xedb88320u;
      else         crc >>= 1;
    }
  }
  return ~crc;
}

// Table-driven reference implementation (computed outside the measured region)
static uint32_t crc_table[256];
static uint32_t crc32_table(const uint8_t *p, uint32_t n) {
  for (uint32_t i = 0; i < 256; i++) {
    uint32_t c = i;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
    crc_table[i] = c;
  }
  uint32_t crc = 0xffffffffu;
  while (n--) crc = crc_table[(crc ^ *p++) & 0xff] ^ (crc >> 8);
  return ~crc;
}

int main(void) {
  uint32_t rng = 0xc0ffee;
  for (int i = 0; i < LEN; i++) buf[i] = (uint8_t)xorshift32(&rng);

  // Known-answer test for the reference: CRC-32("123456789") = 0xCBF43926
  CHECK(crc32_table((const uint8_t *)"123456789", 9) == 0xcbf43926u);

  perf_start();
  uint32_t crc = crc32_bitwise(buf, LEN);
  perf_finish("crc32");

  CHECK(crc == crc32_table(buf, LEN));
  tb_printf("crc32: PASS (0x%08x)\n", crc);
  return 0;
}
