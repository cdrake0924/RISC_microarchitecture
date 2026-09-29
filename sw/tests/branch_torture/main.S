# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# branch_torture: control-flow corner cases for the IF-stage branch predictor, the skid buffer and
# the ID/EX mispredict-recovery path.
#
# Every block adds a constant to s0 on its architecturally correct path (PASS) and a poison value on
# any wrong path. PASS also accumulates the constant into the assembler symbol EXPECTED, so the final
# value of s0 is checked against a sum computed at build time. The RVFI control-flow checker in the
# testbench independently verifies every retired branch.

#include "platform.h"

  .set EXPECTED, 0

  .macro PASS val
  addi  s0, s0, \val
  .set  EXPECTED, EXPECTED + \val
  .endm

  # Executed \count times (inside a loop)
  .macro PASS_N val, count
  addi  s0, s0, \val
  .set  EXPECTED, EXPECTED + (\val * \count)
  .endm

  .macro POISON
  lui   t6, 0x100
  add   s0, s0, t6
  .endm

  .section .data
  .balign 4
value_one:
  .word 1

  .section .text
  .global main
main:
  addi  sp, sp, -16
  sw    ra, 12(sp)
  sw    s0, 8(sp)
  li    s0, 0
  j     tests

# ---- leaf function (defined before the final check so EXPECTED includes it) ----
leaf:
  PASS  12
  ret

tests:
  # 1. Forward taken / forward not-taken (BTFN predicts both not-taken)
  li    t0, 1
  bnez  t0, 1f
  POISON
1:
  PASS  1
  beqz  t0, 2f
  PASS  2
2:

  # 2. Backward loop branch, 5 iterations
  li    t0, 5
3:
  PASS_N 3, 5
  addi  t0, t0, -1
  bnez  t0, 3b

  # 3. Branch chain: a branch whose target is another branch
  li    t0, 0
  beqz  t0, 4f
  POISON
4:
  beqz  t0, 5f
  POISON
5:
  bnez  t0, 6f
  PASS  4
6:

  # 4. Compressed branches (C.BEQZ / C.BNEZ need x8..x15)
  .option push
  .option rvc
  li    a0, 0
  c.beqz a0, 7f
  POISON
7:
  c.bnez a0, 8f
  PASS  5
8:
  .option pop

  # 5. 32-bit branch at a halfword-aligned PC (straddles two fetch words)
  .option push
  .option rvc
  .balign 4
  c.nop
  .option norvc
  addi  t0, zero, 1
  bne   t0, zero, 9f
  POISON
9:
  PASS  6
  .option pop

  # 6. Backward branch that is NOT taken (BTFN predicts taken -> flush), immediately followed by a
  #    taken branch in the shadow of the mispredict
  li    t0, 0
10:
  nop
  bnez  t0, 10b
  beqz  t0, 11f
  POISON
11:
  PASS  7

  # 7. Jump to jump, call/return, indirect jumps (returns use the RAS, other JALRs the BTB)
  j     12f
  POISON
12:
  j     13f
  POISON
13:
  PASS  8
  call  leaf
  PASS  9
  la    t1, 14f
  jalr  x0, 0(t1)
  POISON
14:
  PASS  10
  la    a1, 15f
  .option push
  .option rvc
  c.jr  a1
  .option pop
  POISON
15:
  PASS  11

  # 8. Load-use hazard feeding a branch
  la    t1, value_one
  lw    t2, 0(t1)
  bnez  t2, 16f
  POISON
16:
  PASS  13

  # 9. Alternating pattern T,NT,T,NT,... (learnable by gshare, not by bimodal)
  li    t0, 64
  li    t2, 0
17:
  andi  t3, t0, 1
  beqz  t3, 18f
  addi  t2, t2, 1
18:
  addi  t0, t0, -1
  bnez  t0, 17b
  li    t3, 32
  bne   t2, t3, fail
  PASS  14

  # 10. 32-bit branch spanning two 16-byte cache lines (starts at byte 14 of a line)
  .option push
  .option norvc
  .balign 16
  nop
  nop
  nop
  .option rvc
  c.nop
  .option norvc
  bne   s0, zero, 19f
  POISON
19:
  PASS  15
  .option pop

  # 11. Jump into an instruction that spans two cache lines; the skipped padding would poison s0
  j     20f
  .option push
  .option rvc
  .balign 16
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  c.addi s0, 1
  .option norvc
20:
  PASS  16
  .option pop

  # 12. Tight nested loops (inner loop exit mispredicts every outer iteration)
  li    t0, 8
21:
  li    t1, 4
22:
  PASS_N 17, 32
  addi  t1, t1, -1
  bnez  t1, 22b
  addi  t0, t0, -1
  bnez  t0, 21b

  # ---- final check ----
  li    t0, EXPECTED
  bne   s0, t0, fail
  li    a0, 0
  j     done

fail:
  li    a0, 1

done:
  lw    ra, 12(sp)
  lw    s0, 8(sp)
  addi  sp, sp, 16
  ret
