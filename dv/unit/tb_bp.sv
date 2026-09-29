// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Block-level testbench for ibex_bp_dynamic
 *
 * 1. Target / type decode: 20k random JAL, BRANCH, C.J, C.JAL, C.BEQZ, C.BNEZ and non-control
 *    instructions at random PCs, checked against an independent reference decoder (jumps always
 *    predicted taken, non-control instructions never).
 * 2. Direction learning: a synthetic branch stream drives lookup and then update, like the pipeline.
 *    Accuracy after warm-up is checked against what each predictor can learn:
 *                   always  alternating  period-4  random
 *        static       100       50          75       ~50   (backward branch: always "taken")
 *        1-bit        100        0          50       ~50
 *        bimodal      100      0-50         75       ~50
 *        gshare       100      100         100       ~50
 *        tournament   100      100         100       ~50
 * 3. Return address stack: random nested call/return sequences up to three times deeper than the
 *    RAS. A circular RAS overwrites its oldest entries on overflow, so it must never predict a wrong
 *    return: every prediction must equal the top of a software shadow stack, and a prediction must
 *    be made exactly when the modelled RAS occupancy (saturating at the depth) is non-zero.
 * 4. BTB: indirect jumps at random PCs with random targets, including aliasing PCs (same index,
 *    different tag) that must never produce a false hit.
 * The predictor's internal SVA run throughout.
 */
