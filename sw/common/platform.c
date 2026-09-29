// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "platform.h"

// ---------------------------------------------------------------------------------------------
// Console
// ---------------------------------------------------------------------------------------------

void tb_putc(char c) { MMIO32(TB_PUTCHAR_ADDR) = (uint32_t)(uint8_t)c; }

void tb_puts(const char *s) {
  while (*s) tb_putc(*s++);
}

void tb_exit(int code) {
  // Clean the D-cache so memory is coherent for any backdoor inspection, then report.
  __asm__ volatile("fence.i" ::: "memory");
  MMIO32(TB_EXIT_ADDR) = (uint32_t)code;
  for (;;) __asm__ volatile("wfi");
}

// 64-bit unsigned to decimal without 64-bit division (no libgcc on this platform).
static int put_u64_dec(uint64_t v, int width, char pad) {
  static const uint64_t pow10[] = {10000000000000000000ull, 1000000000000000000ull,
                                   100000000000000000ull,   10000000000000000ull,
                                   1000000000000000ull,     100000000000000ull,
                                   10000000000000ull,       1000000000000ull,
                                   100000000000ull,         10000000000ull,
                                   1000000000ull,           100000000ull,
                                   10000000ull,             1000000ull,
                                   100000ull,               10000ull,
                                   1000ull,                 100ull,
                                   10ull,                   1ull};
  char buf[21];
  int n = 0;
  int started = 0;
  for (unsigned i = 0; i < sizeof(pow10) / sizeof(pow10[0]); i++) {
    char digit = '0';
    while (v >= pow10[i]) {
      v -= pow10[i];
      digit++;
    }
    if (digit != '0' || started || i == sizeof(pow10) / sizeof(pow10[0]) - 1) {
      buf[n++] = digit;
      started = 1;
    }
  }
  for (int i = n; i < width; i++) tb_putc(pad);
  for (int i = 0; i < n; i++) tb_putc(buf[i]);
  return (n > width) ? n : width;
}

static int put_hex(uint64_t v, int width, char pad, int upper) {
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  char buf[16];
  int n = 0;
  do {
    buf[n++] = digits[v & 0xf];
    v >>= 4;
  } while (v);
  for (int i = n; i < width; i++) tb_putc(pad);
  for (int i = n - 1; i >= 0; i--) tb_putc(buf[i]);
  return (n > width) ? n : width;
}

// Minimal printf: %d %i %u %x %X %c %s %% with optional '0' flag, width and 'l'/'ll' modifiers.
int tb_vprintf(const char *fmt, va_list ap) {
  int count = 0;
  for (; *fmt; fmt++) {
    if (*fmt != '%') {
      tb_putc(*fmt);
      count++;
      continue;
    }
    fmt++;
    char pad = ' ';
    int width = 0;
    int longs = 0;
    int left = 0;
    if (*fmt == '-') {
      left = 1;
      fmt++;
    }
    if (*fmt == '0') {
      pad = '0';
      fmt++;
    }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    while (*fmt == 'l') {
      longs++;
      fmt++;
    }
    switch (*fmt) {
      case 'd':
      case 'i': {
        int64_t v = (longs >= 2) ? va_arg(ap, int64_t) : (int64_t)va_arg(ap, int32_t);
        if (v < 0) {
          tb_putc('-');
          count++;
          v = -v;
          if (width) width--;
        }
        count += put_u64_dec((uint64_t)v, width, pad);
        break;
      }
      case 'u': {
        uint64_t v = (longs >= 2) ? va_arg(ap, uint64_t) : (uint64_t)va_arg(ap, uint32_t);
        count += put_u64_dec(v, width, pad);
        break;
      }
      case 'x':
      case 'X': {
        uint64_t v = (longs >= 2) ? va_arg(ap, uint64_t) : (uint64_t)va_arg(ap, uint32_t);
        count += put_hex(v, width, pad, *fmt == 'X');
        break;
      }
      case 'c':
        tb_putc((char)va_arg(ap, int));
        count++;
        break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        int len = (int)strlen(s);
        if (!left) for (int i = len; i < width; i++, count++) tb_putc(' ');
        while (*s) {
          tb_putc(*s++);
          count++;
        }
        if (left) for (int i = len; i < width; i++, count++) tb_putc(' ');
        break;
      }
      case '%':
        tb_putc('%');
        count++;
        break;
      default:
        tb_putc('?');
        count++;
        break;
    }
  }
  return count;
}

int tb_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = tb_vprintf(fmt, ap);
  va_end(ap);
  return n;
}

// ---------------------------------------------------------------------------------------------
// Timer and traps
// ---------------------------------------------------------------------------------------------

// Arms the timer and enables its interrupt source (mie.MTIE) but deliberately does NOT touch the
// global enable mstatus.MIE: re-arming from inside the handler must not allow a nested interrupt
// (the handler does not save mepc/mstatus). Call tb_irq_enable() from thread context instead.
void tb_timer_arm(uint32_t cycles) {
  MMIO32(TB_TIMER_CTRL_ADDR) = 1u << 7;
  MMIO32(TB_TIMER_CNT_ADDR) = cycles;
  set_csr(mie, 1u << 7);
}

void tb_irq_enable(void) { set_csr(mstatus, 1u << 3); }
void tb_irq_disable(void) { clear_csr(mstatus, 1u << 3); }

void tb_timer_disable(void) {
  clear_csr(mie, 1u << 7);
  MMIO32(TB_TIMER_CTRL_ADDR) = 0;
  MMIO32(TB_TIMER_CNT_ADDR) = 0;  // also clears the pending interrupt
}

__attribute__((weak)) uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  tb_printf("\nUNEXPECTED TRAP: mcause=0x%08x mepc=0x%08x mtval=0x%08x\n", mcause, mepc, mtval);
  tb_exit(0xbad);
  return mepc;
}

__attribute__((weak)) void irq_handler(uint32_t mcause) {
  (void)mcause;
  tb_timer_disable();
}

// ---------------------------------------------------------------------------------------------
// Freestanding libc subset
// ---------------------------------------------------------------------------------------------

void *memset(void *dst, int c, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  while (n--) *d++ = (uint8_t)c;
  return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  const uint8_t *s = (const uint8_t *)src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  uint8_t *d = (uint8_t *)dst;
  const uint8_t *s = (const uint8_t *)src;
  if (d < s) {
    while (n--) *d++ = *s++;
  } else {
    d += n;
    s += n;
    while (n--) *--d = *--s;
  }
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const uint8_t *x = (const uint8_t *)a;
  const uint8_t *y = (const uint8_t *)b;
  for (; n; n--, x++, y++) {
    if (*x != *y) return (int)*x - (int)*y;
  }
  return 0;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) {
    a++;
    b++;
  }
  return (int)(uint8_t)*a - (int)(uint8_t)*b;
}
