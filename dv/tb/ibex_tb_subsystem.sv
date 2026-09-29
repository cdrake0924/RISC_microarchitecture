// Copyright 2018 Robert Balas <balasr@student.ethz.ch>
// Copyright 2026 RISC_microarchitecture contributors.
//
// Copyright and related rights are licensed under the Solderpad Hardware License, Version 0.51
// (the "License"); you may not use this file except in compliance with the License. You may obtain
// a copy of the License at http://solderpad.org/licenses/SHL-0.51. Unless required by applicable
// law or agreed to in writing, software, hardware and materials distributed under this License is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing permissions and limitations under
// the License.

/**
 * Ibex core-complex test subsystem
 *
 * Adapted from the CV32E40P example testbench (example_tb/core/cv32e40p_tb_subsystem.sv): the
 * CV32E40P core is replaced by ibex_cc_top (Ibex + dynamic branch predictor + L1 caches), and the
 * environment gains the checkers and coverage models that the CV32E40P example lacks:
 *
 *   rvfi_pc_checker   architectural control-flow check at retirement (branch prediction)
 *   mem_scoreboard    end-to-end data/instruction check against a reference memory (caches)
 *   obi_checker x4    bus protocol assertions on core-side and memory-side interfaces
 *   *_cov             functional coverage bins
 *   ibex_tracer       optional instruction trace (+trace)
 */