module tb_bp #(
  parameter int MODE = 4,    // 1 static, 2 1-bit, 3 bimodal, 4 gshare, 5 tournament
  parameter int PHT  = 512,
  parameter int GHR  = 8,
  parameter int RAS  = 8,
  parameter int BTB  = 16
);
  import ibex_uarch_pkg::*;
  import tb_pkg::*;

  logic clk = 1'b0, rst_n = 1'b1;
  initial forever #5 clk = ~clk;

  logic [31:0]  fetch_rdata, fetch_pc;
  logic         fetch_valid;
  logic         pred_taken;
  logic [31:0]  pred_pc;
  bp_meta_t     pred_meta;
  logic         entry_valid;
  logic [31:0]  entry_rdata, entry_pc;
  bp_cond_upd_t cond_upd;
  bp_jump_upd_t jump_upd;

  ibex_bp_dynamic #(
    .Mode      (bp_mode_e'(MODE)),
    .PhtEntries(PHT),
    .GhrBits   (GHR),
    .RasDepth  (RAS),
    .BtbEntries(BTB)
  ) dut (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    .fetch_rdata_i         (fetch_rdata),
    .fetch_pc_i            (fetch_pc),
    .fetch_valid_i         (fetch_valid),
    .predict_branch_taken_o(pred_taken),
    .predict_branch_pc_o   (pred_pc),
    .predict_meta_o        (pred_meta),
    .id_entry_valid_i      (entry_valid),
    .id_entry_rdata_i      (entry_rdata),
    .id_entry_pc_i         (entry_pc),
    .cond_upd_i            (cond_upd),
    .jump_upd_i            (jump_upd)
  );

  // ---------------- instruction encoders ----------------
  function automatic logic [31:0] enc_jal(int off, logic [4:0] rd = 5'd1);
    logic [20:0] i = 21'(off);
    return {i[20], i[10:1], i[11], i[19:12], rd, 7'b1101111};
  endfunction
  function automatic logic [31:0] enc_jalr(logic [4:0] rd, logic [4:0] rs1);
    return {12'd0, rs1, 3'b000, rd, 7'b1100111};
  endfunction
  function automatic logic [31:0] enc_branch(int off, logic [2:0] f3);
    logic [12:0] i = 13'(off);
    return {i[12], i[10:5], 5'd11, 5'd10, f3, i[4:1], i[11], 7'b1100011};
  endfunction
  function automatic logic [31:0] enc_cj(int off, bit link);  // C.J / C.JAL
    logic [11:0] i = 12'(off);
    return {16'h0, link ? 3'b001 : 3'b101, i[11], i[4], i[9:8], i[10], i[6], i[7], i[3:1], i[5],
            2'b01};
  endfunction
  function automatic logic [31:0] enc_cb(int off, bit bnez);  // C.BEQZ / C.BNEZ, rs1' = x8
    logic [8:0] i = 9'(off);
    return {16'h0, bnez ? 3'b111 : 3'b110, i[8], i[4:3], 3'b000, i[7:6], i[2:1], i[5], 2'b01};
  endfunction

  task automatic idle();
    fetch_valid     = 1'b0;
    entry_valid     = 1'b0;
    cond_upd        = '0;
    jump_upd        = '0;
  endtask

  // ---------------- test 1: decode ----------------
  task automatic test_decode(int n);
    int errors_before = error_count;
    for (int k = 0; k < n; k++) begin
      int kind, off;
      logic [31:0] insn, pc, exp_target;
      logic        exp_ctrl, exp_jump;
      pc   = {$urandom, 1'b0} & 32'h00ff_fffe;
      kind = $urandom_range(6, 0);
      unique case (kind)
        0: begin off = int'($urandom_range(2**20 - 1, 0)) - 2**19; off &= ~1;
                 insn = enc_jal(off, 5'd0); exp_jump = 1; exp_ctrl = 1; end
        1: begin off = int'($urandom_range(2**12 - 1, 0)) - 2**11; off &= ~1;
                 insn = enc_branch(off, 3'b000); exp_jump = 0; exp_ctrl = 1; end
        2, 3: begin off = int'($urandom_range(2**11 - 1, 0)) - 2**10; off &= ~1;
                 insn = enc_cj(off, kind == 3); exp_jump = 1; exp_ctrl = 1; end
        4, 5: begin off = int'($urandom_range(2**8 - 1, 0)) - 2**7; off &= ~1;
                 insn = enc_cb(off, kind == 5); exp_jump = 0; exp_ctrl = 1; end
        default: begin  // OP-IMM: never predicted
                 insn = {$urandom} & 32'hffff_ff80 | 32'h13; off = 0; exp_jump = 0; exp_ctrl = 0; end
      endcase
      exp_target = pc + 32'(off);

      @(negedge clk);
      idle();
      fetch_rdata = insn;
      fetch_pc    = pc;
      fetch_valid = 1'b1;
      #1;
      if (exp_ctrl && pred_pc !== exp_target)
        tb_error("BP", $sformatf("insn 0x%08x at 0x%08x: target 0x%08x, expected 0x%08x",
                                 insn, pc, pred_pc, exp_target));
      if (exp_jump && !pred_taken)
        tb_error("BP", $sformatf("jump 0x%08x not predicted taken", insn));
      if (!exp_ctrl && pred_taken)
        tb_error("BP", $sformatf("non-control instruction 0x%08x predicted taken", insn));
      if (MODE == 1 && exp_ctrl && !exp_jump && pred_taken != (off < 0))
        tb_error("BP", $sformatf("static mode: branch offset %0d predicted %0d", off, pred_taken));
    end
    idle();
    $display("[BP] decode test: %0d random instructions, %0d errors", n, error_count - errors_before);
  endtask

  // ---------------- test 2: direction learning ----------------
  task automatic run_pattern(string name, logic [31:0] pc, int iters, int warmup,
                             int kind, output real accuracy);
    int correct = 0, measured = 0;
    logic [31:0] insn = enc_branch(-64, 3'b001);  // backward BNE
    for (int k = 0; k < iters; k++) begin
      bit taken;
      bp_meta_t meta;
      unique case (kind)
        0: taken = 1;
        1: taken = k[0];
        2: taken = (k % 4) != 3;
        default: taken = $urandom_range(1, 0);
      endcase
      @(negedge clk);
      idle();
      fetch_rdata = insn;
      fetch_pc    = pc;
      fetch_valid = 1'b1;
      #1;
      meta = pred_meta;
      if (k >= warmup) begin
        measured++;
        if (pred_taken == taken) correct++;
      end
      // resolve in the next cycle, carrying the metadata used for the prediction
      @(negedge clk);
      idle();
      cond_upd.valid = 1'b1;
      cond_upd.taken = taken;
      cond_upd.meta  = meta;
    end
    @(negedge clk);
    idle();
    accuracy = 100.0 * correct / measured;
    $display("[BP] %-12s accuracy %6.2f%% (%0d/%0d after %0d warm-up)", name, accuracy, correct,
             measured, warmup);
  endtask

  task automatic expect_acc(string name, real acc, real lo, real hi);
    if (acc < lo || acc > hi)
      tb_error("BP", $sformatf("%s accuracy %.2f%% outside expected [%.0f, %.0f]", name, acc, lo, hi));
  endtask

  // ---------------- test 3: return address stack ----------------
  // A call enters ID (id_entry), its return is looked up in IF later. Calls and returns are
  // randomly interleaved with nesting beyond the RAS depth.
  task automatic test_ras(int n);
    logic [31:0] shadow[$];   // full software call stack
    int model_cnt = 0;        // modelled RAS occupancy
    int predicted = 0, correct = 0, errors_before = error_count;
    logic [31:0] pc = 32'h0001_0000;
    for (int k = 0; k < n; k++) begin
      bit do_call = (shadow.size() == 0) || (shadow.size() < 3 * RAS && $urandom_range(1, 0));
      pc = pc + 32'($urandom_range(64, 1) * 4);
      @(negedge clk);
      idle();
      if (do_call) begin
        // JAL ra, <somewhere> enters ID: push pc + 4
        entry_valid = 1'b1;
        entry_rdata = enc_jal(256, 5'd1);
        entry_pc    = pc;
        shadow.push_back(pc + 4);
        if (model_cnt < RAS) model_cnt++;
      end else begin
        // `ret` at the fetch output: predicted from the RAS ...
        logic [31:0] expect_target = shadow[$];
        fetch_rdata = enc_jalr(5'd0, 5'd1);
        fetch_pc    = pc;
        fetch_valid = 1'b1;
        #1;
        if (pred_taken) begin
          predicted++;
          if (pred_pc == expect_target) correct++;
          else tb_error("RAS", $sformatf("return predicted to 0x%08x, expected 0x%08x (depth %0d)",
                                         pred_pc, expect_target, shadow.size()));
        end
        if (pred_taken != (model_cnt > 0)) begin
          tb_error("RAS", $sformatf("return %s predicted with modelled occupancy %0d",
                                    str_sel(pred_taken, "", "not"), model_cnt));
        end
        if (model_cnt > 0) model_cnt--;
        // ... then enters ID: pop
        @(negedge clk);
        idle();
        entry_valid = 1'b1;
        entry_rdata = enc_jalr(5'd0, 5'd1);
        entry_pc    = pc;
        void'(shadow.pop_back());
      end
    end
    @(negedge clk);
    idle();
    $display("[RAS] %0d call/return events: %0d returns predicted, %0d with the correct target, %0d errors",
             n, predicted, correct, error_count - errors_before);
  endtask

  // ---------------- test 4: indirect-jump BTB ----------------
  task automatic test_btb(int n);
    int hits = 0, errors_before = error_count;
    logic [31:0] targets[logic [31:0]];  // pc -> last target
    for (int k = 0; k < n; k++) begin
      // a small set of jump sites, some of which alias in the BTB index
      logic [31:0] pc     = 32'h0002_0000 + 32'($urandom_range(7, 0) * 2 * BTB * 2) +
                            32'($urandom_range(3, 0) * 2);
      logic [31:0] target = ($urandom_range(3, 0) == 0) ? {$urandom, 1'b0} & 32'h000f_fffe
                                                        : 32'h0004_0000 + pc[15:0];
      @(negedge clk);
      idle();
      fetch_rdata = enc_jalr(5'd1, 5'd10);  // jalr ra, 0(a0): an indirect call
      fetch_pc    = pc;
      fetch_valid = 1'b1;
      #1;
      if (pred_taken) begin
        hits++;
        if (!targets.exists(pc))
          tb_error("BTB", $sformatf("false hit for never-seen jump at 0x%08x", pc));
        else if (pred_pc !== targets[pc])
          tb_error("BTB", $sformatf("jump at 0x%08x predicted 0x%08x, last target 0x%08x",
                                    pc, pred_pc, targets[pc]));
      end
      // the call enters ID (RAS push) ...
      @(negedge clk);
      idle();
      entry_valid = 1'b1;
      entry_rdata = enc_jalr(5'd1, 5'd10);
      entry_pc    = pc;
      // ... and executes in the next cycle, as in the pipeline: update the BTB with the real target
      // (this also evicts aliasing sites). CallRetDecodeConsistent relies on this ordering.
      @(negedge clk);
      idle();
      jump_upd.valid    = 1'b1;
      jump_upd.push     = 1'b1;
      jump_upd.indirect = 1'b1;
      jump_upd.pc       = pc;
      jump_upd.link     = pc + 4;
      jump_upd.target   = target;
      // aliasing sites overwrite each other: forget every site that maps to the same entry
      begin
        logic [31:0] victims[$];
        foreach (targets[p]) if (p[$clog2(BTB):1] == pc[$clog2(BTB):1]) victims.push_back(p);
        foreach (victims[v]) targets.delete(victims[v]);
      end
      targets[pc] = target;
    end
    @(negedge clk);
    idle();
    $display("[BTB] %0d indirect jumps: %0d BTB hits, %0d errors", n, hits,
             error_count - errors_before);
  endtask

  initial begin
    real a_always, a_alt, a_p4, a_rand;
    idle();
    fetch_rdata = '0;
    fetch_pc    = '0;
    entry_rdata = '0;
    entry_pc    = '0;
    #1 rst_n = 0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1;

    $display("[BP] mode=%0d pht=%0d ghr=%0d ras=%0d btb=%0d", MODE, PHT, GHR, RAS, BTB);
    test_decode(20000);

    run_pattern("always",      32'h1000, 400, 20,  0, a_always);
    run_pattern("alternating", 32'h2000, 400, 40,  1, a_alt);
    run_pattern("period-4",    32'h3000, 800, 80,  2, a_p4);
    run_pattern("random",      32'h4000, 2000, 50, 3, a_rand);

    unique case (MODE)
      1: begin expect_acc("always", a_always, 100, 100); expect_acc("alternating", a_alt, 45, 55);
               expect_acc("period-4", a_p4, 70, 80); end
      2: begin expect_acc("always", a_always, 100, 100); expect_acc("alternating", a_alt, 0, 5);
               expect_acc("period-4", a_p4, 45, 55); expect_acc("random", a_rand, 40, 60); end
      3: begin expect_acc("always", a_always, 100, 100); expect_acc("alternating", a_alt, 0, 55);
               expect_acc("period-4", a_p4, 70, 80); expect_acc("random", a_rand, 40, 60); end
      4, 5: begin expect_acc("always", a_always, 100, 100); expect_acc("alternating", a_alt, 99, 100);
               expect_acc("period-4", a_p4, 99, 100); expect_acc("random", a_rand, 40, 60); end
      default: ;
    endcase

    if (RAS > 0) test_ras(4000);
    if (BTB > 0) test_btb(4000);

    if (error_count == 0) $display("[TB] TEST PASSED");
    else                  $display("[TB] TEST FAILED");
    $finish;
  end

endmodule
