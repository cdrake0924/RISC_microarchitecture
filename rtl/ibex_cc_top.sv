// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Ibex core complex: ibex_top + L1 instruction cache (+ next-line prefetcher) + L1 data cache
 *
 *                 +------------------------------------------------------------+
 *                 | ibex_cc_top                                                |
 *                 |   +-----------------------+    instr     +-----------+     |  imem_*
 *                 |   | ibex_top              |------------->| L1 I$ (RO)|-----+-------->
 *                 |   |  IF: ibex_bp_dynamic  |              +-----------+     |
 *                 |   |  CSR: extended HPM    |    data      +-----------+     |  dmem_*
 *                 |   |                       |------------->| L1 D$ (WB)|-----+-------->
 *                 |   +-----------------------+              +-----------+     |
 *                 |        | fencei_o  ^ hpm_ext_event_i        ^   |           |
 *                 |        v           |                        |   |           |
 *                 |   FENCE.I sequencer (clean D$ -> invalidate I$)  perf events |
 *                 +------------------------------------------------------------+
 *
 * Both caches are optional (ICacheEn / DCacheEn). When a cache is disabled its port is a plain
 * wire-through, so the same wrapper provides every configuration used in the evaluation. With
 * ICachePrefetch a one-line stream buffer (ibex_l1_prefetch) sits between the I-cache and memory.
 * The D-cache is write-back/write-allocate or write-through/no-allocate (DCacheWriteThrough).
 *
 * FENCE.I coherence: the D-cache is write-back, so a store that modifies code may still be sitting
 * in a dirty D-cache line. On FENCE.I the sequencer (1) holds instruction fetch, (2) cleans the
 * D-cache (writes back every dirty line), (3) invalidates the I-cache, then releases fetch. The
 * core implements FENCE.I as a jump to the next PC, so the refetch after the fence observes the
 * updated memory.
 */

`include "uarch_assert.svh"

module ibex_cc_top import ibex_uarch_pkg::*; #(
  // ---- Core ----
  parameter ibex_pkg::rv32m_e RV32M            = ibex_pkg::RV32MFast,
  parameter ibex_pkg::rv32b_e RV32B            = ibex_pkg::RV32BNone,
  parameter bit               BranchTargetALU  = 1'b0,
  parameter bit               WritebackStage   = 1'b0,
  parameter int unsigned      MHPMCounterNum   = HPM_NUM_COUNTERS,
  parameter int unsigned      MHPMCounterWidth = 40,
  // ---- Branch prediction ----
  parameter bp_mode_e         BpMode           = BpGshare,
  parameter int unsigned      BpPhtEntries     = 512,
  parameter int unsigned      BpGhrBits        = 8,
  parameter int unsigned      BpRasDepth       = 8,   // return address stack (0 = off)
  parameter int unsigned      BpBtbEntries     = 16,  // indirect-jump BTB (0 = off)
  // ---- L1 instruction cache ----
  parameter bit               ICacheEn         = 1'b1,
  parameter int unsigned      ICacheSets       = 64,
  parameter int unsigned      ICacheWays       = 2,
  parameter int unsigned      ICacheLineBytes  = 16,
  parameter repl_policy_e     ICacheRepl       = ReplPlru,
  parameter bit               ICachePrefetch   = 1'b1,  // next-line prefetcher
  // ---- L1 data cache ----
  parameter bit               DCacheEn         = 1'b1,
  parameter int unsigned      DCacheSets       = 64,
  parameter int unsigned      DCacheWays       = 2,
  parameter int unsigned      DCacheLineBytes  = 16,
  parameter repl_policy_e     DCacheRepl       = ReplPlru,
  parameter bit               DCacheWriteThrough = 1'b0,
  // ---- Memory map ----
  parameter logic [31:0]      CacheableMask    = 32'hF000_0000,  // default: 0x0xxx_xxxx is RAM
  parameter logic [31:0]      CacheableBase    = 32'h0000_0000,
  parameter int unsigned      DmHaltAddr       = 32'h1A11_0800,
  parameter int unsigned      DmExceptionAddr  = 32'h1A11_0808
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic [31:0] hart_id_i,
  input  logic [31:0] boot_addr_i,
  input  logic        fetch_enable_i,

  // Instruction memory port (next level)
  output logic        imem_req_o,
  input  logic        imem_gnt_i,
  output logic [31:0] imem_addr_o,
  input  logic        imem_rvalid_i,
  input  logic [31:0] imem_rdata_i,
  input  logic        imem_err_i,

  // Data memory port (next level)
  output logic        dmem_req_o,
  input  logic        dmem_gnt_i,
  output logic        dmem_we_o,
  output logic [3:0]  dmem_be_o,
  output logic [31:0] dmem_addr_o,
  output logic [31:0] dmem_wdata_o,
  input  logic        dmem_rvalid_i,
  input  logic [31:0] dmem_rdata_i,
  input  logic        dmem_err_i,

  // Interrupts / debug
  input  logic        irq_software_i,
  input  logic        irq_timer_i,
  input  logic        irq_external_i,
  input  logic [14:0] irq_fast_i,
  input  logic        irq_nm_i,
  input  logic        debug_req_i,

  output logic        core_sleep_o,
  output logic        double_fault_seen_o
);

  ////////////////////////////////
  // Core <-> cache interfaces  //
  ////////////////////////////////

  // Instruction side (core view)
  logic        instr_req, instr_gnt, instr_rvalid, instr_err;
  logic [31:0] instr_addr, instr_rdata;

  // Data side (core view)
  logic        data_req, data_gnt, data_rvalid, data_we, data_err;
  logic [3:0]  data_be;
  logic [31:0] data_addr, data_wdata, data_rdata;

  logic        fencei;
  logic [HPM_EXT_EVENTS-1:0] hpm_ext_event;

  ///////////
  // Core  //
  ///////////

`ifdef RVFI
  // Retirement trace, observed hierarchically by the testbench checkers and tracer.
  logic        rvfi_valid;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn;
  logic        rvfi_trap;
  logic        rvfi_halt;
  logic        rvfi_intr;
  logic [ 1:0] rvfi_mode;
  logic [ 1:0] rvfi_ixl;
  logic [ 4:0] rvfi_rs1_addr;
  logic [ 4:0] rvfi_rs2_addr;
  logic [ 4:0] rvfi_rs3_addr;
  logic [31:0] rvfi_rs1_rdata;
  logic [31:0] rvfi_rs2_rdata;
  logic [31:0] rvfi_rs3_rdata;
  logic [ 4:0] rvfi_rd_addr;
  logic [31:0] rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata;
  logic [31:0] rvfi_pc_wdata;
  logic [31:0] rvfi_mem_addr;
  logic [ 3:0] rvfi_mem_rmask;
  logic [ 3:0] rvfi_mem_wmask;
  logic [31:0] rvfi_mem_rdata;
  logic [31:0] rvfi_mem_wdata;
