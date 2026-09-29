// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Functional coverage models for the micro-architecture extensions
 *
 * Verilator 5 does not implement SystemVerilog covergroups, so each coverage point is an explicit
 * named bin (tb_pkg::cov_register / cov_hit). Every test writes its bins to cov.txt and
 * scripts/regress.py merges them into a regression-wide coverage report. Assertion-style cover
 * points inside the RTL (UARCH_COVER) are collected separately via verilator --coverage-user.
 *
 *   arch_cov   control-transfer instruction mix seen at retirement (RVFI)
 *   bp_cov     prediction x outcome matrix and recovery scenarios at branch resolution
 *   cache_cov  hit/miss/eviction/bypass/maintenance scenarios, per-way replacement
 *   bus_cov    memory back-pressure and pipelining on the external buses
 */

// -------------------------------------------------------------------------------------------------
module arch_cov (
  input logic clk_i,
  input logic rst_ni,
  input logic cond_branch_i,
  input logic taken_i,
  input logic backward_i,
  input logic compressed_i,
  input logic jal_i,
  input logic jalr_i,
  input logic trap_i,
  input logic intr_i
);
  import tb_pkg::*;

  int b_cond[2][2][2];  // [compressed][backward][taken]
  int b_jal[2], b_jalr[2], b_trap, b_intr;

  initial begin
    for (int c = 0; c < 2; c++)
      for (int d = 0; d < 2; d++)
        for (int t = 0; t < 2; t++)
          b_cond[c][d][t] = cov_register("arch", $sformatf("%s_%s_%s",
              str_sel(c, "c.branch", "branch"), str_sel(d, "bwd", "fwd"),
              str_sel(t, "taken", "not_taken")));
    b_jal[0]  = cov_register("arch", "jal");
    b_jal[1]  = cov_register("arch", "c.j_c.jal");
    b_jalr[0] = cov_register("arch", "jalr");
    b_jalr[1] = cov_register("arch", "c.jr_c.jalr");
    b_trap    = cov_register("arch", "exception");
    b_intr    = cov_register("arch", "interrupt");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (cond_branch_i) cov_hit(b_cond[compressed_i][backward_i][taken_i]);
      if (jal_i)         cov_hit(b_jal[compressed_i]);
      if (jalr_i)        cov_hit(b_jalr[compressed_i]);
      if (trap_i)        cov_hit(b_trap);
      if (intr_i)        cov_hit(b_intr);
    end
  end
endmodule

