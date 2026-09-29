// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Next-line instruction prefetcher (one-line stream buffer)
 *
 * Sits between the L1 I-cache's memory port and main memory; both sides use the Ibex/OBI protocol.
 *
 *   trigger  when the I-cache starts a refill of line X from memory, or when a refill of line X is
 *            served from the buffer, the prefetcher fetches line X+1 into its buffer (streaming)
 *   issue    prefetch beats use the memory port only when the cache is not requesting it, so they
 *            queue behind the demand refill and arrive while the core executes line X
 *   hit      a later refill of X+1 is answered from the buffer at one word per cycle (as soon as
 *            each word has arrived) instead of paying the memory latency
 *   flush    flush_i (FENCE.I) invalidates the buffer and drops prefetch beats still in flight
 *
 * Only cacheable addresses are prefetched (never MMIO). The cache is unaware of the prefetcher;
 * responses to the cache are always returned in request order.
 */

`include "uarch_assert.svh"

module ibex_l1_prefetch import ibex_uarch_pkg::*; #(
  parameter int unsigned LineBytes     = 16,
  parameter logic [31:0] CacheableMask = 32'hF000_0000,
  parameter logic [31:0] CacheableBase = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Upstream: I-cache memory port (reads only)
  input  logic        up_req_i,
  output logic        up_gnt_o,
  input  logic [31:0] up_addr_i,
  output logic        up_rvalid_o,
  output logic [31:0] up_rdata_o,
  output logic        up_err_o,

  // Downstream: memory
  output logic        mem_req_o,
  input  logic        mem_gnt_i,
  output logic [31:0] mem_addr_o,
  input  logic        mem_rvalid_i,
  input  logic [31:0] mem_rdata_i,
  input  logic        mem_err_i,

  input  logic        flush_i,          // invalidate the buffer (FENCE.I)

  output logic        perf_pf_issue_o,  // prefetch of a line started
  output logic        perf_pf_hit_o     // refill of a line served from the buffer
);

  localparam int unsigned W     = LineBytes / 4;
  localparam int unsigned OffW  = $clog2(LineBytes);
  localparam int unsigned WordW = $clog2(W);
  localparam int unsigned LineW = 32 - OffW;
  // Queue depths are powers of two so the pointers wrap naturally
  localparam int unsigned MqD   = 2 * W;  // memory transactions in flight (demand + prefetch)
  localparam int unsigned UqD   = 2 * W;  // upstream requests awaiting a response
  localparam int unsigned MqPW  = $clog2(MqD);
  localparam int unsigned UqAW  = $clog2(UqD);  // pointer width
  localparam int unsigned UqPW  = UqAW + 1;     // counter width

  //////////////////////
  // Stream buffer    //
  //////////////////////

  logic             buf_valid_q;
  logic [LineW-1:0] buf_line_q;
  logic [31:0]      buf_data_q [W];
  logic [W-1:0]     buf_word_q;     // word has arrived
  logic             buf_err_q;      // a beat returned a bus error

  logic [WordW:0]   pf_issued_q;    // beats of the current prefetch sent to memory
  logic [WordW:0]   pf_outst_q;     // prefetch beats awaiting a memory response
  logic             pf_drop_q;      // drop in-flight prefetch beats (flushed)
  logic             pf_hold_q;      // a prefetch request is on the bus and not yet granted
  logic             pend_q;         // prefetch requested while the buffer was busy
  logic [LineW-1:0] pend_line_q;

  //////////////////////
  // Queues           //
  //////////////////////

  // Memory transactions in flight: prefetch beat (word index) or demand forward
  logic             mq_pf   [MqD];
  logic [WordW-1:0] mq_word [MqD];
  logic [MqPW-1:0]  mq_wr_q, mq_rd_q;
  logic [MqPW:0]    mq_cnt_q;

  // Upstream requests in order: served from the buffer (word index) or from memory
  logic             uq_buf  [UqD];
  logic [WordW-1:0] uq_word [UqD];
  logic [UqAW-1:0]  uq_wr_q, uq_rd_q;
  logic [UqPW-1:0]  uq_cnt_q, uq_buf_cnt_q;

  // Demand responses from memory awaiting their turn upstream
  logic [31:0]      dq_data [UqD];
  logic             dq_err  [UqD];
  logic [UqAW-1:0]  dq_wr_q, dq_rd_q;
  logic [UqPW-1:0]  dq_cnt_q;

  //////////////////////
  // Classification   //
  //////////////////////

  logic [LineW-1:0] up_line;
  logic [WordW-1:0] up_word;
  logic             up_cacheable, up_buf_hit, line_start;

  assign up_line      = up_addr_i[31:OffW];
  assign up_word      = up_addr_i[OffW-1:2];
  assign up_cacheable = (up_addr_i & CacheableMask) == CacheableBase;
  assign up_buf_hit   = buf_valid_q & ~buf_err_q & (up_line == buf_line_q);
  assign line_start   = up_cacheable & (up_word == '0);  // the cache refills from word 0

  //////////////////////
  // Memory port      //
  //////////////////////

  logic mq_full, uq_full;
  logic dem_fwd, pf_want, pf_sel;
  logic up_accept, mem_accept;

  assign mq_full = mq_cnt_q == (MqPW+1)'(MqD);
  assign uq_full = uq_cnt_q == UqPW'(UqD);

  // A demand forward has priority, except that a prefetch request already on the bus is held until
  // it is granted (request attributes must stay stable).
  assign pf_want = buf_valid_q & (pf_issued_q < (WordW+1)'(W)) & ~pf_drop_q;
  assign dem_fwd = up_req_i & ~up_buf_hit & ~uq_full & ~mq_full;
  assign pf_sel  = pf_hold_q | (pf_want & ~dem_fwd & ~mq_full);

  assign mem_req_o  = pf_sel | dem_fwd;
  assign mem_addr_o = pf_sel ? {buf_line_q, pf_issued_q[WordW-1:0], 2'b00} : up_addr_i;
  assign mem_accept = mem_req_o & mem_gnt_i;

  assign up_gnt_o  = up_req_i & ~uq_full & (up_buf_hit ? 1'b1 : (dem_fwd & ~pf_sel & mem_gnt_i));
  assign up_accept = up_gnt_o;

  //////////////////////
  // Upstream response //
  //////////////////////

  logic uq_head_buf, head_ready;
  logic [WordW-1:0] uq_head_word;

  assign uq_head_buf  = uq_buf[uq_rd_q];
  assign uq_head_word = uq_word[uq_rd_q];
  assign head_ready   = (uq_cnt_q != '0) &
                        (uq_head_buf ? (buf_word_q[uq_head_word] | buf_err_q) : (dq_cnt_q != '0));

  assign up_rvalid_o = head_ready;
  assign up_rdata_o  = uq_head_buf ? buf_data_q[uq_head_word] : dq_data[dq_rd_q];
  assign up_err_o    = head_ready & (uq_head_buf ? buf_err_q : dq_err[dq_rd_q]);

  //////////////////////
  // Prefetch start   //
  //////////////////////

  logic             trig;
  logic [LineW-1:0] trig_line;
  logic             buf_busy, start_now, start_pend;

  // Triggers: a refill starting from memory, or a refill served from the buffer (keep streaming)
  assign trig      = up_accept & line_start;
  assign trig_line = up_line + LineW'(1);
  // The buffer may be replaced only when no request of the current line is waiting for it, no
  // prefetch beat is outstanding and it is not being requested this cycle.
  assign buf_busy  = (uq_buf_cnt_q != '0) | (pf_outst_q != '0) | pf_hold_q |
                     (up_req_i & up_buf_hit) | (pf_want & pf_issued_q != '0);
  assign start_now  = trig & ~buf_busy & ~(buf_valid_q & (buf_line_q == trig_line));
  // A deferred prefetch starts only while the cache is not requesting, so a request already on
  // the bus is never re-classified by a buffer change.
  assign start_pend = pend_q & ~buf_busy & ~trig & ~up_req_i;

  //////////////////////
  // Sequential logic //
  //////////////////////

  logic mq_head_pf;
  logic [WordW-1:0] mq_head_word;
  assign mq_head_pf   = mq_pf[mq_rd_q];
  assign mq_head_word = mq_word[mq_rd_q];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buf_valid_q  <= 1'b0;
      buf_line_q   <= '0;
      buf_word_q   <= '0;
      buf_err_q    <= 1'b0;
      pf_issued_q  <= '0;
      pf_outst_q   <= '0;
      pf_drop_q    <= 1'b0;
      pf_hold_q    <= 1'b0;
      pend_q       <= 1'b0;
      pend_line_q  <= '0;
      mq_wr_q      <= '0;
      mq_rd_q      <= '0;
      mq_cnt_q     <= '0;
      uq_wr_q      <= '0;
      uq_rd_q      <= '0;
      uq_cnt_q     <= '0;
      uq_buf_cnt_q <= '0;
      dq_wr_q      <= '0;
      dq_rd_q      <= '0;
      dq_cnt_q     <= '0;
    end else begin
      // ---- memory requests ----
      pf_hold_q <= pf_sel & ~mem_gnt_i;
      if (mem_accept) begin
        mq_wr_q <= mq_wr_q + MqPW'(1);
        if (pf_sel) pf_issued_q <= pf_issued_q + (WordW+1)'(1);
      end

      // ---- memory responses ----
      if (mem_rvalid_i) begin
        mq_rd_q <= mq_rd_q + MqPW'(1);
        if (mq_head_pf) begin
          if (!pf_drop_q) begin
            buf_word_q[mq_head_word] <= 1'b1;
            if (mem_err_i) buf_err_q <= 1'b1;
          end
        end else begin
          dq_wr_q <= dq_wr_q + UqAW'(1);
        end
      end
      mq_cnt_q   <= mq_cnt_q + (MqPW+1)'(mem_accept) - (MqPW+1)'(mem_rvalid_i);
      pf_outst_q <= pf_outst_q + (WordW+1)'(mem_accept && pf_sel)
                               - (WordW+1)'(mem_rvalid_i && mq_head_pf);
      dq_cnt_q   <= dq_cnt_q + UqPW'(mem_rvalid_i && !mq_head_pf)
                             - UqPW'(up_rvalid_o && !uq_head_buf);
      if (up_rvalid_o && !uq_head_buf) dq_rd_q <= dq_rd_q + UqAW'(1);

      // ---- upstream queue ----
      if (up_accept) uq_wr_q <= uq_wr_q + UqAW'(1);
      if (up_rvalid_o) uq_rd_q <= uq_rd_q + UqAW'(1);
      uq_cnt_q     <= uq_cnt_q + UqPW'(up_accept) - UqPW'(up_rvalid_o);
      uq_buf_cnt_q <= uq_buf_cnt_q + UqPW'(up_accept && up_buf_hit)
                                   - UqPW'(up_rvalid_o && uq_head_buf);

      // ---- drop in-flight prefetch beats after a flush ----
      if (pf_drop_q && pf_outst_q == '0 && !pf_hold_q) pf_drop_q <= 1'b0;

      // ---- start a prefetch (or remember that one is wanted) ----
      if (flush_i) begin
        // Invalidate; a prefetch request still waiting for its grant stays on the bus unchanged
        // (OBI) and, like every beat in flight, has its response dropped.
        buf_valid_q <= 1'b0;
        pend_q      <= 1'b0;
        if (pf_outst_q != '0 || pf_hold_q || (mem_accept && pf_sel)) pf_drop_q <= 1'b1;
      end else if (start_now || start_pend) begin
        buf_valid_q <= 1'b1;
        buf_line_q  <= start_now ? trig_line : pend_line_q;
        buf_word_q  <= '0;
        buf_err_q   <= 1'b0;
        pf_issued_q <= '0;
        pend_q      <= 1'b0;
      end else if (trig && !(buf_valid_q && buf_line_q == trig_line)) begin
        pend_q      <= 1'b1;
        pend_line_q <= trig_line;
      end
    end
  end

  // Queue payloads (no reset needed: qualified by the counters)
  always_ff @(posedge clk_i) begin
    if (mem_accept) begin
      mq_pf[mq_wr_q]   <= pf_sel;
      mq_word[mq_wr_q] <= pf_issued_q[WordW-1:0];
    end
    if (mem_rvalid_i && mq_head_pf && !pf_drop_q) begin
      buf_data_q[mq_head_word] <= mem_rdata_i;
    end
    if (mem_rvalid_i && !mq_head_pf) begin
      dq_data[dq_wr_q] <= mem_rdata_i;
      dq_err[dq_wr_q]  <= mem_err_i;
    end
    if (up_accept) begin
      uq_buf[uq_wr_q]  <= up_buf_hit;
      uq_word[uq_wr_q] <= up_word;
    end
  end

  assign perf_pf_issue_o = ~flush_i & (start_now | start_pend);
  assign perf_pf_hit_o   = up_accept & up_buf_hit & line_start;

  ////////////////
  // Assertions //
  ////////////////

`ifndef SYNTHESIS
  initial begin
    if ((LineBytes & (LineBytes - 1)) != 0 || LineBytes < 8) begin
      $fatal(1, "ibex_l1_prefetch: LineBytes (%0d) must be a power of two >= 8", LineBytes);
    end
  end

  `UARCH_ASSERT(PfMemReqStable, mem_req_o && !mem_gnt_i |=> mem_req_o && $stable(mem_addr_o))
  `UARCH_ASSERT(PfMemRvalidExpected, mem_rvalid_i |-> mq_cnt_q != '0)
  `UARCH_ASSERT(PfUpRvalidExpected, up_rvalid_o |-> uq_cnt_q != '0)
  // The buffer is never replaced or flushed while a request is waiting for one of its words
  `UARCH_ASSERT(PfNoFlushWithPendingReads, flush_i |-> uq_buf_cnt_q == '0)
  `UARCH_ASSERT(PfPrefetchAddrCacheable,
      mem_req_o && pf_sel |-> (({buf_line_q, {OffW{1'b0}}} & CacheableMask) == CacheableBase))

  `UARCH_COVER(CovPfHit, perf_pf_hit_o)
  `UARCH_COVER(CovPfHitWhileFilling, up_accept && up_buf_hit && !buf_word_q[up_word])
  `UARCH_COVER(CovPfDropAfterFlush, mem_rvalid_i && mq_head_pf && pf_drop_q)
  `UARCH_COVER(CovPfDemandOvertakesPrefetch, dem_fwd && pf_want && !pf_hold_q)
`endif

endmodule
