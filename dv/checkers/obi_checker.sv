// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Protocol assertions for an Ibex / OBI request-grant, response-valid interface
 *
 * Instantiated on all four buses of the core complex (core<->cache and cache<->memory, instruction
 * and data), so a cache that corrupts the handshake is caught at the interface where it happens.
 *
 *   ObiReqHeldUntilGnt   an ungranted request stays asserted ...
 *   ObiAttrStable        ... with stable address and write attributes
 *   ObiRvalidExpected    a response only arrives while a granted request is outstanding
 *   ObiMaxOutstanding    no more than MaxOutstanding requests in flight
 *   ObiAddrKnown         the address is never X while requesting
 */

`include "uarch_assert.svh"

module obi_checker #(
  parameter string       Name           = "obi",
  parameter int unsigned MaxOutstanding = 2
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        req_i,
  input  logic        gnt_i,
  input  logic [31:0] addr_i,
  input  logic        we_i,
  input  logic [3:0]  be_i,
  input  logic [31:0] wdata_i,
  input  logic        rvalid_i,

  output logic        stall_o,         // coverage: request not granted this cycle
  output logic [3:0]  outstanding_o    // coverage: requests in flight
);

  int unsigned outstanding_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      outstanding_q <= 0;
    end else begin
      outstanding_q <= outstanding_q + ((req_i && gnt_i) ? 1 : 0) - (rvalid_i ? 1 : 0);
    end
  end

  assign stall_o       = req_i & ~gnt_i;
  assign outstanding_o = 4'(outstanding_q);

  `UARCH_ASSERT(ObiReqHeldUntilGnt, req_i && !gnt_i |=> req_i)
  `UARCH_ASSERT(ObiAttrStable, req_i && !gnt_i |=>
      $stable(addr_i) && $stable(we_i) && (!we_i || ($stable(be_i) && $stable(wdata_i))))
  `UARCH_ASSERT(ObiRvalidExpected, rvalid_i |-> outstanding_q > 0)
  `UARCH_ASSERT(ObiMaxOutstanding, outstanding_q <= MaxOutstanding)
  `UARCH_ASSERT(ObiAddrKnown, req_i |-> !$isunknown(addr_i))

endmodule
