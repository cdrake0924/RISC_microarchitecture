// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Block-level constrained-random testbench for ibex_l1_cache (+ optional ibex_l1_prefetch)
 *
 * Stimulus (per transaction, all randomised)
 *   - address: uniform within a window of 4x the cache capacity (conflict misses, dirty evictions)
 *     or sequential runs of 4..16 words (spatial locality, prefetcher streams); 5% uncached (MMIO
 *     bypass); 2% to a line whose refill returns a bus error
 *   - direction: 40% stores (read-write cache only), random byte enables (word/half/byte)
 *   - timing: 0-3 idle cycles, or back-to-back (request presented during the previous response)
 *   - hold_i bursts; maintenance (clean / invalidate) at random points
 *   - reset asserted in the middle of a line refill or dirty write-back
 * Memory model: random grant stalls and response latency 1..8 cycles, in-order responses.
 *
 * Checking
 *   - every load response against a golden byte-addressed reference memory
 *   - bus-error line: every access must return err
 *   - after every clean (and at the end): backing memory == reference for the whole window, i.e.
 *     no modified data was lost or written to the wrong place
 *   - write-through: every store is already in memory when it responds
 *   - read-only caches (+ prefetcher): a backdoor memory change becomes visible after invalidation,
 *     so stale lines in the cache *and* in the prefetch buffer must have been dropped
 *   - reset during refill/eviction: the cache restarts empty and correct; dirty data that was never
 *     written back is (correctly) lost, so the reference is resynchronised to memory
 *   - the cache's and prefetcher's own SVA (built with --assert)
 *
 * Parameters are overridden with -G; the seed with +verilator+seed+<n>.
 */
