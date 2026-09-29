// Copyright 2017 Embecosm Limited <www.embecosm.com>
// Copyright 2018 Robert Balas <balasr@student.ethz.ch>
// Copyright 2020 OpenHW Group / Silicon Labs, Inc.
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
 * Main memory and virtual peripherals for the Ibex core-complex testbench
 *
 * Adapted from the CV32E40P example testbench (example_tb/core/mm_ram.sv, dp_ram.sv,
 * riscv_gnt_stall.sv, riscv_rvalid_stall.sv). Changes for this project:
 *   - Verilator-5 compatible (timing, queues, $urandom) instead of Questa-only stall generators
 *   - configurable pipelined memory latency so cache effects are visible (+mem_latency=N)
 *   - random grant stalls and response jitter for protocol stress (+gnt_stall=P, +rvalid_jitter=N)
 *   - bus errors instead of $fatal for unmapped addresses, so the core's fault path is exercised
 *   - AMO shim and PULP-specific interrupt generator removed (Ibex has no A extension)
 *
 * Memory map (data port; the instruction port only sees RAM)
 *   0x0000_0000 - RAM_BYTES-1  RAM, latency +mem_latency (default 10), pipelined, in-order
 *   0x1000_0000 (W)            putchar
 *   0x1500_0000 (W)            timer IRQ enable (bit 7 = mtip)
 *   0x1500_0004 (W)            timer count-down value; raises irq_timer when it reaches 0
 *   0x2000_0000 (W)            123456789 = tests passed, 1 = tests failed  (CV32E40P convention)
 *   0x2000_0004 (W)            exit(value)
 *   0x2000_0008 / 0x2000_000C  signature begin / end
 *   0x2000_0010 (W)            dump signature and exit(0)
 *   0x2000_0100 (R)            SoC configuration word (ConfigWord parameter), so software can
 *                              adapt its expectations to the micro-architecture under test
 *   anything else              bus error response
 */
