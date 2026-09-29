// Copyright 2026 RISC_microarchitecture contributors.
// Copyright lowRISC contributors (instruction decode derived from ibex_branch_predict.sv).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Branch predictor for the Ibex IF stage
 *
 * Replaces the upstream static predictor (ibex_branch_predict). It inspects the instruction at the
 * output of the prefetch buffer and decides whether IF should redirect fetch before the instruction
 * reaches ID/EX, and where to.
 *
 *   Direct branches/jumps (JAL, BRANCH, C.J, C.JAL, C.BEQZ, C.BNEZ)
 *     Target decoded from the immediate, so no BTB is needed for them. Unconditional jumps are
 *     always predicted taken; conditional branches follow the direction predictor (Mode):
 *       BpStatic     backward taken / forward not-taken (BTFN), identical to upstream
 *       BpOneBit     PC-indexed table of 1-bit "last outcome" entries
 *       BpBimodal    PC-indexed table of 2-bit saturating counters
 *       BpGshare     table indexed by PC[IdxW:1] xor global history register (GHR)
 *       BpTournament bimodal + gshare components and a PC-indexed 2-bit chooser
 *   Register-indirect jumps (JALR, C.JR, C.JALR)
 *     Returns (RISC-V link-register hint convention) are predicted from a return address stack
 *     (RasDepth entries); other indirect jumps from a direct-mapped, tagged branch target buffer
 *     (BtbEntries entries) holding the last target of each indirect jump.
 *
 * Training
 *   The prediction metadata (table indices, component predictions, predicted target, source) is
 *   returned on predict_meta_o and carried with the instruction to ID/EX, which resolves it and
 *   drives cond_upd_i (every conditional branch) and jump_upd_i (every JAL/JALR). Using the carried
 *   indices means the entry that made a prediction is the one trained, even though the GHR may have
 *   advanced in between. The direction tables, GHR and BTB are updated at resolution, so wrong-path
 *   instructions never pollute them and no repair logic is needed.
 *
 *   The RAS is updated one stage earlier, when a call/return *enters ID* (id_entry_*_i). In Ibex no
 *   wrong-path instruction ever enters ID (a redirect blocks the IF/ID register write), so this is
 *   as safe as updating at execution, and it guarantees that a return fetched right behind its
 *   call (e.g. a function whose first instruction is `ret`) already sees the call's entry.
 *
 *   Predictor state is a performance hint only: every prediction is verified in ID/EX, and wrong
 *   predictions are repaired by the controller (nt_branch_mispredict for a wrongly-taken branch,
 *   a normal PC redirect for a missed branch or a wrong JALR target).
 */