// -------------------------------------------------------------------------------------------------
module bp_cov #(
  parameter bit RasEn      = 1'b0,
  parameter bit BtbEn      = 1'b0,
  parameter bit Tournament = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic resolve_i,        // conditional branch resolved in ID/EX
  input logic predicted_taken_i,
  input logic actual_taken_i,
  input logic nt_mispredict_i,  // predicted-taken branch flushed and fetch redirected to PC+len
  // tournament component predictions of the resolving branch
  input logic pred_bim_i,
  input logic pred_gsh_i,
  // jumps (JAL/JALR executed in ID/EX)
  input ibex_uarch_pkg::bp_jump_upd_t jump_i,
  input ibex_uarch_pkg::bp_perf_t     perf_i,
  input logic ras_full_i,       // RAS holds RasDepth entries
  input logic ras_empty_i,
  input logic target_recover_i  // fetch redirected after a wrong JALR target (redirect checker)
);
  import tb_pkg::*;

  int b_matrix[2][2];  // [predicted][actual]
  int b_b2b, b_consecutive_mispred, b_flush;
  int b_push, b_pop, b_poppush, b_ras_ok, b_ras_bad, b_ras_ovf, b_ras_unf;
  int b_btb_ok, b_btb_bad, b_btb_miss, b_recover;
  int b_choose_bim, b_choose_gsh, b_bim_right, b_gsh_right;
  logic resolve_q, last_mispred_q;

  initial begin
    for (int p = 0; p < 2; p++)
      for (int a = 0; a < 2; a++)
        b_matrix[p][a] = cov_register("bp", $sformatf("pred_%s_actual_%s",
            str_sel(p, "T", "NT"), str_sel(a, "T", "NT")));
    b_b2b                 = cov_register("bp", "back_to_back_branches");
    b_consecutive_mispred = cov_register("bp", "consecutive_mispredicts");
    b_flush               = cov_register("bp", "taken_mispredict_flush");
    if (RasEn) begin
      b_push    = cov_register("ras", "push_call");
      b_pop     = cov_register("ras", "pop_return");
      b_poppush = cov_register("ras", "pop_push_coroutine");
      b_ras_ok  = cov_register("ras", "return_predicted_correct");
      b_ras_bad = cov_register("ras", "return_predicted_wrong");
      b_ras_ovf = cov_register("ras", "overflow_push_when_full");
      b_ras_unf = cov_register("ras", "underflow_pop_when_empty");
    end
    if (BtbEn) begin
      b_btb_ok   = cov_register("btb", "indirect_hit_correct");
      b_btb_bad  = cov_register("btb", "indirect_hit_wrong_target");
      b_btb_miss = cov_register("btb", "indirect_miss");
    end
    if (RasEn || BtbEn) b_recover = cov_register("bp", "jalr_target_recovery");
    if (Tournament) begin
      b_choose_bim = cov_register("tournament", "chose_bimodal");
      b_choose_gsh = cov_register("tournament", "chose_gshare");
      b_bim_right  = cov_register("tournament", "disagree_bimodal_right");
      b_gsh_right  = cov_register("tournament", "disagree_gshare_right");
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      resolve_q      <= 1'b0;
      last_mispred_q <= 1'b0;
    end else begin
      resolve_q <= resolve_i;
      if (resolve_i) begin
        // outcome of the most recent conditional branch (not necessarily in the previous cycle)
        last_mispred_q <= (predicted_taken_i != actual_taken_i);
        cov_hit(b_matrix[predicted_taken_i][actual_taken_i]);
        if (resolve_q) cov_hit(b_b2b);
        if (last_mispred_q && (predicted_taken_i != actual_taken_i)) cov_hit(b_consecutive_mispred);
      end
      if (nt_mispredict_i) cov_hit(b_flush);

      if (RasEn && jump_i.valid) begin
        if (jump_i.push && !jump_i.pop) cov_hit(b_push);
        if (jump_i.pop && !jump_i.push) cov_hit(b_pop);
        if (jump_i.pop && jump_i.push)  cov_hit(b_poppush);
        if (jump_i.push && !jump_i.pop && ras_full_i) cov_hit(b_ras_ovf);
        if (jump_i.pop && !jump_i.push && ras_empty_i) cov_hit(b_ras_unf);
      end
      if (RasEn && perf_i.ras_pred) cov_hit(perf_i.jalr_mispred ? b_ras_bad : b_ras_ok);
      if (BtbEn && perf_i.btb_pred) cov_hit(perf_i.jalr_mispred ? b_btb_bad : b_btb_ok);
      if (BtbEn && jump_i.valid && jump_i.indirect && !perf_i.btb_pred && !perf_i.ras_pred)
        cov_hit(b_btb_miss);
      if ((RasEn || BtbEn) && target_recover_i) cov_hit(b_recover);
      if (Tournament && resolve_i && pred_bim_i != pred_gsh_i) begin
        cov_hit(predicted_taken_i == pred_gsh_i ? b_choose_gsh : b_choose_bim);
        cov_hit(actual_taken_i == pred_gsh_i ? b_gsh_right : b_bim_right);
      end
    end
  end
endmodule