`endif

  ibex_top #(
    .PMPEnable       (1'b0),
    .MHPMCounterNum  (MHPMCounterNum),
    .MHPMCounterWidth(MHPMCounterWidth),
    .RV32E           (1'b0),
    .RV32M           (RV32M),
    .RV32B           (RV32B),
    .RegFile         (ibex_pkg::RegFileFF),
    .BranchTargetALU (BranchTargetALU),
    .WritebackStage  (WritebackStage),
    .ICache          (1'b0),            // replaced by the external L1 I-cache below
    .ICacheECC       (1'b0),
    .BranchPredictor (BpMode != BpNone),
    .BpMode          (BpMode),
    .BpPhtEntries    (BpPhtEntries),
    .BpGhrBits       (BpGhrBits),
    .BpRasDepth      (BpRasDepth),
    .BpBtbEntries    (BpBtbEntries),
    .DbgTriggerEn    (1'b0),
    .SecureIbex      (1'b0),
    .DmHaltAddr      (DmHaltAddr),
    .DmExceptionAddr (DmExceptionAddr)
  ) u_ibex_top (
    .clk_i,
    .rst_ni,

    .test_en_i            (1'b0),
    .ram_cfg_icache_tag_i ('0),
    .ram_cfg_icache_tag_o (),
    .ram_cfg_icache_data_i('0),
    .ram_cfg_icache_data_o(),

    .hart_id_i,
    .boot_addr_i,

    .instr_req_o       (instr_req),
    .instr_gnt_i       (instr_gnt),
    .instr_rvalid_i    (instr_rvalid),
    .instr_addr_o      (instr_addr),
    .instr_rdata_i     (instr_rdata),
    .instr_rdata_intg_i('0),
    .instr_err_i       (instr_err),

    .data_req_o       (data_req),
    .data_gnt_i       (data_gnt),
    .data_rvalid_i    (data_rvalid),
    .data_we_o        (data_we),
    .data_be_o        (data_be),
    .data_addr_o      (data_addr),
    .data_wdata_o     (data_wdata),
    .data_wdata_intg_o(),
    .data_rdata_i     (data_rdata),
    .data_rdata_intg_i('0),
    .data_err_i       (data_err),

    .irq_software_i,
    .irq_timer_i,
    .irq_external_i,
    .irq_fast_i,
    .irq_nm_i,

    .scramble_key_valid_i('0),
    .scramble_key_i      ('0),
    .scramble_nonce_i    ('0),
    .scramble_req_o      (),

    .debug_req_i,
    .crash_dump_o       (),
    .double_fault_seen_o,

`ifdef RVFI
    .rvfi_valid,
    .rvfi_order,
    .rvfi_insn,
    .rvfi_trap,
    .rvfi_halt,
    .rvfi_intr,
    .rvfi_mode,
    .rvfi_ixl,
    .rvfi_rs1_addr,
    .rvfi_rs2_addr,
    .rvfi_rs3_addr,
    .rvfi_rs1_rdata,
    .rvfi_rs2_rdata,
    .rvfi_rs3_rdata,
    .rvfi_rd_addr,
    .rvfi_rd_wdata,
    .rvfi_pc_rdata,
    .rvfi_pc_wdata,
    .rvfi_mem_addr,
    .rvfi_mem_rmask,
    .rvfi_mem_wmask,
    .rvfi_mem_rdata,
    .rvfi_mem_wdata,
    .rvfi_ext_pre_mip            (),
    .rvfi_ext_post_mip           (),
    .rvfi_ext_nmi                (),
    .rvfi_ext_nmi_int            (),
    .rvfi_ext_debug_req          (),
    .rvfi_ext_debug_mode         (),
    .rvfi_ext_rf_wr_suppress     (),
    .rvfi_ext_mcycle             (),
    .rvfi_ext_mhpmcounters       (),
    .rvfi_ext_mhpmcountersh      (),
    .rvfi_ext_ic_scr_key_valid   (),
    .rvfi_ext_irq_valid          (),
    .rvfi_ext_expanded_insn_valid(),
    .rvfi_ext_expanded_insn      (),
    .rvfi_ext_expanded_insn_last (),
