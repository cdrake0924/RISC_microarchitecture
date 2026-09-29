// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * L1 cache replacement policy
 *
 * Chooses the victim way for a set on a miss and maintains the per-set replacement state.
 *
 *   ReplPlru   - tree pseudo-LRU, NumWays-1 bits per set. Each node points towards the less
 *                recently used half; hits and fills flip the nodes on their path to point away.
 *                For 2 ways this is exact LRU.
 *   ReplFifo   - per-set round-robin pointer, advanced on every fill.
 *   ReplRandom - 16-bit maximal-length LFSR, free running.
 *
 * All policies fill invalid ways first (lowest index), so a cold set never evicts valid data.
 */

`include "uarch_assert.svh"

module ibex_l1_repl import ibex_uarch_pkg::*; #(
  parameter int unsigned  NumSets = 64,
  parameter int unsigned  NumWays = 2,
  parameter repl_policy_e Policy  = ReplPlru,
  localparam int unsigned SetW    = (NumSets > 1) ? $clog2(NumSets) : 1,
  localparam int unsigned WayW    = (NumWays > 1) ? $clog2(NumWays) : 1
) (
  input  logic               clk_i,
  input  logic               rst_ni,

  // Set being looked up / updated (the cache processes one request at a time)
  input  logic [SetW-1:0]    set_i,
  input  logic [NumWays-1:0] valid_i,     // valid bits of the ways in set_i
  output logic [WayW-1:0]    victim_o,    // way to replace on a miss in set_i

  input  logic               hit_i,       // access hit way hit_way_i of set_i
  input  logic [WayW-1:0]    hit_way_i,
  input  logic               fill_i,      // line installed into way fill_way_i of set_i
  input  logic [WayW-1:0]    fill_way_i
);

  localparam int unsigned Levels = WayW;  // depth of the PLRU tree

  logic [WayW-1:0] policy_victim;
  logic [WayW-1:0] invalid_way;
  logic            any_invalid;

  // Lowest-index invalid way
  always_comb begin
    invalid_way = '0;
    any_invalid = 1'b0;
    for (int w = NumWays - 1; w >= 0; w--) begin
      if (!valid_i[w]) begin
        invalid_way = WayW'(w);
        any_invalid = 1'b1;
      end
    end
  end

  assign victim_o = any_invalid ? invalid_way : policy_victim;

  if (NumWays == 1) begin : g_direct_mapped
    assign policy_victim = '0;

    logic unused_inputs;
    assign unused_inputs = ^{set_i, hit_i, hit_way_i, fill_i, fill_way_i};

  end else if (Policy == ReplPlru) begin : g_plru
    localparam int unsigned NodeBits = NumWays - 1;

    logic [NumSets-1:0][NodeBits-1:0] tree_q;
    logic                touch;
    logic [WayW-1:0]     touch_way;

    // Walk the tree from the root following the node bits (0 = go left, 1 = go right).
    function automatic logic [WayW-1:0] plru_victim(logic [NodeBits-1:0] tree);
      int unsigned node;
      logic [WayW-1:0] way;
      node = 0;
      way  = '0;
      for (int unsigned l = 0; l < Levels; l++) begin
        way[Levels-1-l] = tree[node];
        node = 2 * node + 1 + int'(tree[node]);
      end
      return way;
    endfunction

    // Make every node on the path to `way` point away from it.
    function automatic logic [NodeBits-1:0] plru_touch(logic [NodeBits-1:0] tree,
                                                       logic [WayW-1:0]     way);
      int unsigned node;
      logic dir;
      node = 0;
      for (int unsigned l = 0; l < Levels; l++) begin
        dir        = way[Levels-1-l];
        tree[node] = ~dir;
        node       = 2 * node + 1 + int'(dir);
      end
      return tree;
    endfunction

    assign policy_victim = plru_victim(tree_q[set_i]);
    assign touch         = hit_i | fill_i;
    assign touch_way     = fill_i ? fill_way_i : hit_way_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        tree_q <= '0;
      end else if (touch) begin
        tree_q[set_i] <= plru_touch(tree_q[set_i], touch_way);
      end
    end

`ifndef SYNTHESIS
    // After touching a way, PLRU must never immediately select it as the victim.
    logic            chk_touch_q;
    logic [SetW-1:0] chk_set_q;
    logic [WayW-1:0] chk_way_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        chk_touch_q <= 1'b0;
      end else begin
        chk_touch_q <= touch;
      end
    end
    always_ff @(posedge clk_i) begin
      chk_set_q <= set_i;
      chk_way_q <= touch_way;
    end
    `UARCH_ASSERT(PlruNeverEvictsMru,
        chk_touch_q |-> (plru_victim(tree_q[chk_set_q]) != chk_way_q))
`endif

  end else if (Policy == ReplFifo) begin : g_fifo
    logic [NumSets-1:0][WayW-1:0] ptr_q;

    assign policy_victim = ptr_q[set_i];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ptr_q <= '0;
      end else if (fill_i) begin
        ptr_q[set_i] <= ptr_q[set_i] + WayW'(1);
      end
    end

    logic unused_hit;
    assign unused_hit = ^{hit_i, hit_way_i, fill_way_i};

  end else begin : g_random
    // x^16 + x^14 + x^13 + x^11 + 1 (maximal length), shifted every cycle
    logic [15:0] lfsr_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        lfsr_q <= 16'hACE1;
      end else begin
        lfsr_q <= {lfsr_q[14:0], lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
      end
    end

    assign policy_victim = lfsr_q[WayW-1:0];

    logic unused_inputs;
    assign unused_inputs = ^{set_i, hit_i, hit_way_i, fill_i, fill_way_i};
  end

`ifndef SYNTHESIS
  initial begin
    if ((NumWays & (NumWays - 1)) != 0) begin
      $fatal(1, "ibex_l1_repl: NumWays (%0d) must be a power of two", NumWays);
    end
  end

  // (victim_o is always in range: NumWays is a power of two and victim_o is log2(NumWays) wide.)
  // Never evict a valid line while an invalid way is available
  `UARCH_ASSERT(ReplInvalidFirst, !(&valid_i) |-> !valid_i[victim_o])
`endif

endmodule
