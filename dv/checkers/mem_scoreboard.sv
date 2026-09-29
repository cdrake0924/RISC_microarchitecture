// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * End-to-end memory scoreboard for the L1 caches
 *
 * Caches must be architecturally invisible. This scoreboard observes the *core-side* instruction
 * and data interfaces (between ibex_top and the L1 caches) and checks every response against a flat
 * reference memory that is updated by every store the core issues:
 *
 *   data port    every load from RAM must return the most recently stored bytes (masked by BE)
 *   instr port   every fetch from RAM must return the reference word, except for words written
 *                since the last completed FENCE.I (RISC-V allows stale instruction fetch until the
 *                program executes FENCE.I; the snapshot is taken when the fetch is granted)
 *
 * Because the reference model knows nothing about lines, sets, dirtiness or replacement, any
 * refill/eviction/write-back bug in the caches surfaces as a data mismatch.
 */
module mem_scoreboard #(
  parameter int unsigned RamAddrWidth = 20
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Core-side instruction interface
  input  logic        instr_req_i,
  input  logic        instr_gnt_i,
  input  logic [31:0] instr_addr_i,
  input  logic        instr_rvalid_i,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_err_i,

  // Core-side data interface
  input  logic        data_req_i,
  input  logic        data_gnt_i,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_addr_i,
  input  logic [31:0] data_wdata_i,
  input  logic        data_rvalid_i,
  input  logic [31:0] data_rdata_i,
  input  logic        data_err_i,

  // FENCE.I sequence completed: modified code is now visible to instruction fetch
  input  logic        fence_done_i
);
  import tb_pkg::*;

  localparam int unsigned RamBytes = 2 ** RamAddrWidth;

  logic [7:0] ref_mem [RamBytes];  // loaded by tb_top with the same image as tb_mem

  typedef struct {
    logic [31:0] addr;
    logic        we;
    logic [3:0]  be;
  } d_txn_t;

  typedef struct {
    logic [31:0] addr;
    logic        stale_ok;  // word modified since the last FENCE.I when the fetch was granted
  } i_txn_t;

  d_txn_t d_q[$];
  i_txn_t i_q[$];
  bit     modified[logic [31:0]];  // word addresses written since the last FENCE.I

  longint unsigned n_loads, n_stores, n_fetches, n_fetch_skipped;

  function automatic bit in_ram(logic [31:0] a);
    return a < RamBytes;
  endfunction

  function automatic logic [31:0] ref_word(logic [31:0] addr);
    logic [31:0] a;
    a = {addr[31:2], 2'b00};
    return {ref_mem[a+3], ref_mem[a+2], ref_mem[a+1], ref_mem[a]};
  endfunction

  function automatic logic [31:0] be_mask(logic [3:0] be);
    return {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      d_q.delete();
      i_q.delete();
      n_loads         <= 0;
      n_stores        <= 0;
      n_fetches       <= 0;
      n_fetch_skipped <= 0;
    end else begin
      if (fence_done_i) modified.delete();

      // ---- data side (processed first, like the memory model) ----
      if (data_req_i && data_gnt_i) begin
        d_txn_t t;
        t.addr = data_addr_i;
        t.we   = data_we_i;
        t.be   = data_be_i;
        d_q.push_back(t);
        if (data_we_i && in_ram(data_addr_i)) begin
          logic [31:0] a;
          a = {data_addr_i[31:2], 2'b00};
          for (int b = 0; b < 4; b++) begin
            if (data_be_i[b]) ref_mem[a+b] = data_wdata_i[8*b +: 8];
          end
          modified[a] = 1'b1;
        end
      end

      if (data_rvalid_i) begin
        if (d_q.size() == 0) begin
          tb_error("MEM_SB", "data response without an outstanding request");
        end else begin
          d_txn_t t;
          t = d_q.pop_front();
          if (t.we) begin
            n_stores <= n_stores + 1;
          end else if (in_ram(t.addr) && !data_err_i) begin
            logic [31:0] exp, mask;
            exp  = ref_word(t.addr);
            mask = be_mask(t.be);
            n_loads <= n_loads + 1;
            if ((data_rdata_i & mask) !== (exp & mask)) begin
              tb_error("MEM_SB", $sformatf(
                  "load 0x%08x be=%b returned 0x%08x, expected 0x%08x",
                  t.addr, t.be, data_rdata_i & mask, exp & mask));
            end
          end
        end
      end

      // ---- instruction side ----
      if (instr_req_i && instr_gnt_i) begin
        i_txn_t t;
        t.addr     = instr_addr_i;
        t.stale_ok = modified.exists({instr_addr_i[31:2], 2'b00});
        i_q.push_back(t);
      end

      if (instr_rvalid_i) begin
        if (i_q.size() == 0) begin
          tb_error("MEM_SB", "instruction response without an outstanding request");
        end else begin
          i_txn_t t;
          t = i_q.pop_front();
          if (t.stale_ok) begin
            n_fetch_skipped <= n_fetch_skipped + 1;
          end else if (in_ram(t.addr) && !instr_err_i) begin
            n_fetches <= n_fetches + 1;
            if (instr_rdata_i !== ref_word(t.addr)) begin
              tb_error("MEM_SB", $sformatf("fetch 0x%08x returned 0x%08x, expected 0x%08x",
                                           t.addr, instr_rdata_i, ref_word(t.addr)));
            end
          end
        end
      end
    end
  end

  final begin
    $display("[MEM_SB] checked %0d loads, %0d stores, %0d fetches (%0d fetches of modified code skipped)",
             n_loads, n_stores, n_fetches, n_fetch_skipped);
    if (d_q.size() != 0 || i_q.size() != 0) begin
      $display("[MEM_SB] note: %0d data / %0d instruction requests outstanding at end of test",
               d_q.size(), i_q.size());
    end
  end

endmodule
