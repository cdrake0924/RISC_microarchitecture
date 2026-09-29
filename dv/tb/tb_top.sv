// Copyright 2017 Embecosm Limited <www.embecosm.com>
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
 * Top-level testbench for the extended Ibex core complex
 *
 * Adapted from the CV32E40P example testbench (example_tb/core/tb_top.sv). Pure SystemVerilog
 * (no C++ harness): built with `verilator --binary --timing`.
 *
 * Plusargs
 *   +firmware=<file.hex>  program image (objcopy -O verilog), required
 *   +maxcycles=<n>        abort after n cycles (default 20,000,000)
 *   +mem_latency=<n>      main-memory latency in cycles (default 10), see tb_mem
 *   +gnt_stall=<pct>      random grant back-pressure on both memory ports
 *   +rvalid_jitter=<n>    random extra response latency 0..n cycles
 *   +cov_file=<path>      functional coverage output (default cov.txt)
 *   +trace                write an instruction trace (trace_core_00000000.log)
 *   +verbose              log every memory transaction
 *
 * Micro-architecture parameters are overridden at build time (verilator -G...), see sim/Makefile.
 */
module tb_top #(
  parameter int BP_MODE  = 5,    // 0 none, 1 static BTFN, 2 1-bit, 3 bimodal, 4 gshare, 5 tournament
  parameter int BP_PHT   = 512,  // direction table entries
  parameter int BP_GHR   = 8,    // global history bits (gshare / tournament)
  parameter int BP_RAS   = 8,    // return address stack entries (0 = off)
  parameter int BP_BTB   = 16,   // indirect-jump BTB entries (0 = off)
  parameter int IC_EN    = 1,
  parameter int IC_SETS  = 64,
  parameter int IC_WAYS  = 2,
  parameter int IC_LINE  = 16,   // bytes
  parameter int IC_REPL  = 0,    // 0 PLRU, 1 random, 2 FIFO
  parameter int IC_PF    = 1,    // next-line prefetcher
  parameter int DC_EN    = 1,
  parameter int DC_SETS  = 64,
  parameter int DC_WAYS  = 2,
  parameter int DC_LINE  = 16,
  parameter int DC_REPL  = 0,
  parameter int DC_WT    = 0,    // 0 write-back/allocate, 1 write-through/no-allocate
  parameter int RAM_AW   = 20    // 1 MiB of RAM
);
  import ibex_uarch_pkg::*;

  localparam time ClkHalfPeriod = 5ns;
  localparam int  ResetCycles   = 4;

  logic        clk   = 1'b1;
  logic        rst_n = 1'b1;  // see reset_gen
  logic        exit_valid;
  logic [31:0] exit_value;
  longint unsigned cycles;

  //////////////////////
  // Clock and reset  //
  //////////////////////

  initial begin : clock_gen
    forever #(ClkHalfPeriod) clk = ~clk;
  end

  // Reset must have a real falling edge: ibex_top gates the core clock while the core is idle, so
  // asynchronously-reset core flops only reset on negedge rst_ni. (A 4-state simulator sees X->0 at
  // time 0 as that edge; Verilator is 2-state, so the edge is created explicitly.)
  initial begin : reset_gen
    #1 rst_n = 1'b0;
    repeat (ResetCycles) @(posedge clk);
    #1 rst_n = 1'b1;
  end

  initial $timeformat(-9, 0, "ns", 12);

  //////////////////////
  // DUT subsystem    //
  //////////////////////

  ibex_tb_subsystem #(
    .RamAddrWidth(RAM_AW),
    .BootAddr    (32'h0000_0000),
    .BpMode      (bp_mode_e'(BP_MODE)),
    .BpPhtEntries(BP_PHT),
    .BpGhrBits   (BP_GHR),
    .BpRasDepth  (BP_RAS),
    .BpBtbEntries(BP_BTB),
    .ICacheEn    (IC_EN != 0),
    .ICachePf    (IC_PF != 0),
    .ICacheSets  (IC_SETS),
    .ICacheWays  (IC_WAYS),
    .ICacheLine  (IC_LINE),
    .ICacheRepl  (repl_policy_e'(IC_REPL)),
    .DCacheEn    (DC_EN != 0),
    .DCacheSets  (DC_SETS),
    .DCacheWays  (DC_WAYS),
    .DCacheLine  (DC_LINE),
    .DCacheRepl  (repl_policy_e'(DC_REPL)),
    .DCacheWt    (DC_WT != 0)
  ) u_sys (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .fetch_enable_i(1'b1),
    .exit_valid_o  (exit_valid),
    .exit_value_o  (exit_value)
  );

  //////////////////////
  // Program loading  //
  //////////////////////

  string cov_file = "cov.txt";
  longint unsigned max_cycles = 20_000_000;

  initial begin : load_prog
    string firmware;
    int    fd;
    void'($value$plusargs("maxcycles=%d", max_cycles));
    void'($value$plusargs("cov_file=%s", cov_file));
    if (!$value$plusargs("firmware=%s", firmware)) begin
      $display("[TB] ERROR: no firmware specified (+firmware=<file.hex>)");
      $display("[TB] TEST FAILED");
      $finish;
    end
    fd = $fopen(firmware, "r");
    if (fd == 0) begin
      $display("[TB] ERROR: cannot open firmware file '%s'", firmware);
      $display("[TB] TEST FAILED");
      $finish;
    end
    $fclose(fd);
    $display("[TB] loading %s", firmware);
    $readmemh(firmware, u_sys.u_mem.mem);
    $readmemh(firmware, u_sys.u_mem_sb.ref_mem);
    print_config();
  end

`ifdef TB_WAVES
  initial begin
    if ($test$plusargs("waves")) begin
      $dumpfile("waves.fst");
      $dumpvars(0, tb_top);
    end
  end
`endif

  //////////////////////
  // Test control     //
  //////////////////////

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycles <= 0;
    end else begin
      cycles <= cycles + 1;
      if (cycles >= max_cycles) begin
        $display("[TB] TIMEOUT after %0d cycles", cycles);
        end_of_test(1'b0);
      end
      if (exit_valid) begin
        end_of_test(exit_value == 0);
      end
    end
  end

  task automatic end_of_test(bit sw_pass);
    bit pass;
    pass = sw_pass && (tb_pkg::error_count == 0);
    $display("");
    $display("[TB] software exit value: %0d, checker errors: %0d", exit_value,
             tb_pkg::error_count);
    $display("[TB] HPM counters at exit (frozen at the end of the last software-measured region):");
    print_hpm();
    tb_pkg::cov_report(cov_file);
    $display("[TB] simulated %0d cycles", cycles);
    if (pass) $display("[TB] TEST PASSED");
    else      $display("[TB] TEST FAILED");
    $finish;
  endtask

  // Whole-program counter values read straight from the CSR file (software additionally reports
  // counters for its measured region of interest).
  task automatic print_hpm();
    string line;
    line = $sformatf("[TB] HPM mcycle=%0d minstret=%0d",
        u_sys.dut.u_ibex_top.u_ibex_core.cs_registers_i.mhpmcounter[0],
        u_sys.dut.u_ibex_top.u_ibex_core.cs_registers_i.mhpmcounter[2]);
    for (int i = 3; i < 3 + HPM_NUM_COUNTERS; i++) begin
      line = {line, $sformatf(" hpm%0d=%0d", i,
          u_sys.dut.u_ibex_top.u_ibex_core.cs_registers_i.mhpmcounter[i])};
    end
    $display("%s", line);
  endtask

  task automatic print_config();
    string bp_name[6] = '{"none", "static", "1-bit", "bimodal", "gshare", "tournament"};
    string repl_name[3] = '{"plru", "random", "fifo"};
    $display("[TB] config: bp=%s pht=%0d ghr=%0d ras=%0d btb=%0d | icache=%s %0dx%0dx%0dB %s%s | dcache=%s %0dx%0dx%0dB %s %s",
             bp_name[BP_MODE], BP_PHT, BP_GHR, BP_RAS, BP_BTB,
             tb_pkg::str_sel(IC_EN != 0, "on", "off"), IC_SETS, IC_WAYS, IC_LINE, repl_name[IC_REPL],
             tb_pkg::str_sel(IC_PF != 0, " +prefetch", ""),
             tb_pkg::str_sel(DC_EN != 0, "on", "off"), DC_SETS, DC_WAYS, DC_LINE, repl_name[DC_REPL],
             tb_pkg::str_sel(DC_WT != 0, "write-through", "write-back"));
  endtask

endmodule
