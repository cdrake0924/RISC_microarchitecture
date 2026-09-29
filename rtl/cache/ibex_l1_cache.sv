// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Parameterised L1 cache for Ibex
 *
 * A blocking, set-associative cache that sits between an Ibex memory port (instruction or data) and
 * the next level of memory. Both sides use the Ibex/OBI request-grant / response-valid protocol, so
 * the cache can be inserted without modifying the core's fetch or load/store units.
 *
 *   Organisation   NumSets x NumWays lines of LineBytes each, physically indexed/tagged
 *   Hit latency    1 cycle (request granted in cycle N, response in cycle N+1); a new request can be
 *                  granted in the same cycle a hit responds, giving one access per cycle
 *   Write policy   write-back + write-allocate (default), or write-through + no-write-allocate
 *                  (WriteThrough = 1: stores update a hitting line and are always sent to memory);
 *                  no stores at all for ReadOnly = 1
 *   Replacement    ibex_l1_repl (PLRU / FIFO / random), invalid ways filled first
 *   Miss handling  optional dirty-victim eviction (LineWords pipelined writes), then line refill
 *                  (LineWords pipelined reads); the missing request is then replayed as a hit
 *   Uncached       addresses outside (CacheableMask, CacheableBase) bypass the arrays (MMIO)
 *   Maintenance    maint_req_i / maint_done_o handshake:
 *                    ReadOnly = 1 : invalidate every line (1 cycle)
 *                    ReadOnly = 0 : clean every dirty line (write back, keep valid)
 *                  used by ibex_cc_top to implement FENCE.I coherence between the I- and D-cache
 *
 * Pipeline
 *   IDLE : cycle N   core_req & core_gnt -> request captured in req_*_q
 *          cycle N+1 tag compare against req_*_q
 *                    hit  -> core_rvalid (store hits write the line and set dirty)
 *                    miss -> EVICT (dirty victim) -> REFILL -> IDLE (replay hits)
 *
 * Storage is modelled as flop arrays with asynchronous read; an SRAM implementation would read the
 * arrays with the incoming (not registered) index in cycle N, giving the same timing.
 */

