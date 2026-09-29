// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Lightweight concurrent-assertion macros for the micro-architecture extensions.
//
// Upstream Ibex routes its assertions through prim_assert.sv, which compiles them to no-ops when
// the simulator is Verilator. The extensions in this repository are verified primarily with that
// simulator, so they use these native SVA macros instead (evaluated when built with --assert).
// (Note: a comment line must not start with the simulator's name - it would be read as a pragma.)
//
// All macros assume a clock named clk_i and an active-low reset named rst_ni in scope.

`ifndef UARCH_ASSERT_SVH
`define UARCH_ASSERT_SVH

`ifndef SYNTHESIS

  // Concurrent assertion, disabled during reset.
  `define UARCH_ASSERT(__name, __prop)                                         \
    __name: assert property (@(posedge clk_i) disable iff (!rst_ni) (__prop))  \
      else $error("[ASSERT FAILED] %m: %s", `"__name`");

  // Assert that a signal carries no X/Z while an enable is high.
  `define UARCH_ASSERT_KNOWN_IF(__name, __sig, __en)                           \
    `UARCH_ASSERT(__name, (__en) |-> !$isunknown(__sig))

  // Functional-coverage point (reported by verilator_coverage / simulator coverage DB).
  `define UARCH_COVER(__name, __prop)                                          \
    __name: cover property (@(posedge clk_i) disable iff (!rst_ni) (__prop));

`else

  `define UARCH_ASSERT(__name, __prop)
  `define UARCH_ASSERT_KNOWN_IF(__name, __sig, __en)
  `define UARCH_COVER(__name, __prop)

`endif

`endif  // UARCH_ASSERT_SVH