module tb_mem #(
  parameter int unsigned RamAddrWidth = 20,  // 1 MiB
  parameter logic [31:0] ConfigWord   = '0   // value of the read-only config register
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction port
  input  logic        instr_req_i,
  output logic        instr_gnt_o,
  input  logic [31:0] instr_addr_i,
  output logic        instr_rvalid_o,
  output logic [31:0] instr_rdata_o,
  output logic        instr_err_o,

  // Data port
  input  logic        data_req_i,
  output logic        data_gnt_o,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_addr_i,
  input  logic [31:0] data_wdata_i,
  output logic        data_rvalid_o,
  output logic [31:0] data_rdata_o,
  output logic        data_err_o,

  // Interrupts
  output logic        irq_timer_o,

  // Test status
  output logic        exit_valid_o,
  output logic [31:0] exit_value_o
);

  localparam int unsigned RamBytes = 2 ** RamAddrWidth;

  localparam logic [31:0] AddrPutchar    = 32'h1000_0000;
  localparam logic [31:0] AddrTimerCtrl  = 32'h1500_0000;
  localparam logic [31:0] AddrTimerCnt   = 32'h1500_0004;
  localparam logic [31:0] AddrTestStatus = 32'h2000_0000;
  localparam logic [31:0] AddrExit       = 32'h2000_0004;
  localparam logic [31:0] AddrSigBegin   = 32'h2000_0008;
  localparam logic [31:0] AddrSigEnd     = 32'h2000_000C;
  localparam logic [31:0] AddrSigDump    = 32'h2000_0010;
  localparam logic [31:0] AddrConfig     = 32'h2000_0100;

  // Byte-addressed backing store, loaded by tb_top with $readmemh (objcopy -O verilog format)
  logic [7:0] mem [RamBytes];

  //////////////////////
  // Runtime knobs    //
  //////////////////////

  int unsigned mem_latency   = 10;  // cycles from grant to response for RAM
  int unsigned gnt_stall_pct = 0;   // % of cycles a request is not granted
  int unsigned rvalid_jitter = 0;   // extra random 0..N cycles of response latency
  bit          verbose       = 0;

  initial begin
    void'($value$plusargs("mem_latency=%d", mem_latency));
    void'($value$plusargs("gnt_stall=%d", gnt_stall_pct));
    void'($value$plusargs("rvalid_jitter=%d", rvalid_jitter));
    verbose = $test$plusargs("verbose");
    if (mem_latency < 1) mem_latency = 1;
    $display("[TB_MEM] RAM %0d KiB, latency %0d cycles, gnt stall %0d%%, rvalid jitter %0d",
             RamBytes / 1024, mem_latency, gnt_stall_pct, rvalid_jitter);
  end

  longint unsigned cycle_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cycle_q <= 0;
    else         cycle_q <= cycle_q + 1;
  end

  //////////////////////
  // Helpers          //
  //////////////////////

  function automatic bit in_ram(logic [31:0] addr);
    return addr < RamBytes;
  endfunction

  function automatic logic [31:0] ram_read(logic [31:0] addr);
    logic [31:0] a;
    a = {addr[31:2], 2'b00};
    return {mem[a+3], mem[a+2], mem[a+1], mem[a]};
  endfunction

  task automatic ram_write(logic [31:0] addr, logic [31:0] wdata, logic [3:0] be);
    logic [31:0] a;
    a = {addr[31:2], 2'b00};
    for (int b = 0; b < 4; b++) begin
      if (be[b]) mem[a+b] = wdata[8*b +: 8];
    end
  endtask

  function automatic int unsigned resp_delay(bit is_ram);
    int unsigned d;
    d = is_ram ? mem_latency : 1;
    if (rvalid_jitter > 0) d += $urandom_range(rvalid_jitter, 0);
    return d;
  endfunction

  typedef struct {
    longint unsigned due;
    logic [31:0]     rdata;
    logic            err;
  } resp_t;

  //////////////////////
  // Grant stalls     //
  //////////////////////

  // Registered random stall decision, so grants never depend combinationally on anything but req.
  logic instr_stall_q, data_stall_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_stall_q <= 1'b0;
      data_stall_q  <= 1'b0;
    end else begin
      instr_stall_q <= (gnt_stall_pct > 0) && ($urandom_range(99, 0) < gnt_stall_pct);
      data_stall_q  <= (gnt_stall_pct > 0) && ($urandom_range(99, 0) < gnt_stall_pct);
    end
  end

  assign instr_gnt_o = instr_req_i & ~instr_stall_q;
  assign data_gnt_o  = data_req_i  & ~data_stall_q;

  //////////////////////////////////
  // Request / response handling  //
  //////////////////////////////////

  // Both ports are served from one process so a store and an instruction fetch to the same address
  // in the same cycle resolve deterministically (the data port is processed first).
  resp_t instr_q[$];
  resp_t data_q[$];

  logic [31:0] sig_begin_q, sig_end_q;
  logic        timer_irq_en_q;
  logic [31:0] timer_cnt_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_rvalid_o <= 1'b0;
      instr_rdata_o  <= '0;
      instr_err_o    <= 1'b0;
      instr_q.delete();
      data_rvalid_o  <= 1'b0;
      data_rdata_o   <= '0;
      data_err_o     <= 1'b0;
      exit_valid_o   <= 1'b0;
      exit_value_o   <= '0;
      sig_begin_q    <= '0;
      sig_end_q      <= '0;
      timer_irq_en_q <= 1'b0;
      timer_cnt_q    <= '0;
      irq_timer_o    <= 1'b0;
      data_q.delete();
    end else begin
      // Timer: count down, raise the (level) interrupt at zero until re-armed
      if (timer_cnt_q > 0) begin
        timer_cnt_q <= timer_cnt_q - 1;
        if (timer_cnt_q == 1 && timer_irq_en_q) irq_timer_o <= 1'b1;
      end

      if (data_req_i && data_gnt_o) begin
        resp_t r;
        r.err   = 1'b0;
        r.rdata = '0;

        if (in_ram(data_addr_i)) begin
          r.due = cycle_q + resp_delay(1'b1);
          if (data_we_i) begin
            ram_write(data_addr_i, data_wdata_i, data_be_i);
            if (verbose) $display("[TB_MEM] write 0x%08x = 0x%08x be=%b", data_addr_i,
                                  data_wdata_i, data_be_i);
          end else begin
            r.rdata = ram_read(data_addr_i);
          end
        end else begin
          r.due = cycle_q + resp_delay(1'b0);
          if (data_we_i) begin
            unique case (data_addr_i)
              AddrPutchar: begin
                $write("%c", data_wdata_i[7:0]);
                $fflush();
              end
              AddrTimerCtrl: timer_irq_en_q <= data_wdata_i[7];
              AddrTimerCnt: begin
                timer_cnt_q <= data_wdata_i;
                irq_timer_o <= 1'b0;
              end
              AddrTestStatus: begin
                if (data_wdata_i == 32'd123456789) begin
                  exit_valid_o <= 1'b1;
                  exit_value_o <= 32'd0;
                end else if (data_wdata_i == 32'd1) begin
                  exit_valid_o <= 1'b1;
                  exit_value_o <= 32'd1;
                end
              end
              AddrExit: begin
                exit_valid_o <= 1'b1;
                exit_value_o <= data_wdata_i;
              end
              AddrSigBegin: sig_begin_q <= data_wdata_i;
              AddrSigEnd:   sig_end_q   <= data_wdata_i;
              AddrSigDump: begin
                dump_signature();
                exit_valid_o <= 1'b1;
                exit_value_o <= 32'd0;
              end
              default: begin
                r.err = 1'b1;
                if (verbose) $display("[TB_MEM] bus error: write to 0x%08x", data_addr_i);
              end
            endcase
          end else if (data_addr_i == AddrConfig) begin
            r.rdata = ConfigWord;
          end else begin
            r.err = 1'b1;
            if (verbose) $display("[TB_MEM] bus error: read from 0x%08x", data_addr_i);
          end
        end
        data_q.push_back(r);
      end

      // ---- instruction port (after the data port, see above) ----
      if (instr_req_i && instr_gnt_o) begin
        resp_t r;
        r.due   = cycle_q + resp_delay(1'b1);
        r.err   = !in_ram(instr_addr_i);
        r.rdata = r.err ? 32'h0 : ram_read(instr_addr_i);
        instr_q.push_back(r);
      end

      // ---- responses: in order, at most one per port per cycle ----
      if (data_q.size() > 0 && data_q[0].due <= cycle_q + 1) begin
        data_rvalid_o <= 1'b1;
        data_rdata_o  <= data_q[0].rdata;
        data_err_o    <= data_q[0].err;
        void'(data_q.pop_front());
      end else begin
        data_rvalid_o <= 1'b0;
        data_err_o    <= 1'b0;
      end

      if (instr_q.size() > 0 && instr_q[0].due <= cycle_q + 1) begin
        instr_rvalid_o <= 1'b1;
        instr_rdata_o  <= instr_q[0].rdata;
        instr_err_o    <= instr_q[0].err;
        void'(instr_q.pop_front());
      end else begin
        instr_rvalid_o <= 1'b0;
        instr_err_o    <= 1'b0;
      end
    end
  end

  // Signature dump for compliance-style tests (the D-cache is cleaned by FENCE.I in sw exit code
  // before the dump is requested, so memory is coherent here).
  task automatic dump_signature();
    string sig_file;
    int    fd;
    fd = 0;
    if ($value$plusargs("signature=%s", sig_file)) fd = $fopen(sig_file, "w");
    for (logic [31:0] a = sig_begin_q; a < sig_end_q; a += 4) begin
      if (fd != 0) $fdisplay(fd, "%08x", ram_read(a));
      else         $display("%08x", ram_read(a));
    end
    if (fd != 0) $fclose(fd);
  endtask

  // Backdoor accessors used by tb_top for program loading and end-of-test reporting
  function automatic logic [31:0] backdoor_read_word(logic [31:0] addr);
    return ram_read(addr);
  endfunction

endmodule