module tb_l1_cache #(
  parameter int SETS  = 16,
  parameter int WAYS  = 2,
  parameter int LINE  = 16,
  parameter int RO    = 0,
  parameter int REPL  = 0,
  parameter int WT    = 0,    // write-through D-cache
  parameter int PF    = 0,    // next-line prefetcher in front of a read-only cache
  parameter int TXNS  = 20000
);
  import ibex_uarch_pkg::*;
  import tb_pkg::*;

  localparam int unsigned CacheBytes = SETS * WAYS * LINE;
  localparam int unsigned OffW       = $clog2(LINE);
  localparam int unsigned Window     = 4 * CacheBytes;
  localparam logic [31:0] ErrLine    = 32'h0000_8000;  // refills of this line return bus errors
  localparam logic [31:0] MmioBase   = 32'h1000_0000;
  localparam bit          UsePf      = (PF != 0) && (RO != 0);

  logic clk = 1'b0, rst_n = 1'b1;
  initial forever #5 clk = ~clk;

  // ---------------- DUT ----------------
  logic        core_req, core_gnt, core_we, core_rvalid, core_err;
  logic [3:0]  core_be;
  logic [31:0] core_addr, core_wdata, core_rdata;
  logic        c_req, c_gnt, c_we, c_rvalid, c_err;       // cache memory port
  logic [3:0]  c_be;
  logic [31:0] c_addr, c_wdata, c_rdata;
  logic        mem_req, mem_gnt, mem_we, mem_rvalid, mem_err;
  logic [3:0]  mem_be;
  logic [31:0] mem_addr, mem_wdata, mem_rdata;
  logic        hold, maint_req, maint_done;
  logic        perf_access, perf_miss, perf_wb, perf_bypass;

  ibex_l1_cache #(
    .NumSets     (SETS),
    .NumWays     (WAYS),
    .LineBytes   (LINE),
    .ReadOnly    (RO != 0),
    .WriteThrough(WT != 0),
    .ReplPolicy  (repl_policy_e'(REPL))
  ) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .core_req_i(core_req), .core_gnt_o(core_gnt), .core_addr_i(core_addr), .core_we_i(core_we),
    .core_be_i(core_be), .core_wdata_i(core_wdata), .core_rvalid_o(core_rvalid),
    .core_rdata_o(core_rdata), .core_err_o(core_err),
    .mem_req_o(c_req), .mem_gnt_i(c_gnt), .mem_addr_o(c_addr), .mem_we_o(c_we),
    .mem_be_o(c_be), .mem_wdata_o(c_wdata), .mem_rvalid_i(c_rvalid),
    .mem_rdata_i(c_rdata), .mem_err_i(c_err),
    .hold_i(hold), .maint_req_i(maint_req), .maint_done_o(maint_done),
    .perf_access_o(perf_access), .perf_miss_o(perf_miss), .perf_writeback_o(perf_wb),
    .perf_bypass_o(perf_bypass)
  );

  if (UsePf) begin : g_pf
    logic pf_issue, pf_hit;
    ibex_l1_prefetch #(
      .LineBytes(LINE)
    ) u_pf (
      .clk_i(clk), .rst_ni(rst_n),
      .up_req_i(c_req), .up_gnt_o(c_gnt), .up_addr_i(c_addr),
      .up_rvalid_o(c_rvalid), .up_rdata_o(c_rdata), .up_err_o(c_err),
      .mem_req_o(mem_req), .mem_gnt_i(mem_gnt), .mem_addr_o(mem_addr),
      .mem_rvalid_i(mem_rvalid), .mem_rdata_i(mem_rdata), .mem_err_i(mem_err),
      .flush_i(maint_done),
      .perf_pf_issue_o(pf_issue), .perf_pf_hit_o(pf_hit)
    );
    assign mem_we    = 1'b0;
    assign mem_be    = 4'hF;
    assign mem_wdata = '0;

    prefetch_cov u_pf_cov (
      .clk_i(clk), .rst_ni(rst_n),
      .issue_i(pf_issue), .hit_i(pf_hit),
      .hit_filling_i(u_pf.up_accept & u_pf.up_buf_hit & !u_pf.buf_word_q[u_pf.up_word]),
      .drop_i(u_pf.mem_rvalid_i & u_pf.mq_head_pf & u_pf.pf_drop_q),
      .demand_first_i(u_pf.dem_fwd & u_pf.pf_want & !u_pf.pf_hold_q)
    );
  end else begin : g_no_pf
    assign mem_req   = c_req;
    assign c_gnt     = mem_gnt;
    assign mem_addr  = c_addr;
    assign mem_we    = c_we;
    assign mem_be    = c_be;
    assign mem_wdata = c_wdata;
    assign c_rvalid  = mem_rvalid;
    assign c_rdata   = mem_rdata;
    assign c_err     = mem_err;
  end

  cache_cov #(.Name(RO ? "icache" : "dcache"), .NumWays(WAYS), .ReadOnly(RO != 0),
              .WriteThrough(WT != 0)) u_cov (
    .clk_i(clk), .rst_ni(rst_n),
    .lookup_i(dut.lookup), .first_lookup_i(perf_access), .hit_i(dut.hit), .we_i(dut.req_we_q),
    .hit_way_i(8'(dut.hit_way)), .victim_way_i(8'(dut.repl_victim)), .miss_start_i(perf_miss),
    .evict_start_i(dut.dv_evict_start), .bypass_i(perf_bypass), .core_gnt_i(core_gnt),
    .mem_stall_i(dut.dv_mem_stall), .refilling_i(dut.dv_refilling), .maint_done_i(maint_done),
    .maint_writeback_i(dut.dv_maint_writeback)
  );

  // ---------------- memory model ----------------
  logic [7:0] mem [logic [31:0]];      // backing store (sparse)
  logic [7:0] ref_mem [logic [31:0]];  // golden architectural memory

  function automatic logic [7:0] init_byte(logic [31:0] a);
    return a[7:0] ^ a[15:8] ^ 8'h5a;
  endfunction

  function automatic logic [7:0] rd(ref logic [7:0] m [logic [31:0]], input logic [31:0] a);
    if (!m.exists(a)) m[a] = init_byte(a);
    return m[a];
  endfunction

  function automatic logic [31:0] rd_word(ref logic [7:0] m [logic [31:0]], input logic [31:0] a);
    logic [31:0] w;
    for (int b = 0; b < 4; b++) w[8*b +: 8] = rd(m, {a[31:2], 2'b00} + b);
    return w;
  endfunction

  typedef struct { logic [31:0] rdata; logic err; int delay; } mresp_t;
  mresp_t mq[$];
  logic   mem_stall_q;

  always_ff @(posedge clk) mem_stall_q <= ($urandom_range(99, 0) < 25);
  assign mem_gnt = mem_req & ~mem_stall_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mem_rvalid <= 1'b0;
      mem_err    <= 1'b0;
      mq.delete();
    end else begin
      if (mem_req && mem_gnt) begin
        mresp_t r;
        r.err   = ({mem_addr[31:4], 4'b0} == ErrLine);
        r.delay = $urandom_range(7, 0);
        r.rdata = '0;
        if (!r.err) begin
          if (mem_we) begin
            for (int b = 0; b < 4; b++) if (mem_be[b]) mem[mem_addr + b] = mem_wdata[8*b +: 8];
          end else begin
            r.rdata = rd_word(mem, mem_addr);
          end
        end
        mq.push_back(r);
      end
      mem_rvalid <= 1'b0;
      mem_err    <= 1'b0;
      if (mq.size() > 0) begin
        if (mq[0].delay == 0) begin
          mem_rvalid <= 1'b1;
          mem_rdata  <= mq[0].rdata;
          mem_err    <= mq[0].err;
          void'(mq.pop_front());
        end else begin
          mq[0].delay--;
        end
      end
    end
  end

  // ---------------- checking ----------------
  typedef struct { logic [31:0] addr; logic we; logic [3:0] be; logic [31:0] exp; logic exp_err; } txn_t;
  txn_t outstanding[$];

  int unsigned n_done, n_loads, n_stores, n_err, n_bypass, n_maint, n_hits, n_misses, n_wb, n_resets;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (perf_access && dut.hit) n_hits++;
      if (perf_miss)             n_misses++;
      if (perf_wb)               n_wb++;
      if (hold && core_gnt)      tb_error("TB", "request granted while hold_i is asserted");
    end
  end

  function automatic logic [31:0] be_mask(logic [3:0] be);
    return {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  endfunction

  always_ff @(posedge clk) begin
    if (rst_n && core_rvalid) begin
      txn_t t;
      if (outstanding.size() == 0) begin
        tb_error("TB", "response without an outstanding request");
      end else begin
        t = outstanding.pop_front();
        n_done++;
        if (core_err != t.exp_err) begin
          tb_error("TB", $sformatf("addr 0x%08x we=%0d: err=%0d, expected %0d", t.addr, t.we,
                                   core_err, t.exp_err));
        end else if (!t.we && !t.exp_err) begin
          if ((core_rdata & be_mask(t.be)) !== (t.exp & be_mask(t.be))) begin
            tb_error("TB", $sformatf("load 0x%08x be=%b returned 0x%08x, expected 0x%08x",
                                     t.addr, t.be, core_rdata & be_mask(t.be), t.exp & be_mask(t.be)));
          end
        end else if (t.we && !t.exp_err && WT != 0) begin
          // write-through: the store must already be in memory
          if ((rd_word(mem, t.addr) & be_mask(t.be)) !== (rd_word(ref_mem, t.addr) & be_mask(t.be))) begin
            tb_error("TB", $sformatf("write-through store 0x%08x not in memory when it responded",
                                     t.addr));
          end
        end
      end
    end
  end

  // ---------------- stimulus helpers ----------------
  logic [31:0] seq_addr;
  int          seq_left;

  function automatic logic [3:0] rand_be();
    unique case ($urandom_range(6, 0))
      0, 1, 2: return 4'b1111;
      3:       return 4'b0011 << (2 * $urandom_range(1, 0));
      default: return 4'b0001 << $urandom_range(3, 0);
    endcase
  endfunction

  function automatic logic [31:0] rand_addr();
    int r;
    if (seq_left > 0) begin
      seq_left--;
      seq_addr += 4;
      if (seq_addr < Window) return seq_addr;
    end
    r = $urandom_range(99, 0);
    if (r < 5)  return MmioBase + ($urandom_range(63, 0) << 2);
    if (r < 7)  return ErrLine + ($urandom_range(LINE / 4 - 1, 0) << 2);
    if (r < 32) begin  // start a sequential run
      seq_left = $urandom_range(15, 3);
      seq_addr = $urandom_range(Window / 4 - 1, 0) << 2;
      return seq_addr;
    end
    return $urandom_range(Window / 4 - 1, 0) << 2;
  endfunction

  // Backing memory == reference over the whole cacheable window (after a clean)
  task automatic check_memory_coherent(string when);
    int bad = 0;
    for (logic [31:0] a = 0; a < Window; a += 4) begin
      if (rd_word(mem, a) !== rd_word(ref_mem, a)) begin
        if (bad < 5) tb_error("TB", $sformatf("%s: memory 0x%08x = 0x%08x, reference 0x%08x",
                                              when, a, rd_word(mem, a), rd_word(ref_mem, a)));
        bad++;
      end
    end
  endtask

  // All stimulus is driven and sampled at the falling edge (plus #1 for combinational settling):
  // DUT outputs are stable mid-cycle and the handshake completes at the following rising edge.
  task automatic do_maintenance();
    while (outstanding.size() != 0) @(negedge clk);
    if (RO) begin
      // Change memory behind the read-only cache (and prefetcher); visible after invalidation.
      logic [31:0] a;
      a = $urandom_range(Window / 4 - 1, 0) << 2;
      for (int b = 0; b < 4; b++) begin
        mem[a + b]     = 8'($urandom);
        ref_mem[a + b] = mem[a + b];
      end
    end
    maint_req = 1'b1;
    #1;
    while (!maint_done) begin
      @(negedge clk);
      #1;
    end
    @(negedge clk);
    maint_req = 1'b0;
    n_maint++;
    if (!RO) check_memory_coherent("after clean");
  endtask

  task automatic pulse_reset();
    rst_n = 1'b0;
    core_req = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    // the in-flight request is gone, and so is every dirty line: memory is the truth now
    outstanding.delete();
    ref_mem.delete();
    foreach (mem[a]) ref_mem[a] = mem[a];
    n_resets++;
    @(negedge clk);
  endtask

  initial begin
    bit arm_reset = 0;
    core_req  = 1'b0;
    hold      = 1'b0;
    maint_req = 1'b0;
    seq_left  = 0;
    #1 rst_n = 1'b0;
    repeat (3) @(posedge clk);
    #1 rst_n = 1'b1;
    @(negedge clk);

    for (int i = 0; i < TXNS; i++) begin
      txn_t t;
      if ($urandom_range(999, 0) < 3) do_maintenance();
      if ($urandom_range(999, 0) < 2) arm_reset = 1;
      if ($urandom_range(99, 0) < 3) begin
        hold = 1'b1;
        repeat ($urandom_range(4, 1)) @(negedge clk);
        hold = 1'b0;
      end

      t.addr    = rand_addr();
      t.we      = RO ? 1'b0 : ($urandom_range(99, 0) < 40);
      t.be      = t.we ? rand_be() : 4'b1111;
      t.exp_err = ((t.addr >> OffW) == (ErrLine >> OffW));

      core_req   = 1'b1;
      core_addr  = t.addr;
      core_we    = t.we;
      core_be    = t.be;
      core_wdata = $urandom;
      #1;
      while (!core_gnt) begin
        @(negedge clk);
        #1;
      end
      // accepted at the next rising edge: update the reference in program order first
      if (t.we && !t.exp_err) begin
        for (int b = 0; b < 4; b++) if (t.be[b]) ref_mem[t.addr + b] = core_wdata[8*b +: 8];
        n_stores++;
      end else if (!t.we) begin
        t.exp = rd_word(ref_mem, t.addr);
        n_loads++;
      end
      if (t.exp_err) n_err++;
      if (t.addr >= MmioBase) n_bypass++;
      outstanding.push_back(t);
      @(negedge clk);
      core_req = 1'b0;

      // Reset in the middle of a refill or dirty write-back
      if (arm_reset) begin
        for (int w = 0; w < 4; w++) begin
          if (dut.dv_refilling || dut.dv_evicting) begin
            pulse_reset();
            arm_reset = 0;
            break;
          end
          @(negedge clk);
        end
      end

      repeat ($urandom_range(3, 0)) @(negedge clk);
    end

    while (outstanding.size() != 0) @(negedge clk);
    if (!RO) do_maintenance();  // final clean + full memory comparison

    $display("[UNIT] cache %0dx%0dx%0dB %s%s%s repl=%0d: %0d txns (%0d loads, %0d stores, %0d uncached, %0d error-line), %0d hits, %0d misses, %0d write-backs, %0d maintenance ops, %0d resets mid-refill",
             SETS, WAYS, LINE, str_sel(RO != 0, "RO", "RW"), str_sel(WT != 0, " write-through", ""),
             str_sel(UsePf, " +prefetch", ""), REPL, n_done, n_loads, n_stores, n_bypass, n_err,
             n_hits, n_misses, n_wb, n_maint, n_resets);
    begin
      string cov_file = "cov.txt";
      int    b_reset;
      void'($value$plusargs("cov_file=%s", cov_file));
      b_reset = cov_register(str_sel(RO != 0, "icache", "dcache"), "reset_during_refill");
      repeat (n_resets) cov_hit(b_reset);
      cov_report(cov_file);
    end
    if (error_count == 0) $display("[TB] TEST PASSED");
    else                  $display("[TB] TEST FAILED");
    $finish;
  end

  // Watchdog
  initial begin
    #(64'd10 * TXNS * 200);
    $display("[TB] TIMEOUT");
    $display("[TB] TEST FAILED");
    $finish;
  end

endmodule
