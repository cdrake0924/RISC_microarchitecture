// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Testbench-wide error accounting and coverage bookkeeping.
 *
 * Every checker reports through tb_error() so tb_top can fail the test on any mismatch, even if the
 * software itself reported success. Coverage bins are registered by name so the regression script
 * can merge them across tests (Verilator 5 does not support SystemVerilog covergroups, so functional
 * coverage is collected with explicit bins; see dv/coverage/uarch_coverage.sv).
 */
package tb_pkg;

  int unsigned error_count = 0;
  int unsigned max_errors  = 10;

  // String select. Note: `c ? "a" : "bb"` on two string *literals* is evaluated as a bit-vector
  // operation and zero-pads the shorter literal; routing through string-typed arguments avoids it.
  function automatic string str_sel(bit sel, string if_true, string if_false);
    return sel ? if_true : if_false;
  endfunction

  function automatic void tb_error(string who, string msg);
    error_count++;
    $display("[%s] ERROR: %s", who, msg);
    if (error_count >= max_errors) begin
      $display("[TB] too many errors (%0d), stopping", error_count);
      $finish;
    end
  endfunction

  ////////////////////////
  // Coverage bins      //
  ////////////////////////

  typedef struct {
    string           group;
    string           name;
    longint unsigned hits;
  } cov_bin_t;

  cov_bin_t cov_bins[$];

  // Register a bin and return its handle.
  function automatic int cov_register(string group, string name);
    cov_bin_t b;
    b.group = group;
    b.name  = name;
    b.hits  = 0;
    cov_bins.push_back(b);
    return cov_bins.size() - 1;
  endfunction

  function automatic void cov_hit(int id);
    cov_bins[id].hits++;
  endfunction

  // Print a per-group summary and write every bin to `file` (one "group.name hits" per line).
  function automatic void cov_report(string file);
    int fd;
    string groups[$];
    fd = 0;
    // (not a ?: expression: Verilator 5.020 emits invalid C++ for $fopen inside a conditional)
    if (file != "") fd = $fopen(file, "w");
    foreach (cov_bins[i]) begin
      bit seen = 0;
      foreach (groups[g]) if (groups[g] == cov_bins[i].group) seen = 1;
      if (!seen) groups.push_back(cov_bins[i].group);
      if (fd != 0) $fdisplay(fd, "%s.%s %0d", cov_bins[i].group, cov_bins[i].name, cov_bins[i].hits);
    end
    if (fd != 0) $fclose(fd);
    $display("[COV] functional coverage (this test):");
    foreach (groups[g]) begin
      int total = 0, hit = 0;
      string missing = "";
      foreach (cov_bins[i]) begin
        if (cov_bins[i].group != groups[g]) continue;
        total++;
        if (cov_bins[i].hits > 0) hit++;
        else missing = {missing, " ", cov_bins[i].name};
      end
      $display("[COV]   %-12s %3d/%-3d bins%s%s", groups[g], hit, total,
               (missing != "") ? "  missing:" : "", missing);
    end
  endfunction

endpackage
