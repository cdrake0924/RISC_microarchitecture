// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Pipeline redirect ("flush") checker
 *
 * Micro-architectural companion to rvfi_pc_checker. Every time ID/EX redirects fetch, the next
 * instruction that enters ID must be the one at the redirect address, i.e. the flush removed every
 * wrong-path instruction and the refetch started at the right place:
 *
 *   nt_branch_mispredict   a branch predicted taken was not taken   -> next PC = PC + 2/4
 *   pc_set with PC_JUMP    an unpredicted taken branch/jump, or a
 *                          JALR predicted to the wrong target       -> next PC = computed target
 *
 * Redirects to trap handlers (PC_EXC/ERET/DRET/BOOT) cancel the check. Ibex never lets a wrong-path
 * instruction enter ID (the IF/ID register is not written in a redirect cycle), so the property is
 * exact, and it is checked one stage earlier than the RVFI retirement check.
 */
module redirect_checker (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              pc_set_i,
  input  ibex_pkg::pc_sel_e pc_mux_i,
  input  logic [31:0]       branch_target_ex_i,
  input  logic              nt_mispredict_i,
  input  logic [31:0]       nt_addr_i,
  input  logic              jump_mispredict_i,   // predicted JALR target was wrong
  input  logic              instr_new_id_i,
  input  logic [31:0]       pc_id_i,

  output logic              cov_nt_recover_o,    // coverage: recovery after a wrong "taken"
  output logic              cov_target_recover_o // coverage: recovery after a wrong JALR target
);
  import tb_pkg::*;

  logic        pending_q, pending_jalr_q, pending_nt_q;
  logic [31:0] expect_q;
  longint unsigned n_checked;

  assign cov_nt_recover_o     = instr_new_id_i & pending_q & pending_nt_q;
  assign cov_target_recover_o = instr_new_id_i & pending_q & pending_jalr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q      <= 1'b0;
      pending_nt_q   <= 1'b0;
      pending_jalr_q <= 1'b0;
      expect_q       <= '0;
      n_checked      <= 0;
    end else begin
      if (instr_new_id_i && pending_q) begin
        n_checked <= n_checked + 1;
        if (pc_id_i !== expect_q) begin
          tb_error("REDIRECT", $sformatf(
              "after a %s the next instruction in ID is at 0x%08x, expected 0x%08x",
              str_sel(pending_nt_q, "not-taken mispredict",
                      str_sel(pending_jalr_q, "JALR target mispredict", "branch/jump redirect")),
              pc_id_i, expect_q));
        end
        pending_q <= 1'b0;
      end

      if (nt_mispredict_i) begin
        pending_q      <= 1'b1;
        pending_nt_q   <= 1'b1;
        pending_jalr_q <= 1'b0;
        expect_q       <= nt_addr_i;
      end else if (pc_set_i) begin
        if (pc_mux_i == ibex_pkg::PC_JUMP) begin
          pending_q      <= 1'b1;
          pending_nt_q   <= 1'b0;
          pending_jalr_q <= jump_mispredict_i;
          expect_q       <= {branch_target_ex_i[31:1], 1'b0};
        end else begin
          pending_q <= 1'b0;  // trap entry / return: not a branch redirect
        end
      end
    end
  end

  final begin
    $display("[REDIRECT] %0d pipeline redirects checked", n_checked);
  end

endmodule
