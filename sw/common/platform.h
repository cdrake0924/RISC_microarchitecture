// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Platform layer for the Ibex core-complex testbench (dv/tb/tb_mem.sv memory map).

#ifndef PLATFORM_H
#define PLATFORM_H

#define TB_PUTCHAR_ADDR    0x10000000
#define TB_TIMER_CTRL_ADDR 0x15000000
#define TB_TIMER_CNT_ADDR  0x15000004
#define TB_STATUS_ADDR     0x20000000
#define TB_EXIT_ADDR       0x20000004
#define TB_CONFIG_ADDR     0x20000100  // read-only: micro-architecture configuration
#define TB_UNMAPPED_ADDR   0x30000000  // any access here returns a bus error

// TB_CONFIG_ADDR fields
#define TB_CFG_BP_MODE(w)   ((w) & 0x7)          // 0 none, 1 static, 2 1-bit, 3 bimodal,
                                                 // 4 gshare, 5 tournament
#define TB_CFG_ICACHE_EN(w) (((w) >> 3) & 0x1)
#define TB_CFG_DCACHE_EN(w) (((w) >> 4) & 0x1)
#define TB_CFG_RAS_EN(w)    (((w) >> 5) & 0x1)   // return address stack
#define TB_CFG_BTB_EN(w)    (((w) >> 6) & 0x1)   // indirect-jump BTB
#define TB_CFG_PREFETCH(w)  (((w) >> 7) & 0x1)   // I-cache next-line prefetcher
#define TB_CFG_DC_WT(w)     (((w) >> 8) & 0x1)   // D-cache write-through
#define TB_CFG_DC_LINE(w)   ((w) >> 16)          // D-cache line size in bytes

#define BP_NONE 0
#define BP_STATIC 1
#define BP_ONEBIT 2
#define BP_BIMODAL 3
#define BP_GSHARE 4
#define BP_TOURNAMENT 5

#ifndef __ASSEMBLER__

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define MMIO32(addr) (*(volatile uint32_t *)(addr))

#define read_csr(reg) ({ uint32_t __v; __asm__ volatile("csrr %0, " #reg : "=r"(__v)); __v; })
#define write_csr(reg, val) __asm__ volatile("csrw " #reg ", %0" ::"r"((uint32_t)(val)))
#define set_csr(reg, bits) __asm__ volatile("csrs " #reg ", %0" ::"r"((uint32_t)(bits)))
#define clear_csr(reg, bits) __asm__ volatile("csrc " #reg ", %0" ::"r"((uint32_t)(bits)))

// ---- console / exit ----
void tb_putc(char c);
void tb_puts(const char *s);
int tb_printf(const char *fmt, ...);
int tb_vprintf(const char *fmt, va_list ap);
void tb_exit(int code) __attribute__((noreturn));

// ---- self-check helper: prints a message and exits with failure if cond is false ----
#define CHECK(cond)                                                              \
  do {                                                                           \
    if (!(cond)) {                                                               \
      tb_printf("CHECK FAILED: %s (%s:%d)\n", #cond, __FILE__, __LINE__);        \
      tb_exit(1);                                                                \
    }                                                                            \
  } while (0)

// ---- timer ----
void tb_timer_arm(uint32_t cycles);  // raise mtip after `cycles` cycles (sets mie.MTIE only)
void tb_timer_disable(void);
void tb_irq_enable(void);            // mstatus.MIE = 1 (thread context only)
void tb_irq_disable(void);

// ---- trap hooks (weak, override in a test) ----
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval);
void irq_handler(uint32_t mcause);

// ---- freestanding libc subset (the compiler may emit calls to these) ----
void *memset(void *dst, int c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);

// ---- deterministic pseudo-random numbers (xorshift32) ----
static inline uint32_t xorshift32(uint32_t *state) {
  uint32_t x = *state;
  x ^= x << 13;
  x ^= x >> 17;
  x ^= x << 5;
  *state = x;
  return x;
}

#endif  // __ASSEMBLER__
#endif  // PLATFORM_H