`endif

    .fetch_enable_i        (fetch_enable_i ? ibex_pkg::IbexMuBiOn : ibex_pkg::IbexMuBiOff),
    .mcounteren_writable_i (ibex_pkg::IbexMuBiOn),
    .alert_minor_o         (),
    .alert_major_internal_o(),
    .alert_major_bus_o     (),
    .core_sleep_o,

    .scan_rst_ni(1'b1),

    .lockstep_cmp_en_o       (),
    .data_req_shadow_o       (),
    .data_we_shadow_o        (),
    .data_be_shadow_o        (),
    .data_addr_shadow_o      (),
    .data_wdata_shadow_o     (),
    .data_wdata_intg_shadow_o(),
    .instr_req_shadow_o      (),
    .instr_addr_shadow_o     (),

    .fencei_o       (fencei),
    .hpm_ext_event_i(hpm_ext_event)
  );

  ////////////////////////
  // FENCE.I sequencer  //
  ////////////////////////

  typedef enum logic [1:0] {
    F_IDLE,     // normal operation
    F_CLEAN_D,  // writing back dirty D-cache lines
    F_INVAL_I   // invalidating the I-cache
  } fence_state_e;

  fence_state_e fence_q, fence_d;
  logic         ic_maint_req, ic_maint_done;
  logic         dc_maint_req, dc_maint_done;
  logic         fetch_hold;

  always_comb begin
    fence_d = fence_q;
    unique case (fence_q)
      F_IDLE: begin
        if (fencei) begin
          fence_d = DCacheEn ? F_CLEAN_D : (ICacheEn ? F_INVAL_I : F_IDLE);
        end
      end
      F_CLEAN_D: begin
        if (dc_maint_done) begin
          fence_d = ICacheEn ? F_INVAL_I : F_IDLE;
        end
      end
      F_INVAL_I: begin
        if (ic_maint_done) begin
          fence_d = F_IDLE;
        end
      end
      default: fence_d = F_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fence_q <= F_IDLE;
    end else begin
      fence_q <= fence_d;
    end
  end

  assign dc_maint_req = (fence_q == F_CLEAN_D);
  assign ic_maint_req = (fence_q == F_INVAL_I);
  // Fetch is held from the FENCE.I cycle itself until the sequence completes (not needed, and
  // not applied, when neither cache exists: then the core complex is cycle-identical to Ibex).
  assign fetch_hold   = (ICacheEn || DCacheEn) & (fencei | (fence_q != F_IDLE));

  ///////////////////////////
  // L1 instruction cache  //
  ///////////////////////////

  logic ic_perf_access, ic_perf_miss, ic_perf_pf_issue, ic_perf_pf_hit;

  if (ICacheEn) begin : g_icache
    // I-cache memory port (to the prefetcher or directly to imem)
    logic        ic_mem_req, ic_mem_gnt, ic_mem_rvalid, ic_mem_err;
    logic [31:0] ic_mem_addr, ic_mem_rdata;

    ibex_l1_cache #(
      .NumSets      (ICacheSets),
      .NumWays      (ICacheWays),
      .LineBytes    (ICacheLineBytes),
      .ReadOnly     (1'b1),
      .ReplPolicy   (ICacheRepl),
      .CacheableMask(CacheableMask),
      .CacheableBase(CacheableBase)
    ) u_icache (
      .clk_i,
      .rst_ni,
      .core_req_i   (instr_req),
      .core_gnt_o   (instr_gnt),
      .core_addr_i  (instr_addr),
      .core_we_i    (1'b0),
      .core_be_i    (4'hF),
      .core_wdata_i ('0),
      .core_rvalid_o(instr_rvalid),
      .core_rdata_o (instr_rdata),
      .core_err_o   (instr_err),

      .mem_req_o   (ic_mem_req),
      .mem_gnt_i   (ic_mem_gnt),
      .mem_addr_o  (ic_mem_addr),
      .mem_we_o    (),
      .mem_be_o    (),
      .mem_wdata_o (),
      .mem_rvalid_i(ic_mem_rvalid),
      .mem_rdata_i (ic_mem_rdata),
      .mem_err_i   (ic_mem_err),

      .hold_i      (fetch_hold),
      .maint_req_i (ic_maint_req),
      .maint_done_o(ic_maint_done),

      .perf_access_o   (ic_perf_access),
      .perf_miss_o     (ic_perf_miss),
      .perf_writeback_o(),
      .perf_bypass_o   ()
    );

    if (ICachePrefetch) begin : g_prefetch
      ibex_l1_prefetch #(
        .LineBytes    (ICacheLineBytes),
        .CacheableMask(CacheableMask),
        .CacheableBase(CacheableBase)
      ) u_prefetch (
        .clk_i,
        .rst_ni,
        .up_req_i       (ic_mem_req),
        .up_gnt_o       (ic_mem_gnt),
        .up_addr_i      (ic_mem_addr),
        .up_rvalid_o    (ic_mem_rvalid),
        .up_rdata_o     (ic_mem_rdata),
        .up_err_o       (ic_mem_err),
        .mem_req_o      (imem_req_o),
        .mem_gnt_i      (imem_gnt_i),
        .mem_addr_o     (imem_addr_o),
        .mem_rvalid_i   (imem_rvalid_i),
        .mem_rdata_i    (imem_rdata_i),
        .mem_err_i      (imem_err_i),
        // Prefetched lines may be older than stores cleaned from the D-cache: drop them in the
        // cycle the I-cache invalidates (the cache is idle then, so no refill is reading the
        // buffer).
        .flush_i        (ic_maint_done),
        .perf_pf_issue_o(ic_perf_pf_issue),
        .perf_pf_hit_o  (ic_perf_pf_hit)
      );
    end else begin : g_no_prefetch
      assign imem_req_o       = ic_mem_req;
      assign ic_mem_gnt       = imem_gnt_i;
      assign imem_addr_o      = ic_mem_addr;
      assign ic_mem_rvalid    = imem_rvalid_i;
      assign ic_mem_rdata     = imem_rdata_i;
      assign ic_mem_err       = imem_err_i;
      assign ic_perf_pf_issue = 1'b0;
      assign ic_perf_pf_hit   = 1'b0;
    end
  end else begin : g_no_icache
    // Wire-through; FENCE.I still has to hold fetch while the D-cache is cleaned.
    assign imem_req_o     = instr_req & ~fetch_hold;
    assign instr_gnt      = imem_gnt_i & ~fetch_hold;
    assign imem_addr_o    = instr_addr;
    assign instr_rvalid   = imem_rvalid_i;
    assign instr_rdata    = imem_rdata_i;
    assign instr_err      = imem_err_i;
    assign ic_maint_done    = 1'b1;
    assign ic_perf_access   = 1'b0;
    assign ic_perf_miss     = 1'b0;
    assign ic_perf_pf_issue = 1'b0;
    assign ic_perf_pf_hit   = 1'b0;
  end

  ////////////////////
  // L1 data cache  //
  ////////////////////

  logic dc_perf_access, dc_perf_miss, dc_perf_writeback, dc_perf_bypass;

  if (DCacheEn) begin : g_dcache
    ibex_l1_cache #(
      .NumSets      (DCacheSets),
      .NumWays      (DCacheWays),
      .LineBytes    (DCacheLineBytes),
      .ReadOnly     (1'b0),
      .WriteThrough (DCacheWriteThrough),
      .ReplPolicy   (DCacheRepl),
      .CacheableMask(CacheableMask),
      .CacheableBase(CacheableBase)
    ) u_dcache (
      .clk_i,
      .rst_ni,
      .core_req_i   (data_req),
      .core_gnt_o   (data_gnt),
      .core_addr_i  (data_addr),
      .core_we_i    (data_we),
      .core_be_i    (data_be),
      .core_wdata_i (data_wdata),
      .core_rvalid_o(data_rvalid),
      .core_rdata_o (data_rdata),
      .core_err_o   (data_err),

      .mem_req_o   (dmem_req_o),
      .mem_gnt_i   (dmem_gnt_i),
      .mem_addr_o  (dmem_addr_o),
      .mem_we_o    (dmem_we_o),
      .mem_be_o    (dmem_be_o),
      .mem_wdata_o (dmem_wdata_o),
      .mem_rvalid_i(dmem_rvalid_i),
      .mem_rdata_i (dmem_rdata_i),
      .mem_err_i   (dmem_err_i),

      .hold_i      (1'b0),
      .maint_req_i (dc_maint_req),
      .maint_done_o(dc_maint_done),

      .perf_access_o   (dc_perf_access),
      .perf_miss_o     (dc_perf_miss),
      .perf_writeback_o(dc_perf_writeback),
      .perf_bypass_o   (dc_perf_bypass)
    );
  end else begin : g_no_dcache
    assign dmem_req_o        = data_req;
    assign data_gnt          = dmem_gnt_i;
    assign dmem_we_o         = data_we;
    assign dmem_be_o         = data_be;
    assign dmem_addr_o       = data_addr;
    assign dmem_wdata_o      = data_wdata;
    assign data_rvalid       = dmem_rvalid_i;
    assign data_rdata        = dmem_rdata_i;
    assign data_err          = dmem_err_i;
    assign dc_maint_done     = 1'b1;
    assign dc_perf_access    = 1'b0;
    assign dc_perf_miss      = 1'b0;
    assign dc_perf_writeback = 1'b0;
    assign dc_perf_bypass    = 1'b0;
  end

  //////////////////////////////
  // HPM external event map   //
  //////////////////////////////

  always_comb begin
    hpm_ext_event                   = '0;
    hpm_ext_event[ExtEvIcAccess]    = ic_perf_access;
    hpm_ext_event[ExtEvIcMiss]      = ic_perf_miss;
    hpm_ext_event[ExtEvIcPfIssue]   = ic_perf_pf_issue;
    hpm_ext_event[ExtEvIcPfHit]     = ic_perf_pf_hit;
    hpm_ext_event[ExtEvDcAccess]    = dc_perf_access;
    hpm_ext_event[ExtEvDcMiss]      = dc_perf_miss;
    hpm_ext_event[ExtEvDcWriteback] = dc_perf_writeback;
    hpm_ext_event[ExtEvDcBypass]    = dc_perf_bypass;
  end

  ////////////////
  // Assertions //
  ////////////////

`ifndef SYNTHESIS
  // The FENCE.I sequence starts only from idle and completes in bounded time; a second FENCE.I
  // cannot arrive while one is in progress because instruction fetch is held.
  `UARCH_ASSERT(FenceNotReentered, fencei |-> fence_q == F_IDLE)
  // No instruction is granted to the core while the D-cache is being cleaned
  `UARCH_ASSERT(NoFetchDuringFence, (fence_q != F_IDLE) |-> !instr_gnt)

  `UARCH_COVER(CovFenceCleanD, fence_q == F_CLEAN_D && dc_maint_done)
  `UARCH_COVER(CovFenceInvalI, fence_q == F_INVAL_I && ic_maint_done)
`endif

endmodule