`include "uarch_assert.svh"

module ibex_bp_dynamic import ibex_uarch_pkg::*; #(
  parameter bp_mode_e    Mode       = BpGshare,
  parameter int unsigned PhtEntries = 512,  // direction table entries, power of two, <= 4096
  parameter int unsigned GhrBits    = 8,    // global history length, <= log2(PhtEntries)
  parameter int unsigned RasDepth   = 8,    // return address stack entries, power of two, 0 = off
  parameter int unsigned BtbEntries = 16    // indirect-jump BTB entries, power of two, 0 = off
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  // Lookup: instruction presented by the prefetch buffer
  input  logic [31:0]  fetch_rdata_i,
  input  logic [31:0]  fetch_pc_i,
  input  logic         fetch_valid_i,

  output logic         predict_branch_taken_o,
  output logic [31:0]  predict_branch_pc_o,
  output bp_meta_t     predict_meta_o,

  // Instruction entering ID (RAS update; never a wrong-path instruction)
  input  logic         id_entry_valid_i,
  input  logic [31:0]  id_entry_rdata_i,
  input  logic [31:0]  id_entry_pc_i,

  // Training from ID/EX
  input  bp_cond_upd_t cond_upd_i,  // conditional branch resolved
  input  bp_jump_upd_t jump_upd_i   // JAL/JALR executed (BTB update)
);
  import ibex_pkg::*;

  localparam int unsigned IdxW   = (PhtEntries > 1) ? $clog2(PhtEntries) : 1;
  localparam bit          UseGhr = (Mode == BpGshare) || (Mode == BpTournament);
  localparam int unsigned GhrW   = (GhrBits > 0) ? GhrBits : 1;
  localparam bit          RasEn  = RasDepth > 0;
  localparam bit          BtbEn  = BtbEntries > 0;

  ////////////////////////
  // Instruction decode //
  ////////////////////////

  logic [31:0] instr;
  logic [31:0] imm_j_type, imm_b_type, imm_cj_type, imm_cb_type;
  logic [31:0] branch_imm;
  logic        instr_j, instr_b, instr_cj, instr_cb, instr_jalr, instr_cjr;
  logic [4:0]  jalr_rd, jalr_rs1;
  logic        jalr_is_ret;

  assign instr = fetch_rdata_i;

  assign imm_j_type  = { {12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0 };
  assign imm_b_type  = { {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0 };
  assign imm_cj_type = { {20{instr[12]}}, instr[12], instr[8], instr[10:9], instr[6], instr[7],
                         instr[2], instr[11], instr[5:3], 1'b0 };
  assign imm_cb_type = { {23{instr[12]}}, instr[12], instr[6:5], instr[2], instr[11:10],
                         instr[4:3], 1'b0 };

  assign instr_b    = opcode_e'(instr[6:0]) == OPCODE_BRANCH;
  assign instr_j    = opcode_e'(instr[6:0]) == OPCODE_JAL;
  assign instr_jalr = (opcode_e'(instr[6:0]) == OPCODE_JALR) & (instr[14:12] == 3'b000);
  // C.BEQZ / C.BNEZ
  assign instr_cb   = (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b110) | (instr[15:13] == 3'b111));
  // C.J / C.JAL
  assign instr_cj   = (instr[1:0] == 2'b01) & ((instr[15:13] == 3'b101) | (instr[15:13] == 3'b001));
  // C.JR / C.JALR: funct4 100x, rs2 = 0, rs1 != 0
  assign instr_cjr  = (instr[1:0] == 2'b10) & (instr[15:13] == 3'b100) & (instr[6:2] == 5'd0) &
                      (instr[11:7] != 5'd0);

  // Register fields of a register-indirect jump (C.JR: rd = x0, C.JALR: rd = x1)
  assign jalr_rd  = instr_cjr ? (instr[12] ? 5'd1 : 5'd0) : instr[11:7];
  assign jalr_rs1 = instr_cjr ? instr[11:7] : instr[19:15];

  // RISC-V return-address-stack hints: a JALR whose rs1 is a link register (x1/x5) is a return,
  // unless rd is the same link register (then it is a call through that register).
  function automatic logic is_link(logic [4:0] r);
    return (r == 5'd1) || (r == 5'd5);
  endfunction

  assign jalr_is_ret = is_link(jalr_rs1) & ~(is_link(jalr_rd) & (jalr_rd == jalr_rs1));

  always_comb begin
    branch_imm = imm_b_type;
    unique case (1'b1)
      instr_j  : branch_imm = imm_j_type;
      instr_b  : branch_imm = imm_b_type;
      instr_cj : branch_imm = imm_cj_type;
      instr_cb : branch_imm = imm_cb_type;
      default  : ;
    endcase
  end

  ///////////////////////////////////
  // Conditional branch direction  //
  ///////////////////////////////////

  logic            cond_predict_taken;
  logic [IdxW-1:0] pc_idx, gsh_idx;
  logic [GhrW-1:0] ghr_q;

  // Compressed instructions are halfword aligned, so indices start at PC bit 1.
  assign pc_idx = fetch_pc_i[IdxW:1];

  if (UseGhr) begin : g_ghr
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        ghr_q <= '0;
      end else if (cond_upd_i.valid) begin
        ghr_q <= (ghr_q << 1) | GhrW'(cond_upd_i.taken);
      end
    end
    // gshare index: fold the (zero-extended) history onto the low PC bits
    assign gsh_idx = pc_idx ^ IdxW'(ghr_q);
  end else begin : g_no_ghr
    assign ghr_q   = '0;
    assign gsh_idx = pc_idx;
  end

  // Saturating 2-bit counter update
  function automatic logic [1:0] sat_update(logic [1:0] cnt, logic taken);
    if (taken) return (cnt == CNT_STRONG_T)  ? cnt : cnt + 2'd1;
    else       return (cnt == CNT_STRONG_NT) ? cnt : cnt - 2'd1;
  endfunction

  logic [IdxW-1:0] upd_idx, upd_idx_bim;
  assign upd_idx     = cond_upd_i.meta.idx[IdxW-1:0];
  assign upd_idx_bim = cond_upd_i.meta.idx_bim[IdxW-1:0];

  if (Mode == BpStatic || Mode == BpNone) begin : g_dir_static
    // BTFN: a negative offset means a backward branch, which is most likely a loop back-edge
    assign cond_predict_taken  = branch_imm[31];
    assign predict_meta_o.idx      = '0;
    assign predict_meta_o.idx_bim  = '0;
    assign predict_meta_o.pred_bim = 1'b0;
    assign predict_meta_o.pred_gsh = 1'b0;

  end else if (Mode == BpTournament) begin : g_dir_tournament
    logic [PhtEntries-1:0][1:0] pht_gsh_q, pht_bim_q, chooser_q;
    logic                       pred_bim, pred_gsh, use_gsh;

    assign pred_bim = pht_bim_q[pc_idx][1];
    assign pred_gsh = pht_gsh_q[gsh_idx][1];
    assign use_gsh  = chooser_q[pc_idx][1];

    assign cond_predict_taken      = use_gsh ? pred_gsh : pred_bim;
    assign predict_meta_o.idx      = BP_IDX_W'(gsh_idx);
    assign predict_meta_o.idx_bim  = BP_IDX_W'(pc_idx);
    assign predict_meta_o.pred_bim = pred_bim;
    assign predict_meta_o.pred_gsh = pred_gsh;

    // Both components always learn; the chooser moves towards the component that was right when
    // they disagreed (reset: weakly prefer bimodal, which trains faster).
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pht_gsh_q <= {PhtEntries{CNT_WEAK_NT}};
        pht_bim_q <= {PhtEntries{CNT_WEAK_NT}};
        chooser_q <= {PhtEntries{CNT_WEAK_NT}};
      end else if (cond_upd_i.valid) begin
        pht_gsh_q[upd_idx]     <= sat_update(pht_gsh_q[upd_idx],     cond_upd_i.taken);
        pht_bim_q[upd_idx_bim] <= sat_update(pht_bim_q[upd_idx_bim], cond_upd_i.taken);
        if (cond_upd_i.meta.pred_bim != cond_upd_i.meta.pred_gsh) begin
          chooser_q[upd_idx_bim] <= sat_update(chooser_q[upd_idx_bim],
                                               cond_upd_i.meta.pred_gsh == cond_upd_i.taken);
        end
      end
    end

  end else begin : g_dir_table
    // One table: 1-bit (BpOneBit), bimodal (PC index) or gshare (PC xor GHR index)
    logic [PhtEntries-1:0][1:0] pht_q;
    logic [IdxW-1:0]            lookup_idx;

    assign lookup_idx = (Mode == BpGshare) ? gsh_idx : pc_idx;

    assign cond_predict_taken      = pht_q[lookup_idx][1];
    assign predict_meta_o.idx      = BP_IDX_W'(lookup_idx);
    assign predict_meta_o.idx_bim  = '0;
    assign predict_meta_o.pred_bim = 1'b0;
    assign predict_meta_o.pred_gsh = 1'b0;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pht_q <= {PhtEntries{CNT_WEAK_NT}};
      end else if (cond_upd_i.valid) begin
        if (Mode == BpOneBit) begin
          // 1-bit predictor: remember the last outcome (stored as a strong counter state)
          pht_q[upd_idx] <= {2{cond_upd_i.taken}};
        end else begin
          pht_q[upd_idx] <= sat_update(pht_q[upd_idx], cond_upd_i.taken);
        end
      end
    end

`ifndef SYNTHESIS
    // Counter update rule: one cycle after an update the trained entry holds exactly the expected
    // value (saturating increment/decrement, or the outcome for the 1-bit predictor).
    logic            chk_valid_q, chk_taken_q;
    logic [IdxW-1:0] chk_idx_q;
    logic [1:0]      chk_old_q, chk_expected;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) chk_valid_q <= 1'b0;
      else         chk_valid_q <= cond_upd_i.valid;
    end
    always_ff @(posedge clk_i) begin
      chk_taken_q <= cond_upd_i.taken;
      chk_idx_q   <= upd_idx;
      chk_old_q   <= pht_q[upd_idx];
    end
    assign chk_expected = (Mode == BpOneBit) ? {2{chk_taken_q}} : sat_update(chk_old_q, chk_taken_q);

    `UARCH_ASSERT(BpCounterUpdateRule, chk_valid_q |-> (pht_q[chk_idx_q] == chk_expected))
`endif
  end

  ///////////////////////////////
  // Return address stack      //
  ///////////////////////////////

  logic        ras_valid;
  logic [31:0] ras_top;

  // Call/return classification of the instruction entering ID (RISC-V link-register hints)
  logic [31:0] ent;
  logic        ent_jal, ent_cjal, ent_jalr, ent_cjr, ent_rvc;
  logic [4:0]  ent_rd, ent_rs1;
  logic        ent_push, ent_pop, ras_push, ras_pop;
  logic [31:0] ras_link;

  assign ent      = id_entry_rdata_i;
  assign ent_rvc  = ent[1:0] != 2'b11;
  assign ent_jal  = opcode_e'(ent[6:0]) == OPCODE_JAL;
  assign ent_cjal = (ent[1:0] == 2'b01) & ((ent[15:13] == 3'b001) | (ent[15:13] == 3'b101));
  assign ent_jalr = (opcode_e'(ent[6:0]) == OPCODE_JALR) & (ent[14:12] == 3'b000);
  assign ent_cjr  = (ent[1:0] == 2'b10) & (ent[15:13] == 3'b100) & (ent[6:2] == 5'd0) &
                    (ent[11:7] != 5'd0);
  // C.JAL links to x1, C.J to x0; C.JALR links to x1, C.JR to x0
  assign ent_rd   = ent_cjal ? ((ent[15:13] == 3'b001) ? 5'd1 : 5'd0) :
                    ent_cjr  ? (ent[12] ? 5'd1 : 5'd0) : ent[11:7];
  assign ent_rs1  = ent_cjr ? ent[11:7] : ent[19:15];
  assign ent_push = (ent_jal | ent_cjal | ent_jalr | ent_cjr) & is_link(ent_rd);
  assign ent_pop  = (ent_jalr | ent_cjr) & is_link(ent_rs1) & ~(is_link(ent_rd) & (ent_rd == ent_rs1));
  assign ras_push = id_entry_valid_i & ent_push;
  assign ras_pop  = id_entry_valid_i & ent_pop;
  assign ras_link = id_entry_pc_i + (ent_rvc ? 32'd2 : 32'd4);

  if (RasEn) begin : g_ras
    localparam int unsigned PtrW = (RasDepth > 1) ? $clog2(RasDepth) : 1;
    localparam int unsigned CntW = $clog2(RasDepth + 1);

    logic [31:0]     ras_q [RasDepth];
    logic [PtrW-1:0] tos_q;   // index of the top entry (circular, overflow drops the oldest)
    logic [CntW-1:0] cnt_q;   // valid entries, saturates at RasDepth

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        tos_q <= '0;
        cnt_q <= '0;
      end else begin
        unique case ({ras_pop, ras_push})
          2'b01: begin  // call
            tos_q <= tos_q + PtrW'(1);
            if (cnt_q != CntW'(RasDepth)) cnt_q <= cnt_q + CntW'(1);
          end
          2'b10: begin  // return
            if (cnt_q != '0) begin
              tos_q <= tos_q - PtrW'(1);
              cnt_q <= cnt_q - CntW'(1);
            end
          end
          2'b11: begin  // co-routine swap: pop then push = replace the top
            if (cnt_q == '0) cnt_q <= CntW'(1);
          end
          default: ;
        endcase
      end
    end

    always_ff @(posedge clk_i) begin
      if (ras_push) begin
        if (ras_pop) ras_q[tos_q]            <= ras_link;
        else         ras_q[tos_q + PtrW'(1)] <= ras_link;
      end
    end

    assign ras_valid = cnt_q != '0;
    assign ras_top   = ras_q[tos_q];

`ifndef SYNTHESIS
    // After a call the top of the stack holds its return address
    logic        chk_push_q;
    logic [31:0] chk_link_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) chk_push_q <= 1'b0;
      else         chk_push_q <= ras_push;
    end
    always_ff @(posedge clk_i) chk_link_q <= ras_link;
    `UARCH_ASSERT(RasTopAfterPush, chk_push_q |-> (ras_valid && ras_top == chk_link_q))
    `UARCH_ASSERT(RasCountInRange, cnt_q <= CntW'(RasDepth))
`endif
  end else begin : g_no_ras
    assign ras_valid = 1'b0;
    assign ras_top   = '0;
    logic unused_ras;
    assign unused_ras = ^{ras_push, ras_pop, ras_link};
  end

  ///////////////////////////////////
  // Indirect-jump target buffer   //
  ///////////////////////////////////

  logic        btb_hit;
  logic [31:0] btb_target;

  if (BtbEn) begin : g_btb
    localparam int unsigned BIdxW = (BtbEntries > 1) ? $clog2(BtbEntries) : 1;
    localparam int unsigned BTagW = 31 - BIdxW;

    logic [BtbEntries-1:0] btb_valid_q;
    logic [BTagW-1:0]      btb_tag_q    [BtbEntries];
    logic [30:0]           btb_target_q [BtbEntries];
    logic [BIdxW-1:0]      lookup_idx, upd_idx_b;
    logic                  btb_update;

    assign lookup_idx = fetch_pc_i[BIdxW:1];
    assign upd_idx_b  = jump_upd_i.pc[BIdxW:1];
    // Returns are covered by the RAS; without a RAS they are cached here like any indirect jump.
    assign btb_update = jump_upd_i.valid &
                        (jump_upd_i.indirect | (!RasEn && jump_upd_i.pop));

    assign btb_hit    = btb_valid_q[lookup_idx] &
                        (btb_tag_q[lookup_idx] == fetch_pc_i[31:BIdxW+1]);
    assign btb_target = {btb_target_q[lookup_idx], 1'b0};

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        btb_valid_q <= '0;
      end else if (btb_update) begin
        btb_valid_q[upd_idx_b] <= 1'b1;
      end
    end

    always_ff @(posedge clk_i) begin
      if (btb_update) begin
        btb_tag_q[upd_idx_b]    <= jump_upd_i.pc[31:BIdxW+1];
        btb_target_q[upd_idx_b] <= jump_upd_i.target[31:1];
      end
    end
  end else begin : g_no_btb
    assign btb_hit    = 1'b0;
    assign btb_target = '0;
  end

  ///////////////////////////
  // Prediction            //
  ///////////////////////////

  logic jalr_any, ret_pred, ind_pred;

  assign jalr_any = instr_jalr | instr_cjr;
  assign ret_pred = jalr_any & jalr_is_ret & RasEn & ras_valid;
  assign ind_pred = jalr_any & ~(jalr_is_ret & RasEn) & BtbEn & btb_hit;

  assign predict_branch_taken_o = fetch_valid_i &
      (instr_j | instr_cj | ((instr_b | instr_cb) & cond_predict_taken) | ret_pred | ind_pred);

  always_comb begin
    if (ret_pred)      predict_branch_pc_o = ras_top;
    else if (ind_pred) predict_branch_pc_o = btb_target;
    else               predict_branch_pc_o = fetch_pc_i + branch_imm;
  end

  assign predict_meta_o.src_ras = ret_pred;
  assign predict_meta_o.src_btb = ind_pred;
  assign predict_meta_o.target  = predict_branch_pc_o;

  ////////////////
  // Assertions //
  ////////////////

`ifndef SYNTHESIS
  initial begin
    if ((PhtEntries & (PhtEntries - 1)) != 0 || IdxW > BP_IDX_W) begin
      $fatal(1, "ibex_bp_dynamic: PhtEntries (%0d) must be a power of two <= 2**%0d", PhtEntries,
             BP_IDX_W);
    end
    if (UseGhr && GhrBits > IdxW) begin
      $fatal(1, "ibex_bp_dynamic: GhrBits (%0d) must not exceed log2(PhtEntries) (%0d)",
             GhrBits, IdxW);
    end
    if ((RasDepth & (RasDepth - 1)) != 0 || (BtbEntries & (BtbEntries - 1)) != 0) begin
      $fatal(1, "ibex_bp_dynamic: RasDepth / BtbEntries must be powers of two (or 0)");
    end
  end

  // Training indices must originate from a lookup of this table (compared at 32 bits: a 4096-entry
  // table fills the full index width)
  `UARCH_ASSERT(BpUpdateIdxInRange,
      cond_upd_i.valid |-> (32'(cond_upd_i.meta.idx) < PhtEntries &&
                            32'(cond_upd_i.meta.idx_bim) < PhtEntries))
  // At most one kind of control-transfer instruction is recognised at a time
  `UARCH_ASSERT(BpInstrTypeOneHot,
      fetch_valid_i |-> $onehot0({instr_j, instr_b, instr_cj, instr_cb, instr_jalr, instr_cjr}))
  // A taken prediction always has a known, halfword-aligned target
  `UARCH_ASSERT(BpTargetAligned,
      predict_branch_taken_o |-> (!$isunknown(predict_branch_pc_o) && !predict_branch_pc_o[0]))
  // A register-indirect jump is only predicted from exactly one source
  `UARCH_ASSERT(BpIndirectSingleSource, !(ret_pred && ind_pred))

  // Two independent decoders must agree: the call/return classification of the raw (possibly
  // compressed) instruction when it entered ID, and ID/EX's classification of the decompressed
  // instruction when it executes.
  logic entered_push_q, entered_pop_q;
  always_ff @(posedge clk_i) begin
    if (id_entry_valid_i) begin
      entered_push_q <= ent_push;
      entered_pop_q  <= ent_pop;
    end
  end
  `UARCH_ASSERT(CallRetDecodeConsistent,
      jump_upd_i.valid |-> (jump_upd_i.push == entered_push_q && jump_upd_i.pop == entered_pop_q))
`endif

endmodule