// -------------------------------------------------------------------------------------------------
module cache_cov #(
  parameter string       Name         = "cache",
  parameter int unsigned NumWays      = 2,
  parameter bit          ReadOnly     = 1'b0,
  parameter bit          WriteThrough = 1'b0
) (
  input logic        clk_i,
  input logic        rst_ni,
  input logic        lookup_i,          // cacheable request looked up (first or replay)
  input logic        first_lookup_i,    // first lookup of the request (perf_access)
  input logic        hit_i,
  input logic        we_i,
  input logic [7:0]  hit_way_i,
  input logic [7:0]  victim_way_i,
  input logic        miss_start_i,      // refill/evict sequence started this cycle
  input logic        evict_start_i,     // ... with a dirty victim
  input logic        bypass_i,
  input logic        core_gnt_i,
  input logic        mem_stall_i,       // memory request not granted
  input logic        refilling_i,
  input logic        maint_done_i,
  input logic        maint_writeback_i  // write-back performed during maintenance
);
  import tb_pkg::*;

  int b_rd_hit, b_rd_miss, b_wr_hit, b_wr_miss, b_evict, b_bypass_rd, b_bypass_wr;
  int b_b2b, b_b2b_miss, b_refill_stall, b_maint, b_maint_wb;
  int b_hit_way[NumWays], b_victim_way[NumWays];
  logic maint_wb_seen_q, last_missed_q;

  initial begin
    b_rd_hit       = cov_register(Name, "read_hit");
    b_rd_miss      = cov_register(Name, "read_miss");
    b_b2b          = cov_register(Name, "back_to_back_hit");
    b_b2b_miss     = cov_register(Name, "back_to_back_miss");
    b_refill_stall = cov_register(Name, "refill_mem_backpressure");
    b_maint        = cov_register(Name, str_sel(ReadOnly, "invalidate_all", "clean_all"));
    if (!ReadOnly) begin
      b_wr_hit    = cov_register(Name, str_sel(WriteThrough, "write_through_hit", "write_hit"));
      b_wr_miss   = cov_register(Name, str_sel(WriteThrough, "write_through_miss_no_allocate",
                                               "write_miss_allocate"));
      b_bypass_rd = cov_register(Name, "uncached_read");
      b_bypass_wr = cov_register(Name, "uncached_write");
      if (!WriteThrough) begin
        b_evict    = cov_register(Name, "dirty_eviction");
        b_maint_wb = cov_register(Name, "clean_with_writeback");
      end
    end
    for (int w = 0; w < NumWays; w++) begin
      b_hit_way[w]    = cov_register(Name, $sformatf("hit_way%0d", w));
      b_victim_way[w] = cov_register(Name, $sformatf("fill_way%0d", w));
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      maint_wb_seen_q <= 1'b0;
      last_missed_q   <= 1'b0;
    end else begin
      if (first_lookup_i) begin
        if (hit_i) cov_hit(we_i ? b_wr_hit  : b_rd_hit);
        else       cov_hit(we_i ? b_wr_miss : b_rd_miss);
        if (!hit_i && last_missed_q) cov_hit(b_b2b_miss);
        last_missed_q <= !hit_i;
      end
      if (hit_i) begin
        cov_hit(b_hit_way[hit_way_i]);
        if (core_gnt_i) cov_hit(b_b2b);
      end
      if (miss_start_i)                cov_hit(b_victim_way[victim_way_i]);
      if (evict_start_i && !ReadOnly && !WriteThrough) cov_hit(b_evict);
      if (bypass_i && !ReadOnly)       cov_hit(we_i ? b_bypass_wr : b_bypass_rd);
      if (refilling_i && mem_stall_i)  cov_hit(b_refill_stall);

      if (maint_writeback_i) maint_wb_seen_q <= 1'b1;
      if (maint_done_i) begin
        cov_hit(b_maint);
        if (!ReadOnly && !WriteThrough && (maint_wb_seen_q || maint_writeback_i)) cov_hit(b_maint_wb);
        maint_wb_seen_q <= 1'b0;
      end
    end
  end
endmodule

// -------------------------------------------------------------------------------------------------
module prefetch_cov (
  input logic clk_i,
  input logic rst_ni,
  input logic issue_i,          // prefetch of a line started
  input logic hit_i,            // refill served from the buffer
  input logic hit_filling_i,    // ... while the prefetch was still arriving
  input logic drop_i,           // prefetch beat dropped after a FENCE.I flush
  input logic demand_first_i    // demand forward overtook a pending prefetch
);
  import tb_pkg::*;

  int b_issue, b_hit, b_filling, b_drop, b_demand;

  initial begin
    b_issue   = cov_register("prefetch", "line_prefetched");
    b_hit     = cov_register("prefetch", "refill_from_buffer");
    b_filling = cov_register("prefetch", "hit_while_filling");
    b_drop    = cov_register("prefetch", "dropped_after_fence_i");
    b_demand  = cov_register("prefetch", "demand_priority_over_prefetch");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (issue_i)        cov_hit(b_issue);
      if (hit_i)          cov_hit(b_hit);
      if (hit_filling_i)  cov_hit(b_filling);
      if (drop_i)         cov_hit(b_drop);
      if (demand_first_i) cov_hit(b_demand);
    end
  end
endmodule

// -------------------------------------------------------------------------------------------------
module bus_cov (
  input logic       clk_i,
  input logic       rst_ni,
  input logic       imem_stall_i,
  input logic       dmem_stall_i,
  input logic [3:0] core_instr_outstanding_i,
  input logic       fence_done_i,
  input logic       data_err_i
);
  import tb_pkg::*;

  int b_istall, b_dstall, b_two_outstanding, b_fence, b_derr;

  initial begin
    b_istall          = cov_register("bus", "imem_grant_stall");
    b_dstall          = cov_register("bus", "dmem_grant_stall");
    b_two_outstanding = cov_register("bus", "fetch_two_outstanding");
    b_fence           = cov_register("bus", "fence_i_sequence");
    b_derr            = cov_register("bus", "data_bus_error");
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      if (imem_stall_i)                   cov_hit(b_istall);
      if (dmem_stall_i)                   cov_hit(b_dstall);
      if (core_instr_outstanding_i >= 2)  cov_hit(b_two_outstanding);
      if (fence_done_i)                   cov_hit(b_fence);
      if (data_err_i)                     cov_hit(b_derr);
    end
  end
endmodule