`include "uarch_assert.svh"

module ibex_l1_cache import ibex_uarch_pkg::*; #(
  parameter int unsigned  NumSets       = 64,
  parameter int unsigned  NumWays       = 2,
  parameter int unsigned  LineBytes     = 16,
  parameter bit           ReadOnly      = 1'b0,
  parameter bit           WriteThrough  = 1'b0,
  parameter repl_policy_e ReplPolicy    = ReplPlru,
  parameter logic [31:0]  CacheableMask = 32'hF000_0000,
  parameter logic [31:0]  CacheableBase = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Core side (Ibex instruction or data interface)
  input  logic        core_req_i,
  output logic        core_gnt_o,
  input  logic [31:0] core_addr_i,
  input  logic        core_we_i,
  input  logic [3:0]  core_be_i,
  input  logic [31:0] core_wdata_i,
  output logic        core_rvalid_o,
  output logic [31:0] core_rdata_o,
  output logic        core_err_o,

  // Memory side
  output logic        mem_req_o,
  input  logic        mem_gnt_i,
  output logic [31:0] mem_addr_o,
  output logic        mem_we_o,
  output logic [3:0]  mem_be_o,
  output logic [31:0] mem_wdata_o,
  input  logic        mem_rvalid_i,
  input  logic [31:0] mem_rdata_i,
  input  logic        mem_err_i,

  // Control
  input  logic        hold_i,         // do not accept new core requests (FENCE.I in progress)
  input  logic        maint_req_i,    // level: clean (RW) / invalidate (RO) the whole cache
  output logic        maint_done_o,   // pulse in the last cycle of the maintenance operation

  // Performance events (single-cycle pulses)
  output logic        perf_access_o,     // cacheable lookup (first lookup of each request)
  output logic        perf_miss_o,       // ... that missed
  output logic        perf_writeback_o,  // dirty line written back
  output logic        perf_bypass_o      // uncached access forwarded to memory
);

  ////////////////
  // Parameters //
  ////////////////

  localparam int unsigned LineWords = LineBytes / 4;
  localparam int unsigned OffW      = $clog2(LineBytes);       // byte offset within a line
  localparam int unsigned WordW     = $clog2(LineWords);       // word offset within a line
  localparam int unsigned SetW      = $clog2(NumSets);
  localparam int unsigned TagW      = 32 - OffW - SetW;
  localparam int unsigned WayW      = (NumWays > 1) ? $clog2(NumWays) : 1;
  localparam int unsigned BeatW     = WordW + 1;               // counts 0..LineWords

  typedef enum logic [2:0] {
    S_IDLE,      // lookup and hit response
    S_EVICT,     // write back a dirty line (miss victim or maintenance walk)
    S_REFILL,    // read a line from memory into the victim way
    S_BYPASS,    // single uncached access
    S_ERR_RESP,  // report a refill bus error to the core
    S_MAINT      // walk all lines for a clean operation
  } state_e;

  //////////////
  // Storage  //
  //////////////

  logic [TagW-1:0]    tag_q   [NumSets][NumWays];
  logic [31:0]        data_q  [NumSets][NumWays][LineWords];
  logic [NumSets-1:0][NumWays-1:0] valid_q;   // packed: resettable/invalidatable in one cycle
  logic [NumSets-1:0][NumWays-1:0] dirty_q;

  /////////////////////////
  // Registered request  //
  /////////////////////////

  logic        req_valid_q;
  logic [31:0] req_addr_q;
  logic        req_we_q;
  logic [3:0]  req_be_q;
  logic [31:0] req_wdata_q;
  logic        req_missed_q;   // lookup already missed once (replay after refill)

  logic [TagW-1:0]  req_tag;
  logic [SetW-1:0]  req_set;
  logic [WordW-1:0] req_word;
  logic             req_cacheable;

  assign req_tag  = req_addr_q[31 -: TagW];
  assign req_set  = req_addr_q[OffW +: SetW];
  assign req_word = req_addr_q[2 +: WordW];
  // A read-only cache never allocates on a store; route any store around the arrays.
  assign req_cacheable = ((req_addr_q & CacheableMask) == CacheableBase) & ~(ReadOnly & req_we_q);

  // Write-through: every cacheable store is written to memory (through the BYPASS path) after
  // updating the line if it hits; misses do not allocate.
  logic wt_store;
  assign wt_store = WriteThrough & ~ReadOnly & req_valid_q & req_we_q & req_cacheable;

  //////////////
  // FSM regs //
  //////////////

  state_e           state_q, state_d;
  logic [WayW-1:0]  victim_way_q, victim_way_d;
  logic [BeatW-1:0] beat_req_q, beat_rsp_q;    // memory beats granted / responded
  logic             refill_err_q;
  logic             bypass_gnt_q;              // uncached request accepted by memory

  // Line being written back (miss victim or maintenance cursor)
  logic [TagW-1:0]  evict_tag_q,  evict_tag_d;
  logic [SetW-1:0]  evict_set_q,  evict_set_d;
  logic [WayW-1:0]  evict_way_q,  evict_way_d;
  logic             evict_to_maint_q, evict_to_maint_d;  // return to S_MAINT (else S_REFILL)

  // Maintenance walk cursor
  logic [SetW-1:0]  maint_set_q;
  logic [WayW-1:0]  maint_way_q;

  ////////////
  // Lookup //
  ////////////

  logic [NumWays-1:0] way_hit;
  logic               lookup;       // a cacheable request is being looked up this cycle
  logic               hit;
  logic [WayW-1:0]    hit_way;

  always_comb begin
    for (int unsigned w = 0; w < NumWays; w++) begin
      way_hit[w] = valid_q[req_set][w] & (tag_q[req_set][w] == req_tag);
    end
  end

  always_comb begin
    hit_way = '0;
    for (int unsigned w = 0; w < NumWays; w++) begin
      if (way_hit[w]) begin
        hit_way = WayW'(w);
      end
    end
  end

  assign lookup = (state_q == S_IDLE) & req_valid_q & req_cacheable;
  assign hit    = lookup & (|way_hit);

  /////////////////
  // Replacement //
  /////////////////

  logic [WayW-1:0] repl_victim;
  logic            fill_done;   // refill completed without error

  ibex_l1_repl #(
    .NumSets(NumSets),
    .NumWays(NumWays),
    .Policy (ReplPolicy)
  ) u_repl (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .set_i     (req_set),
    .valid_i   (valid_q[req_set]),
    .victim_o  (repl_victim),
    .hit_i     (hit),
    .hit_way_i (hit_way),
    .fill_i    (fill_done),
    .fill_way_i(victim_way_q)
  );

  ///////////////////////
  // Control / datapath //
  ///////////////////////

  logic resp_now;       // lookup completes the request in this cycle
  logic new_req;        // accept a core request this cycle
  logic req_done;       // current request responds this cycle
  logic maint_start;
  logic inval_all;      // ReadOnly maintenance: clear every valid bit
  logic store_hit;
  logic refill_beat;    // refill response written into the arrays
  logic refill_last;
  logic evict_last;
  logic maint_line_dirty;
  logic maint_last;

  assign maint_line_dirty = valid_q[maint_set_q][maint_way_q] & dirty_q[maint_set_q][maint_way_q];
  assign maint_last       = (maint_set_q == SetW'(NumSets - 1)) &
                            (maint_way_q == WayW'(NumWays - 1));

  // Maintenance only starts between requests, so it never interrupts a transaction.
  assign maint_start = (state_q == S_IDLE) & maint_req_i & ~req_valid_q;
  assign inval_all   = maint_start & ReadOnly;

  assign store_hit   = hit & req_we_q;
  assign resp_now    = hit & ~wt_store;
  assign refill_beat = (state_q == S_REFILL) & mem_rvalid_i;
  assign refill_last = refill_beat & (beat_rsp_q == BeatW'(LineWords - 1));
  assign evict_last  = (state_q == S_EVICT) & mem_rvalid_i &
                       (beat_rsp_q == BeatW'(LineWords - 1));
  assign fill_done   = refill_last & ~refill_err_q & ~mem_err_i;

  // A hit frees the request register, so the next request can be granted in the same cycle.
  assign core_gnt_o = core_req_i & ~hold_i & ~maint_req_i & (state_q == S_IDLE) &
                      (~req_valid_q | resp_now);
  assign new_req    = core_gnt_o;

  always_comb begin
    state_d          = state_q;
    victim_way_d     = victim_way_q;
    evict_tag_d      = evict_tag_q;
    evict_set_d      = evict_set_q;
    evict_way_d      = evict_way_q;
    evict_to_maint_d = evict_to_maint_q;
    req_done         = 1'b0;
    maint_done_o     = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        if (maint_start) begin
          if (ReadOnly) begin
            maint_done_o = 1'b1;          // invalidate completes in this cycle
          end else begin
            state_d = S_MAINT;
          end
        end else if (req_valid_q) begin
          if (!req_cacheable || wt_store) begin
            state_d = S_BYPASS;  // uncached access, or write-through store (line updated if hit)
          end else if (hit) begin
            req_done = 1'b1;
          end else begin
            // Miss: evict the victim first if it holds modified data
            victim_way_d = repl_victim;
            if (!ReadOnly && valid_q[req_set][repl_victim] && dirty_q[req_set][repl_victim]) begin
              evict_tag_d      = tag_q[req_set][repl_victim];
              evict_set_d      = req_set;
              evict_way_d      = repl_victim;
              evict_to_maint_d = 1'b0;
              state_d          = S_EVICT;
            end else begin
              state_d          = S_REFILL;
            end
          end
        end
      end

      S_EVICT: begin
        if (evict_last) begin
          state_d = evict_to_maint_q ? S_MAINT : S_REFILL;
        end
      end

      S_REFILL: begin
        if (refill_last) begin
          // Success: return to IDLE and replay the lookup, which now hits.
          state_d = (refill_err_q | mem_err_i) ? S_ERR_RESP : S_IDLE;
        end
      end

      S_BYPASS: begin
        if (bypass_gnt_q && mem_rvalid_i) begin
          req_done = 1'b1;
          state_d  = S_IDLE;
        end
      end

      S_ERR_RESP: begin
        req_done = 1'b1;
        state_d  = S_IDLE;
      end

      S_MAINT: begin
        if (maint_line_dirty) begin
          evict_tag_d      = tag_q[maint_set_q][maint_way_q];
          evict_set_d      = maint_set_q;
          evict_way_d      = maint_way_q;
          evict_to_maint_d = 1'b1;
          state_d          = S_EVICT;
        end else if (maint_last) begin
          maint_done_o = 1'b1;
          state_d      = S_IDLE;
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  // FSM and request registers
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q          <= S_IDLE;
      req_valid_q      <= 1'b0;
      req_missed_q     <= 1'b0;
      victim_way_q     <= '0;
      beat_req_q       <= '0;
      beat_rsp_q       <= '0;
      refill_err_q     <= 1'b0;
      bypass_gnt_q     <= 1'b0;
      evict_tag_q      <= '0;
      evict_set_q      <= '0;
      evict_way_q      <= '0;
      evict_to_maint_q <= 1'b0;
      maint_set_q      <= '0;
      maint_way_q      <= '0;
    end else begin
      state_q          <= state_d;
      victim_way_q     <= victim_way_d;
      evict_tag_q      <= evict_tag_d;
      evict_set_q      <= evict_set_d;
      evict_way_q      <= evict_way_d;
      evict_to_maint_q <= evict_to_maint_d;

      // Request register: a new request may replace one that completes this cycle
      if (new_req) begin
        req_valid_q  <= 1'b1;
        req_missed_q <= 1'b0;
      end else if (req_done) begin
        req_valid_q  <= 1'b0;
        req_missed_q <= 1'b0;
      end else if (lookup && !hit) begin
        req_missed_q <= 1'b1;
      end

      // Memory beat counters (shared by EVICT and REFILL, cleared on completion)
      if (evict_last || refill_last) begin
        beat_req_q <= '0;
        beat_rsp_q <= '0;
      end else if (state_q == S_EVICT || state_q == S_REFILL) begin
        if (mem_req_o && mem_gnt_i) beat_req_q <= beat_req_q + BeatW'(1);
        if (mem_rvalid_i)           beat_rsp_q <= beat_rsp_q + BeatW'(1);
      end

      if (state_q != S_REFILL) begin
        refill_err_q <= 1'b0;
      end else if (refill_beat && mem_err_i) begin
        refill_err_q <= 1'b1;
      end

      if (state_q == S_BYPASS) begin
        if (mem_req_o && mem_gnt_i) bypass_gnt_q <= 1'b1;
        if (req_done)               bypass_gnt_q <= 1'b0;
      end

      // Maintenance cursor: reset on entry, advance past each clean line
      if (maint_start) begin
        maint_set_q <= '0;
        maint_way_q <= '0;
      end else if (state_q == S_MAINT && !maint_line_dirty && !maint_last) begin
        if (maint_way_q == WayW'(NumWays - 1)) begin
          maint_way_q <= '0;
          maint_set_q <= maint_set_q + SetW'(1);
        end else begin
          maint_way_q <= maint_way_q + WayW'(1);
        end
      end
    end
  end

  // Request payload (no reset needed: qualified by req_valid_q)
  always_ff @(posedge clk_i) begin
    if (new_req) begin
      req_addr_q  <= core_addr_i;
      req_we_q    <= core_we_i;
      req_be_q    <= core_be_i;
      req_wdata_q <= core_wdata_i;
    end
  end

  // Tag / valid / dirty arrays
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0;
      dirty_q <= '0;
    end else begin
      if (inval_all) begin
        valid_q <= '0;
      end
      if (refill_last) begin
        // A failed refill leaves the way invalid (it may hold a partial line)
        valid_q[req_set][victim_way_q] <= fill_done;
        dirty_q[req_set][victim_way_q] <= 1'b0;
      end
      if (store_hit && !ReadOnly && !WriteThrough) begin
        dirty_q[req_set][hit_way] <= 1'b1;
      end
      if (evict_last) begin
        dirty_q[evict_set_q][evict_way_q] <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (fill_done) begin
      tag_q[req_set][victim_way_q] <= req_tag;
    end
  end

  // Store data merged into the hit word according to the byte enables
  logic [31:0] store_merged;
  always_comb begin
    store_merged = data_q[req_set][hit_way][req_word];
    for (int unsigned b = 0; b < 4; b++) begin
      if (req_be_q[b]) store_merged[8*b +: 8] = req_wdata_q[8*b +: 8];
    end
  end

  // Data array: refill beats and store hits (never in the same cycle)
  always_ff @(posedge clk_i) begin
    if (refill_beat) begin
      data_q[req_set][victim_way_q][beat_rsp_q[WordW-1:0]] <= mem_rdata_i;
    end
    if (store_hit && !ReadOnly) begin
      data_q[req_set][hit_way][req_word] <= store_merged;
    end
  end

  //////////////////////
  // Memory interface //
  //////////////////////

  always_comb begin
    mem_req_o   = 1'b0;
    mem_addr_o  = '0;
    mem_we_o    = 1'b0;
    mem_be_o    = 4'hF;
    mem_wdata_o = '0;

    unique case (state_q)
      S_EVICT: begin
        mem_req_o   = beat_req_q < BeatW'(LineWords);
        mem_we_o    = 1'b1;
        mem_addr_o  = {evict_tag_q, evict_set_q, beat_req_q[WordW-1:0], 2'b00};
        mem_wdata_o = data_q[evict_set_q][evict_way_q][beat_req_q[WordW-1:0]];
      end
      S_REFILL: begin
        mem_req_o  = beat_req_q < BeatW'(LineWords);
        mem_addr_o = {req_tag, req_set, beat_req_q[WordW-1:0], 2'b00};
      end
      S_BYPASS: begin
        mem_req_o   = ~bypass_gnt_q;
        mem_addr_o  = req_addr_q;
        mem_we_o    = req_we_q;
        mem_be_o    = req_be_q;
        mem_wdata_o = req_wdata_q;
      end
      default: ;
    endcase
  end

  /////////////////////////
  // Core response path  //
  /////////////////////////

  always_comb begin
    core_rvalid_o = 1'b0;
    core_rdata_o  = '0;
    core_err_o    = 1'b0;

    unique case (state_q)
      S_IDLE: begin
        core_rvalid_o = resp_now;
        core_rdata_o  = data_q[req_set][hit_way][req_word];
      end
      S_BYPASS: begin
        core_rvalid_o = bypass_gnt_q & mem_rvalid_i;
        core_rdata_o  = mem_rdata_i;
        core_err_o    = bypass_gnt_q & mem_rvalid_i & mem_err_i;  // err is only defined with rvalid
      end
      S_ERR_RESP: begin
        core_rvalid_o = 1'b1;
        core_err_o    = 1'b1;
      end
      default: ;
    endcase
  end

  ///////////////////////
  // Performance events //
  ///////////////////////

  assign perf_access_o    = lookup & ~req_missed_q;
  assign perf_miss_o      = lookup & ~req_missed_q & ~hit;
  assign perf_writeback_o = evict_last;
  assign perf_bypass_o    = (state_q == S_IDLE) & req_valid_q & ~req_cacheable;

  ////////////////
  // Assertions //
  ////////////////

`ifndef SYNTHESIS
  initial begin
    if ((NumSets & (NumSets - 1)) != 0 || NumSets < 2) begin
      $fatal(1, "ibex_l1_cache: NumSets (%0d) must be a power of two >= 2", NumSets);
    end
    if ((LineBytes & (LineBytes - 1)) != 0 || LineBytes < 8) begin
      $fatal(1, "ibex_l1_cache: LineBytes (%0d) must be a power of two >= 8", LineBytes);
    end
  end

  // Outstanding memory-side beats (for response accounting)
  int unsigned mem_outstanding_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_outstanding_q <= 0;
    end else begin
      mem_outstanding_q <= mem_outstanding_q + ((mem_req_o && mem_gnt_i) ? 1 : 0)
                                             - (mem_rvalid_i ? 1 : 0);
    end
  end

  // --- Core-side protocol ---
  // At most one core request is in flight; a response always belongs to it.
  `UARCH_ASSERT(CoreRvalidHasRequest, core_rvalid_o |-> req_valid_q)
  `UARCH_ASSERT(CoreGntOnlyWhenIdle, core_gnt_o |-> (state_q == S_IDLE))
  `UARCH_ASSERT(CoreErrOnlyWithRvalid, core_err_o |-> core_rvalid_o)
  `UARCH_ASSERT(ReadOnlyNeverWritesMemory, ReadOnly |-> !(mem_req_o && mem_we_o && state_q != S_BYPASS))
  `UARCH_ASSERT_KNOWN_IF(CoreRdataKnown, core_rdata_o, core_rvalid_o && !core_err_o && !req_we_q)

  // --- Memory-side protocol ---
  // A request stays asserted with stable attributes until it is granted.
  `UARCH_ASSERT(MemReqStable, mem_req_o && !mem_gnt_i |=>
      mem_req_o && $stable(mem_addr_o) && $stable(mem_we_o) && $stable(mem_be_o) &&
      $stable(mem_wdata_o))
  `UARCH_ASSERT(MemRvalidExpected, mem_rvalid_i |-> mem_outstanding_q > 0)
  `UARCH_ASSERT(MemAddrAligned, mem_req_o |-> mem_addr_o[1:0] == 2'b00)

  // --- Cache state invariants ---
  `UARCH_ASSERT(HitOneHot, lookup |-> $onehot0(way_hit))
  // A refill never overwrites modified data: dirty victims are evicted first
  `UARCH_ASSERT(RefillVictimClean, state_q == S_REFILL |-> !dirty_q[req_set][victim_way_q])
  // A successful refill makes the replayed lookup hit
  `UARCH_ASSERT(ReplayHitsAfterRefill, fill_done |=> hit)
  // Only a writable cache can hold dirty lines, and only valid lines can be dirty
  `UARCH_ASSERT(DirtyImpliesValid, (dirty_q[req_set] & ~valid_q[req_set]) == '0)
  `UARCH_ASSERT(ReadOnlyNeverDirty, ReadOnly |-> dirty_q[req_set] == '0)
  `UARCH_ASSERT(WriteThroughNeverDirty, WriteThrough |-> dirty_q[req_set] == '0)
  // Maintenance: after a clean completes, no line in the cache is dirty
  `UARCH_ASSERT(CleanLeavesNoDirtyLines, !ReadOnly && maint_done_o |=> dirty_q == '0)

  // --- DV observation points (sampled hierarchically by dv/coverage/uarch_coverage.sv) ---
  logic dv_evict_start;     // miss with a dirty victim: write-back begins
  logic dv_refilling;       // line refill in progress
  logic dv_evicting;        // dirty-line write-back in progress
  logic dv_mem_stall;       // memory request not granted (back-pressure)
  logic dv_maint_writeback; // dirty line written back by a clean operation
  assign dv_evict_start     = (state_q == S_IDLE) & (state_d == S_EVICT);
  assign dv_refilling       = (state_q == S_REFILL);
  assign dv_evicting        = (state_q == S_EVICT);
  assign dv_mem_stall       = mem_req_o & ~mem_gnt_i;
  assign dv_maint_writeback = evict_last & evict_to_maint_q;

  // --- Functional coverage points ---
  `UARCH_COVER(CovReadHit,        hit && !req_we_q)
  `UARCH_COVER(CovWriteHit,       hit && req_we_q)
  `UARCH_COVER(CovReadMiss,       lookup && !hit && !req_we_q)
  `UARCH_COVER(CovWriteMiss,      lookup && !hit && req_we_q)
  `UARCH_COVER(CovDirtyEviction,  state_q == S_IDLE && state_d == S_EVICT)
  `UARCH_COVER(CovBackToBackHit,  hit && core_gnt_o)
  `UARCH_COVER(CovBypass,         perf_bypass_o)
  `UARCH_COVER(CovMaintWriteback, state_q == S_MAINT && state_d == S_EVICT)
  `UARCH_COVER(CovRefillError,    state_q == S_ERR_RESP)
  `UARCH_COVER(CovWriteThroughHit, wt_store && hit)
`endif

endmodule