module ibex_tb_subsystem import ibex_uarch_pkg::*; #(
  parameter int unsigned  RamAddrWidth = 20,
  parameter logic [31:0]  BootAddr     = 32'h0000_0000,
  // Micro-architecture configuration (see ibex_cc_top)
  parameter bp_mode_e     BpMode       = BpGshare,
  parameter int unsigned  BpPhtEntries = 512,
  parameter int unsigned  BpGhrBits    = 8,
  parameter int unsigned  BpRasDepth   = 8,
  parameter int unsigned  BpBtbEntries = 16,
  parameter bit           ICacheEn     = 1'b1,
  parameter bit           ICachePf     = 1'b1,
  parameter int unsigned  ICacheSets   = 64,
  parameter int unsigned  ICacheWays   = 2,
  parameter int unsigned  ICacheLine   = 16,
  parameter repl_policy_e ICacheRepl   = ReplPlru,
  parameter bit           DCacheEn     = 1'b1,
  parameter int unsigned  DCacheSets   = 64,
  parameter int unsigned  DCacheWays   = 2,
  parameter int unsigned  DCacheLine   = 16,
  parameter repl_policy_e DCacheRepl   = ReplPlru,
  parameter bit           DCacheWt     = 1'b0
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        fetch_enable_i,
  output logic        exit_valid_o,
  output logic [31:0] exit_value_o
);

  // Memory-side buses
  logic        imem_req, imem_gnt, imem_rvalid, imem_err;
  logic [31:0] imem_addr, imem_rdata;
  logic        dmem_req, dmem_gnt, dmem_rvalid, dmem_err, dmem_we;
  logic [3:0]  dmem_be;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        irq_timer;

  ////////////////////////////
  // Device under test      //
  ////////////////////////////

  ibex_cc_top #(
    .BpMode         (BpMode),
    .BpPhtEntries   (BpPhtEntries),
    .BpGhrBits      (BpGhrBits),
    .BpRasDepth     (BpRasDepth),
    .BpBtbEntries   (BpBtbEntries),
    .ICacheEn       (ICacheEn),
    .ICachePrefetch (ICachePf),
    .ICacheSets     (ICacheSets),
    .ICacheWays     (ICacheWays),
    .ICacheLineBytes(ICacheLine),
    .ICacheRepl     (ICacheRepl),
    .DCacheEn       (DCacheEn),
    .DCacheSets     (DCacheSets),
    .DCacheWays     (DCacheWays),
    .DCacheLineBytes(DCacheLine),
    .DCacheRepl     (DCacheRepl),
    .DCacheWriteThrough(DCacheWt)
  ) dut (
    .clk_i,
    .rst_ni,
    .hart_id_i      (32'h0),
    .boot_addr_i    (BootAddr),
    .fetch_enable_i,

    .imem_req_o     (imem_req),
    .imem_gnt_i     (imem_gnt),
    .imem_addr_o    (imem_addr),
    .imem_rvalid_i  (imem_rvalid),
    .imem_rdata_i   (imem_rdata),
    .imem_err_i     (imem_err),

    .dmem_req_o     (dmem_req),
    .dmem_gnt_i     (dmem_gnt),
    .dmem_we_o      (dmem_we),
    .dmem_be_o      (dmem_be),
    .dmem_addr_o    (dmem_addr),
    .dmem_wdata_o   (dmem_wdata),
    .dmem_rvalid_i  (dmem_rvalid),
    .dmem_rdata_i   (dmem_rdata),
    .dmem_err_i     (dmem_err),

    .irq_software_i (1'b0),
    .irq_timer_i    (irq_timer),
    .irq_external_i (1'b0),
    .irq_fast_i     ('0),
    .irq_nm_i       (1'b0),
    .debug_req_i    (1'b0),

    .core_sleep_o       (),
    .double_fault_seen_o()
  );

  ////////////////////////////
  // Memory + peripherals   //
  ////////////////////////////

  // Configuration word visible to software at 0x2000_0100 (see sw/common/platform.h)
  localparam bit RasEn = (BpMode != BpNone) && (BpRasDepth > 0);
  localparam bit BtbEn = (BpMode != BpNone) && (BpBtbEntries > 0);
  localparam logic [31:0] ConfigWord = {16'(DCacheLine), 4'(ICacheLine / 4), 3'b0,
                                        DCacheWt, ICachePf & ICacheEn, BtbEn, RasEn,
                                        DCacheEn, ICacheEn, 3'(BpMode)};

  tb_mem #(
    .RamAddrWidth(RamAddrWidth),
    .ConfigWord  (ConfigWord)
  ) u_mem (
    .clk_i,
    .rst_ni,
    .instr_req_i   (imem_req),
    .instr_gnt_o   (imem_gnt),
    .instr_addr_i  (imem_addr),
    .instr_rvalid_o(imem_rvalid),
    .instr_rdata_o (imem_rdata),
    .instr_err_o   (imem_err),
    .data_req_i    (dmem_req),
    .data_gnt_o    (dmem_gnt),
    .data_we_i     (dmem_we),
    .data_be_i     (dmem_be),
    .data_addr_i   (dmem_addr),
    .data_wdata_i  (dmem_wdata),
    .data_rvalid_o (dmem_rvalid),
    .data_rdata_o  (dmem_rdata),
    .data_err_o    (dmem_err),
    .irq_timer_o   (irq_timer),
    .exit_valid_o,
    .exit_value_o
  );

  ////////////////////////////
  // Checkers               //
  ////////////////////////////

  // FENCE.I completion (end of the clean/invalidate sequence)
  logic fence_busy_q, fence_done;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) fence_busy_q <= 1'b0;
    else         fence_busy_q <= dut.fetch_hold;
  end
  assign fence_done = fence_busy_q & ~dut.fetch_hold;

  mem_scoreboard #(
    .RamAddrWidth(RamAddrWidth)
  ) u_mem_sb (
    .clk_i,
    .rst_ni,
    .instr_req_i   (dut.instr_req),
    .instr_gnt_i   (dut.instr_gnt),
    .instr_addr_i  (dut.instr_addr),
    .instr_rvalid_i(dut.instr_rvalid),
    .instr_rdata_i (dut.instr_rdata),
    .instr_err_i   (dut.instr_err),
    .data_req_i    (dut.data_req),
    .data_gnt_i    (dut.data_gnt),
    .data_we_i     (dut.data_we),
    .data_be_i     (dut.data_be),
    .data_addr_i   (dut.data_addr),
    .data_wdata_i  (dut.data_wdata),
    .data_rvalid_i (dut.data_rvalid),
    .data_rdata_i  (dut.data_rdata),
    .data_err_i    (dut.data_err),
    .fence_done_i  (fence_done)
  );

  // Bus protocol checkers: core side (Ibex issues at most 2 outstanding requests per port) ...
  logic       core_i_stall, core_d_stall, imem_stall, dmem_stall;
  logic [3:0] core_i_outstanding, unused_outstanding[3];

  obi_checker #(.Name("core_instr"), .MaxOutstanding(2)) u_obi_core_instr (
    .clk_i, .rst_ni,
    .req_i(dut.instr_req), .gnt_i(dut.instr_gnt), .addr_i(dut.instr_addr), .we_i(1'b0),
    .be_i(4'hF), .wdata_i('0), .rvalid_i(dut.instr_rvalid),
    .stall_o(core_i_stall), .outstanding_o(core_i_outstanding)
  );
  obi_checker #(.Name("core_data"), .MaxOutstanding(2)) u_obi_core_data (
    .clk_i, .rst_ni,
    .req_i(dut.data_req), .gnt_i(dut.data_gnt), .addr_i(dut.data_addr), .we_i(dut.data_we),
    .be_i(dut.data_be), .wdata_i(dut.data_wdata), .rvalid_i(dut.data_rvalid),
    .stall_o(core_d_stall), .outstanding_o(unused_outstanding[0])
  );
  // ... and memory side (a cache line fill can have up to LineWords beats in flight)
  obi_checker #(.Name("mem_instr"), .MaxOutstanding(16)) u_obi_mem_instr (
    .clk_i, .rst_ni,
    .req_i(imem_req), .gnt_i(imem_gnt), .addr_i(imem_addr), .we_i(1'b0),
    .be_i(4'hF), .wdata_i('0), .rvalid_i(imem_rvalid),
    .stall_o(imem_stall), .outstanding_o(unused_outstanding[1])
  );
  obi_checker #(.Name("mem_data"), .MaxOutstanding(16)) u_obi_mem_data (
    .clk_i, .rst_ni,
    .req_i(dmem_req), .gnt_i(dmem_gnt), .addr_i(dmem_addr), .we_i(dmem_we),
    .be_i(dmem_be), .wdata_i(dmem_wdata), .rvalid_i(dmem_rvalid),
    .stall_o(dmem_stall), .outstanding_o(unused_outstanding[2])
  );

`ifdef RVFI
  logic ret_cond, ret_taken, ret_bwd, ret_c, ret_jal, ret_jalr;

  rvfi_pc_checker u_rvfi_checker (
    .clk_i,
    .rst_ni,
    .rvfi_valid       (dut.rvfi_valid),
    .rvfi_insn        (dut.rvfi_insn),
    .rvfi_trap        (dut.rvfi_trap),
    .rvfi_intr        (dut.rvfi_intr),
    .rvfi_pc_rdata    (dut.rvfi_pc_rdata),
    .rvfi_rs1_rdata   (dut.rvfi_rs1_rdata),
    .rvfi_rs2_rdata   (dut.rvfi_rs2_rdata),
    .rvfi_rd_addr     (dut.rvfi_rd_addr),
    .rvfi_rd_wdata    (dut.rvfi_rd_wdata),
    .ret_cond_branch_o(ret_cond),
    .ret_taken_o      (ret_taken),
    .ret_backward_o   (ret_bwd),
    .ret_compressed_o (ret_c),
    .ret_jal_o        (ret_jal),
    .ret_jalr_o       (ret_jalr)
  );

  arch_cov u_arch_cov (
    .clk_i,
    .rst_ni,
    .cond_branch_i(ret_cond),
    .taken_i      (ret_taken),
    .backward_i   (ret_bwd),
    .compressed_i (ret_c),
    .jal_i        (ret_jal),
    .jalr_i       (ret_jalr),
    .trap_i       (dut.rvfi_valid & dut.rvfi_trap),
    .intr_i       (dut.rvfi_valid & dut.rvfi_intr)
  );

  // Optional execution trace (+trace): trace_core_00000000.log
  bit trace_en;
  initial trace_en = $test$plusargs("trace");

  ibex_tracer u_tracer (
    .clk_i,
    .rst_ni,
    .hart_id_i                   (32'h0),
    .rvfi_valid                  (dut.rvfi_valid & trace_en),
    .rvfi_order                  (dut.rvfi_order),
    .rvfi_insn                   (dut.rvfi_insn),
    .rvfi_trap                   (dut.rvfi_trap),
    .rvfi_halt                   (dut.rvfi_halt),
    .rvfi_intr                   (dut.rvfi_intr),
    .rvfi_mode                   (dut.rvfi_mode),
    .rvfi_ixl                    (dut.rvfi_ixl),
    .rvfi_rs1_addr               (dut.rvfi_rs1_addr),
    .rvfi_rs2_addr               (dut.rvfi_rs2_addr),
    .rvfi_rs3_addr               (dut.rvfi_rs3_addr),
    .rvfi_rs1_rdata              (dut.rvfi_rs1_rdata),
    .rvfi_rs2_rdata              (dut.rvfi_rs2_rdata),
    .rvfi_rs3_rdata              (dut.rvfi_rs3_rdata),
    .rvfi_rd_addr                (dut.rvfi_rd_addr),
    .rvfi_rd_wdata               (dut.rvfi_rd_wdata),
    .rvfi_pc_rdata               (dut.rvfi_pc_rdata),
    .rvfi_pc_wdata               (dut.rvfi_pc_wdata),
    .rvfi_mem_addr               (dut.rvfi_mem_addr),
    .rvfi_mem_rmask              (dut.rvfi_mem_rmask),
    .rvfi_mem_wmask              (dut.rvfi_mem_wmask),
    .rvfi_mem_rdata              (dut.rvfi_mem_rdata),
    .rvfi_mem_wdata              (dut.rvfi_mem_wdata),
    .rvfi_ext_expanded_insn_valid(1'b0),
    .rvfi_ext_expanded_insn      ('0)
  );
`endif

  ////////////////////////////
  // Coverage               //
  ////////////////////////////

  // Pipeline redirect checker ("flushes are correct")
  logic cov_nt_recover, cov_target_recover;

  redirect_checker u_redirect_checker (
    .clk_i,
    .rst_ni,
    .pc_set_i            (dut.u_ibex_top.u_ibex_core.pc_set),
    .pc_mux_i            (dut.u_ibex_top.u_ibex_core.pc_mux_id),
    .branch_target_ex_i  (dut.u_ibex_top.u_ibex_core.branch_target_ex),
    .nt_mispredict_i     (dut.u_ibex_top.u_ibex_core.nt_branch_mispredict),
    .nt_addr_i           (dut.u_ibex_top.u_ibex_core.nt_branch_addr),
    .jump_mispredict_i   (dut.u_ibex_top.u_ibex_core.id_stage_i.jump_mispredict),
    .instr_new_id_i      (dut.u_ibex_top.u_ibex_core.instr_new_id),
    .pc_id_i             (dut.u_ibex_top.u_ibex_core.pc_id),
    .cov_nt_recover_o    (cov_nt_recover),
    .cov_target_recover_o(cov_target_recover)
  );

  // RAS occupancy (only exists when the predictor has a RAS)
  logic ras_full, ras_empty;
  if (RasEn) begin : g_ras_probe
    assign ras_full  = dut.u_ibex_top.u_ibex_core.if_stage_i.g_branch_predictor.branch_predict_i
                          .g_ras.cnt_q == BpRasDepth;
    assign ras_empty = dut.u_ibex_top.u_ibex_core.if_stage_i.g_branch_predictor.branch_predict_i
                          .g_ras.cnt_q == 0;
  end else begin : g_no_ras_probe
    assign ras_full  = 1'b0;
    assign ras_empty = 1'b1;
  end

  bp_cov #(
    .RasEn     (RasEn),
    .BtbEn     (BtbEn),
    .Tournament(BpMode == BpTournament)
  ) u_bp_cov (
    .clk_i,
    .rst_ni,
    .resolve_i        (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_cond_upd_o.valid),
    .predicted_taken_i(dut.u_ibex_top.u_ibex_core.id_stage_i.instr_bp_taken_i),
    .actual_taken_i   (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_cond_upd_o.taken),
    .nt_mispredict_i  (dut.u_ibex_top.u_ibex_core.id_stage_i.nt_branch_mispredict_o),
    .pred_bim_i       (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_cond_upd_o.meta.pred_bim),
    .pred_gsh_i       (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_cond_upd_o.meta.pred_gsh),
    .jump_i           (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_jump_upd_o),
    .perf_i           (dut.u_ibex_top.u_ibex_core.id_stage_i.bp_perf_o),
    .ras_full_i       (ras_full),
    .ras_empty_i      (ras_empty),
    .target_recover_i (cov_target_recover)
  );

  bus_cov u_bus_cov (
    .clk_i,
    .rst_ni,
    .imem_stall_i            (imem_stall),
    .dmem_stall_i            (dmem_stall),
    .core_instr_outstanding_i(core_i_outstanding),
    .fence_done_i            (fence_done),
    .data_err_i              (dut.data_rvalid & dut.data_err)
  );

  if (ICacheEn) begin : g_icache_cov
    cache_cov #(.Name("icache"), .NumWays(ICacheWays), .ReadOnly(1'b1)) u_cov (
      .clk_i,
      .rst_ni,
      .lookup_i         (dut.g_icache.u_icache.lookup),
      .first_lookup_i   (dut.g_icache.u_icache.perf_access_o),
      .hit_i            (dut.g_icache.u_icache.hit),
      .we_i             (1'b0),
      .hit_way_i        (8'(dut.g_icache.u_icache.hit_way)),
      .victim_way_i     (8'(dut.g_icache.u_icache.repl_victim)),
      .miss_start_i     (dut.g_icache.u_icache.perf_miss_o),
      .evict_start_i    (1'b0),
      .bypass_i         (dut.g_icache.u_icache.perf_bypass_o),
      .core_gnt_i       (dut.g_icache.u_icache.core_gnt_o),
      .mem_stall_i      (dut.g_icache.u_icache.dv_mem_stall),
      .refilling_i      (dut.g_icache.u_icache.dv_refilling),
      .maint_done_i     (dut.g_icache.u_icache.maint_done_o),
      .maint_writeback_i(1'b0)
    );
  end

  if (ICacheEn && ICachePf) begin : g_prefetch_cov
    prefetch_cov u_cov (
      .clk_i,
      .rst_ni,
      .issue_i       (dut.g_icache.g_prefetch.u_prefetch.perf_pf_issue_o),
      .hit_i         (dut.g_icache.g_prefetch.u_prefetch.perf_pf_hit_o),
      .hit_filling_i (dut.g_icache.g_prefetch.u_prefetch.up_accept &
                      dut.g_icache.g_prefetch.u_prefetch.up_buf_hit &
                      !dut.g_icache.g_prefetch.u_prefetch.buf_word_q[
                          dut.g_icache.g_prefetch.u_prefetch.up_word]),
      .drop_i        (dut.g_icache.g_prefetch.u_prefetch.mem_rvalid_i &
                      dut.g_icache.g_prefetch.u_prefetch.mq_head_pf &
                      dut.g_icache.g_prefetch.u_prefetch.pf_drop_q),
      .demand_first_i(dut.g_icache.g_prefetch.u_prefetch.dem_fwd &
                      dut.g_icache.g_prefetch.u_prefetch.pf_want &
                      !dut.g_icache.g_prefetch.u_prefetch.pf_hold_q)
    );
  end

  if (DCacheEn) begin : g_dcache_cov
    cache_cov #(.Name("dcache"), .NumWays(DCacheWays), .ReadOnly(1'b0),
                .WriteThrough(DCacheWt)) u_cov (
      .clk_i,
      .rst_ni,
      .lookup_i         (dut.g_dcache.u_dcache.lookup),
      .first_lookup_i   (dut.g_dcache.u_dcache.perf_access_o),
      .hit_i            (dut.g_dcache.u_dcache.hit),
      .we_i             (dut.g_dcache.u_dcache.req_we_q),
      .hit_way_i        (8'(dut.g_dcache.u_dcache.hit_way)),
      .victim_way_i     (8'(dut.g_dcache.u_dcache.repl_victim)),
      .miss_start_i     (dut.g_dcache.u_dcache.perf_miss_o),
      .evict_start_i    (dut.g_dcache.u_dcache.dv_evict_start),
      .bypass_i         (dut.g_dcache.u_dcache.perf_bypass_o),
      .core_gnt_i       (dut.g_dcache.u_dcache.core_gnt_o),
      .mem_stall_i      (dut.g_dcache.u_dcache.dv_mem_stall),
      .refilling_i      (dut.g_dcache.u_dcache.dv_refilling),
      .maint_done_i     (dut.g_dcache.u_dcache.maint_done_o),
      .maint_writeback_i(dut.g_dcache.u_dcache.dv_maint_writeback)
    );
  end

endmodule
