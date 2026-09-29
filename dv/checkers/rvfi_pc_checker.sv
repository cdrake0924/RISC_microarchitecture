// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Architectural control-flow checker on the RISC-V Formal Interface (RVFI)
 *
 * The branch predictor steers instruction fetch speculatively; if a misprediction were not repaired
 * the core would retire a wrong-path instruction. This checker recomputes, for every retired
 * instruction, the architecturally correct next PC from the instruction encoding and its source
 * operands (rvfi_rs1/rs2_rdata) and compares it with the PC of the next retired instruction.
 * This is independent of the predictor and of rvfi_pc_wdata (which reports the fetch PC).
 *
 * Also checks that x0 is never written with a non-zero value, and classifies every retired
 * control-transfer instruction for the functional-coverage model.
 */
module rvfi_pc_checker (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        rvfi_valid,
  input  logic [31:0] rvfi_insn,
  input  logic        rvfi_trap,
  input  logic        rvfi_intr,
  input  logic [31:0] rvfi_pc_rdata,
  input  logic [31:0] rvfi_rs1_rdata,
  input  logic [31:0] rvfi_rs2_rdata,
  input  logic [4:0]  rvfi_rd_addr,
  input  logic [31:0] rvfi_rd_wdata,

  // Classification of the instruction retiring this cycle (for coverage)
  output logic        ret_cond_branch_o,
  output logic        ret_taken_o,
  output logic        ret_backward_o,
  output logic        ret_compressed_o,
  output logic        ret_jal_o,
  output logic        ret_jalr_o
);
  import tb_pkg::*;

  typedef struct packed {
    logic        known;      // next PC is determined by the instruction alone
    logic [31:0] npc;
    logic        cond;       // conditional branch
    logic        taken;
    logic        backward;
    logic        jal;        // PC-relative jump (JAL, C.J, C.JAL)
    logic        jalr;       // register-indirect jump (JALR, C.JR, C.JALR)
  } flow_t;

  function automatic flow_t decode_flow(logic [31:0] insn, logic [31:0] pc,
                                        logic [31:0] rs1, logic [31:0] rs2);
    flow_t f;
    logic [31:0] imm;
    f = '0;
    f.known = 1'b1;

    if (insn[1:0] == 2'b11) begin
      // ---- 32-bit instructions ----
      f.npc = pc + 32'd4;
      unique case (insn[6:0])
        7'b1101111: begin  // JAL
          imm   = {{12{insn[31]}}, insn[19:12], insn[20], insn[30:21], 1'b0};
          f.npc = pc + imm;
          f.jal = 1'b1;
        end
        7'b1100111: begin  // JALR
          imm    = {{20{insn[31]}}, insn[31:20]};
          f.npc  = (rs1 + imm) & ~32'd1;
          f.jalr = 1'b1;
        end
        7'b1100011: begin  // BRANCH
          imm = {{19{insn[31]}}, insn[31], insn[7], insn[30:25], insn[11:8], 1'b0};
          unique case (insn[14:12])
            3'b000:  f.taken = (rs1 == rs2);
            3'b001:  f.taken = (rs1 != rs2);
            3'b100:  f.taken = ($signed(rs1) <  $signed(rs2));
            3'b101:  f.taken = ($signed(rs1) >= $signed(rs2));
            3'b110:  f.taken = (rs1 <  rs2);
            3'b111:  f.taken = (rs1 >= rs2);
            default: f.known = 1'b0;
          endcase
          f.cond     = 1'b1;
          f.backward = imm[31];
          if (f.taken) f.npc = pc + imm;
        end
        7'b1110011: begin  // SYSTEM: ECALL/EBREAK/xRET/WFI change flow via the trap unit
          if (insn[14:12] == 3'b000) f.known = 1'b0;
        end
        default: ;
      endcase
    end else begin
      // ---- 16-bit (RVC) instructions ----
      f.npc = pc + 32'd2;
      unique case ({insn[15:13], insn[1:0]})
        5'b001_01, 5'b101_01: begin  // C.JAL, C.J
          imm   = {{20{insn[12]}}, insn[12], insn[8], insn[10:9], insn[6], insn[7], insn[2],
                   insn[11], insn[5:3], 1'b0};
          f.npc = pc + imm;
          f.jal = 1'b1;
        end
        5'b110_01, 5'b111_01: begin  // C.BEQZ, C.BNEZ
          imm        = {{23{insn[12]}}, insn[12], insn[6:5], insn[2], insn[11:10], insn[4:3], 1'b0};
          f.taken    = insn[13] ? (rs1 != 0) : (rs1 == 0);
          f.cond     = 1'b1;
          f.backward = imm[31];
          if (f.taken) f.npc = pc + imm;
        end
        5'b100_10: begin  // C.JR / C.JALR / C.EBREAK / C.MV / C.ADD
          if (insn[6:2] == 5'd0 && insn[11:7] != 5'd0) begin
            f.npc  = rs1 & ~32'd1;
            f.jalr = 1'b1;
          end else if (insn[12] && insn[6:2] == 5'd0 && insn[11:7] == 5'd0) begin
            f.known = 1'b0;  // C.EBREAK
          end
        end
        5'b101_10: f.known = 1'b0;  // Zcmp push/pop/popret (expanded into micro-ops)
        default: ;
      endcase
    end
    return f;
  endfunction

  flow_t       flow;
  logic        exp_valid_q;
  logic [31:0] exp_pc_q;
  logic [31:0] exp_from_pc_q;

  longint unsigned n_retired, n_checked;

  assign flow = decode_flow(rvfi_insn, rvfi_pc_rdata, rvfi_rs1_rdata, rvfi_rs2_rdata);

  assign ret_cond_branch_o = rvfi_valid & ~rvfi_trap & flow.cond;
  assign ret_taken_o       = flow.taken;
  assign ret_backward_o    = flow.backward;
  assign ret_compressed_o  = rvfi_insn[1:0] != 2'b11;
  assign ret_jal_o         = rvfi_valid & ~rvfi_trap & flow.jal;
  assign ret_jalr_o        = rvfi_valid & ~rvfi_trap & flow.jalr;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      exp_valid_q <= 1'b0;
      exp_pc_q    <= '0;
      n_retired   <= 0;
      n_checked   <= 0;
    end else if (rvfi_valid) begin
      n_retired <= n_retired + 1;

      // Interrupt entry legitimately breaks sequential flow
      if (exp_valid_q && !rvfi_intr) begin
        n_checked <= n_checked + 1;
        if (rvfi_pc_rdata !== exp_pc_q) begin
          tb_error("RVFI", $sformatf(
              "control-flow mismatch: instruction after pc 0x%08x retired at 0x%08x, expected 0x%08x",
              exp_from_pc_q, rvfi_pc_rdata, exp_pc_q));
        end
      end

      if (rvfi_rd_addr == 5'd0 && rvfi_rd_wdata != 32'd0) begin
        tb_error("RVFI", $sformatf("x0 written with 0x%08x at pc 0x%08x", rvfi_rd_wdata,
                                   rvfi_pc_rdata));
      end

      exp_valid_q   <= flow.known && !rvfi_trap;
      exp_pc_q      <= flow.npc;
      exp_from_pc_q <= rvfi_pc_rdata;
    end
  end

  final begin
    $display("[RVFI] retired %0d instructions, control flow checked on %0d", n_retired, n_checked);
  end

endmodule
