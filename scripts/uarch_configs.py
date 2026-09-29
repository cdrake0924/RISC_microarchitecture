# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Micro-architecture configurations shared by regress.py and evaluate.py.

Each configuration maps to Verilator -G overrides of dv/tb/tb_top.sv parameters:
  BP_MODE  0 none | 1 static BTFN | 2 1-bit | 3 bimodal | 4 gshare | 5 tournament
  BP_PHT   direction-table entries, BP_GHR history bits, BP_RAS / BP_BTB entries (0 = off)
  IC_* / DC_*  EN, SETS, WAYS, LINE (bytes), REPL (0 PLRU | 1 random | 2 FIFO),
  IC_PF    next-line prefetcher, DC_WT write-through (else write-back)
"""

BP_NAMES = {0: "none", 1: "static", 2: "1-bit", 3: "bimodal", 4: "gshare", 5: "tournament"}
REPL_NAMES = {0: "plru", 1: "random", 2: "fifo"}

DEFAULTS = dict(BP_MODE=5, BP_PHT=512, BP_GHR=8, BP_RAS=8, BP_BTB=16,
                IC_EN=1, IC_SETS=64, IC_WAYS=2, IC_LINE=16, IC_REPL=0, IC_PF=1,
                DC_EN=1, DC_SETS=64, DC_WAYS=2, DC_LINE=16, DC_REPL=0, DC_WT=0)


def cfg(**overrides):
    params = dict(DEFAULTS)
    params.update(overrides)
    return params


def gparams(params):
    return " ".join(f"-G{k}={v}" for k, v in sorted(params.items()))


def describe(params):
    p = params
    bp = BP_NAMES[p["BP_MODE"]]
    if p["BP_MODE"] >= 2:
        bp += f"/{p['BP_PHT']}" + (f"/h{p['BP_GHR']}" if p["BP_MODE"] >= 4 else "")
    if p["BP_MODE"] >= 1:
        if p["BP_RAS"]:
            bp += f"+RAS{p['BP_RAS']}"
        if p["BP_BTB"]:
            bp += f"+BTB{p['BP_BTB']}"
    ic = (f"{max(p['IC_SETS'] * p['IC_WAYS'] * p['IC_LINE'] // 1024, 1)}K {p['IC_WAYS']}w "
          f"{p['IC_LINE']}B{' +pf' if p['IC_PF'] else ''}" if p["IC_EN"] else "off")
    dc = (f"{max(p['DC_SETS'] * p['DC_WAYS'] * p['DC_LINE'] // 1024, 1)}K {p['DC_WAYS']}w "
          f"{p['DC_LINE']}B {'WT' if p['DC_WT'] else 'WB'}" if p["DC_EN"] else "off")
    return f"bp={bp} I$={ic} D$={dc}"


# ---------------------------------------------------------------------------------------------
# Configurations used by the regression (functional verification)
# ---------------------------------------------------------------------------------------------
REGRESS_CONFIGS = {
    # the architecture ladder
    "baseline": cfg(BP_MODE=0, IC_EN=0, DC_EN=0),
    "static":   cfg(BP_MODE=1, BP_RAS=0, BP_BTB=0, IC_EN=0, DC_EN=0),
    "bp_only":  cfg(IC_EN=0, DC_EN=0),
    "caches":   cfg(BP_MODE=0),
    "full":     cfg(),
    # verification-only corners: tiny tables force RAS overflow / BTB and PHT aliasing, tiny caches
    # force constant evictions, odd shapes exercise every policy, line size and write mode
    "tiny":     cfg(BP_MODE=2, BP_PHT=16, BP_RAS=2, BP_BTB=2, IC_SETS=4, IC_WAYS=1, IC_LINE=8,
                    DC_SETS=4, DC_WAYS=1, DC_LINE=8),
    "gshare_wt": cfg(BP_MODE=4, BP_PHT=64, BP_GHR=6, IC_PF=0, DC_WT=1),
    "fifo_4w":  cfg(BP_MODE=3, BP_PHT=64, IC_SETS=8, IC_WAYS=4, IC_LINE=32, IC_REPL=2,
                    DC_SETS=8, DC_WAYS=4, DC_LINE=32, DC_REPL=2),
    "rand_8w":  cfg(BP_MODE=4, BP_RAS=4, BP_BTB=4, IC_SETS=4, IC_WAYS=8, IC_LINE=64, IC_REPL=1,
                    DC_SETS=4, DC_WAYS=8, DC_LINE=64, DC_REPL=1, DC_WT=1),
    "dcache_only": cfg(BP_MODE=1, BP_RAS=0, BP_BTB=0, IC_EN=0),
}

# ---------------------------------------------------------------------------------------------
# Block-level (unit) testbench configurations: (testbench, name, -G overrides, seeds)
# ---------------------------------------------------------------------------------------------
UNIT_CONFIGS = [
    ("tb_l1_cache", "rw_2w_plru",   "-GSETS=16 -GWAYS=2 -GLINE=16 -GRO=0 -GREPL=0", 4),
    ("tb_l1_cache", "rw_dm",        "-GSETS=8 -GWAYS=1 -GLINE=8 -GRO=0 -GREPL=0", 4),
    ("tb_l1_cache", "rw_4w_fifo",   "-GSETS=4 -GWAYS=4 -GLINE=32 -GRO=0 -GREPL=2", 4),
    ("tb_l1_cache", "rw_8w_random", "-GSETS=2 -GWAYS=8 -GLINE=64 -GRO=0 -GREPL=1", 4),
    ("tb_l1_cache", "wt_2w",        "-GSETS=16 -GWAYS=2 -GLINE=16 -GRO=0 -GWT=1", 4),
    ("tb_l1_cache", "ro_2w_plru",   "-GSETS=16 -GWAYS=2 -GLINE=16 -GRO=1 -GREPL=0", 3),
    ("tb_l1_cache", "ro_4w_pf",     "-GSETS=8 -GWAYS=4 -GLINE=32 -GRO=1 -GPF=1", 4),
    ("tb_l1_cache", "ro_dm_pf",     "-GSETS=8 -GWAYS=1 -GLINE=8 -GRO=1 -GPF=1", 4),
    ("tb_bp",       "static",       "-GMODE=1 -GRAS=0 -GBTB=0", 1),
    ("tb_bp",       "onebit",       "-GMODE=2 -GPHT=256", 1),
    ("tb_bp",       "bimodal",      "-GMODE=3 -GPHT=256", 2),
    ("tb_bp",       "gshare",       "-GMODE=4 -GPHT=1024 -GGHR=10", 2),
    ("tb_bp",       "tournament",   "-GMODE=5 -GPHT=512 -GGHR=8 -GRAS=16 -GBTB=32", 2),
    ("tb_bp",       "small_tables", "-GMODE=4 -GPHT=64 -GGHR=4 -GRAS=2 -GBTB=2", 2),
]

# Random memory back-pressure applied in the "stress" suite
STRESS_PLUSARGS = "+gnt_stall=30 +rvalid_jitter=6"
