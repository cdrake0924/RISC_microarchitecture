// Copyright 2026 RISC_microarchitecture contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Micro-architecture extension package
 *
 * Shared types and constants for the Ibex extensions in this repository:
 *   - branch prediction: direction predictors, return address stack, indirect-jump BTB
 *     (ibex_bp_dynamic, integrated in ibex_if_stage / ibex_id_stage / ibex_controller)
 *   - L1 instruction / data caches and the I-side next-line prefetcher (ibex_l1_cache,
 *     ibex_l1_prefetch, ibex_cc_top)
 *   - extended hardware performance monitor (HPM) event map (ibex_cs_registers)
 */
package ibex_uarch_pkg;

  //////////////////////////////
  // Branch prediction        //
  //////////////////////////////

  // Direction-prediction policy for conditional branches. Targets of direct branches/jumps are
  // decoded from the fetched instruction in IF; register-indirect jumps (JALR) use the return
  // address stack and the BTB (independent parameters, see ibex_bp_dynamic).
  typedef enum logic [2:0] {
    BpNone       = 3'd0,  // No prediction: branches implicitly not-taken, jumps resolved in ID/EX
                          // (upstream Ibex default, BranchPredictor = 0)
    BpStatic     = 3'd1,  // BTFN: backward taken / forward not-taken (upstream ibex_branch_predict)
    BpOneBit     = 3'd2,  // PC-indexed table of 1-bit "last outcome" entries
    BpBimodal    = 3'd3,  // PC-indexed table of 2-bit saturating counters
    BpGshare     = 3'd4,  // (PC xor global history)-indexed 2-bit counters
    BpTournament = 3'd5   // bimodal + gshare, per-PC 2-bit chooser selects the component
  } bp_mode_e;

  // Width of the pattern-history-table indices carried with each instruction.
  localparam int unsigned BP_IDX_W = 12;  // supports tables of up to 4096 entries

  // Prediction metadata that travels with each instruction from IF to ID/EX (skid buffer and IF/ID
  // register). It lets the resolving instruction train exactly the entries that produced its
  // prediction and lets ID/EX check a predicted register-indirect target.
  typedef struct packed {
    logic [BP_IDX_W-1:0] idx;       // direction table index (gshare index in tournament mode)
    logic [BP_IDX_W-1:0] idx_bim;   // tournament: bimodal component index
    logic                pred_bim;  // tournament: bimodal component prediction
    logic                pred_gsh;  // tournament: gshare component prediction
    logic                src_ras;   // taken prediction came from the return address stack
    logic                src_btb;   // taken prediction came from the indirect-jump BTB
    logic [31:0]         target;    // predicted target (checked in ID/EX for JALR)
  } bp_meta_t;

  // Conditional-branch resolution (ID/EX -> predictor), one pulse per branch
  typedef struct packed {
    logic     valid;
    logic     taken;
    bp_meta_t meta;
  } bp_cond_upd_t;

  // Jump execution (ID/EX -> predictor): JAL/JALR, used for the RAS and BTB
  typedef struct packed {
    logic        valid;
    logic        push;      // call: rd is a link register (x1/x5)
    logic        pop;       // return: JALR with rs1 a link register (RISC-V RAS hint table)
    logic        indirect;  // JALR (register-indirect) other than a pure return
    logic [31:0] pc;
    logic [31:0] link;      // return address (pc + 2/4)
    logic [31:0] target;    // actual target
  } bp_jump_upd_t;

  // Branch-prediction performance events (one pulse each, from ID/EX)
  typedef struct packed {
    logic br_mispred;    // conditional-branch direction mispredict
    logic br_mispred_t;  // ... predicted taken, was not taken (flush of the predicted path)
    logic jalr;          // register-indirect jump executed
    logic ras_pred;      // ... predicted from the return address stack
    logic btb_pred;      // ... predicted from the BTB
    logic jalr_mispred;  // ... predicted with a wrong target (redirect from ID/EX)
  } bp_perf_t;

  // 2-bit saturating counter encoding
  localparam logic [1:0] CNT_STRONG_NT = 2'b00;
  localparam logic [1:0] CNT_WEAK_NT   = 2'b01;
  localparam logic [1:0] CNT_WEAK_T    = 2'b10;
  localparam logic [1:0] CNT_STRONG_T  = 2'b11;

  //////////////////////////////
  // L1 caches                //
  //////////////////////////////

  typedef enum logic [1:0] {
    ReplPlru   = 2'd0,  // tree pseudo-LRU (identical to true LRU for 2 ways)
    ReplRandom = 2'd1,  // free-running LFSR
    ReplFifo   = 2'd2   // per-set round-robin pointer
  } repl_policy_e;

  //////////////////////////////
  // Performance monitoring   //
  //////////////////////////////

  // Events generated outside ibex_core (L1 caches and prefetcher in ibex_cc_top), fed into the
  // core's HPM counters through ibex_top.hpm_ext_event_i.
  typedef enum int unsigned {
    ExtEvIcAccess    = 0,  // I-cache lookup (one per granted fetch request)
    ExtEvIcMiss      = 1,  // I-cache miss (line refill started)
    ExtEvIcPfIssue   = 2,  // next-line prefetch started
    ExtEvIcPfHit     = 3,  // I-cache refill served by the prefetch buffer
    ExtEvDcAccess    = 4,  // D-cache lookup (cacheable load/store)
    ExtEvDcMiss      = 5,  // D-cache miss
    ExtEvDcWriteback = 6,  // dirty line written back to memory (eviction or clean)
    ExtEvDcBypass    = 7   // uncached (MMIO) data access
  } hpm_ext_event_e;

  localparam int unsigned HPM_EXT_EVENTS = 8;

  // mhpmcounter index of each event. Counters 3..12 are the upstream Ibex events; 13+ are added by
  // this project. Keep sw/common/perf.h and docs/performance_counters.md in sync with this table.
  localparam int unsigned HPM_IDX_DSIDE_WAIT   = 3;
  localparam int unsigned HPM_IDX_ISIDE_WAIT   = 4;
  localparam int unsigned HPM_IDX_LOAD         = 5;
  localparam int unsigned HPM_IDX_STORE        = 6;
  localparam int unsigned HPM_IDX_JUMP         = 7;
  localparam int unsigned HPM_IDX_BRANCH       = 8;
  localparam int unsigned HPM_IDX_BRANCH_TAKEN = 9;
  localparam int unsigned HPM_IDX_COMPRESSED   = 10;
  localparam int unsigned HPM_IDX_MUL_WAIT     = 11;
  localparam int unsigned HPM_IDX_DIV_WAIT     = 12;
  localparam int unsigned HPM_IDX_BP_BASE      = 13;  // 13..18: bp_perf_t fields, MSB first
  localparam int unsigned HPM_BP_EVENTS        = $bits(bp_perf_t);
  localparam int unsigned HPM_IDX_EXT_BASE     = HPM_IDX_BP_BASE + HPM_BP_EVENTS;  // 19..26

  // Number of mhpmcounters needed to expose every event above (counters 3..26).
  localparam int unsigned HPM_NUM_COUNTERS = HPM_IDX_EXT_BASE + HPM_EXT_EVENTS - 3;

endpackage
