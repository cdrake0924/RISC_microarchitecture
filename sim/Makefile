# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Verilator build/run flow for the extended Ibex core complex.
#
#   make build CONFIG=full                build the simulator for a named configuration
#   make run   CONFIG=full TEST=coremark  build software + simulator and run one program
#   make build CONFIG=my GPARAMS="-GBP_MODE=2 -GDC_WAYS=4"   ad-hoc configuration
#   make lint                             Verilator -Wall lint of the RTL
#
# Useful variables: PLUSARGS="+mem_latency=20 +trace", WAVES=1 (FST waveform support, +waves at
# run time), COV=1 (collect SVA cover points / line coverage into coverage.dat).

REPO     := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD    ?= $(REPO)/build
CONFIG   ?= full
SIMDIR   := $(BUILD)/sim/$(CONFIG)
SWDIR    := $(BUILD)/sw
JOBS     ?= 4

# ---- named configurations --------------------------------------------------------------------
# Defaults (dv/tb/tb_top.sv): tournament predictor + 8-entry RAS + 16-entry BTB, 2 KiB 2-way
# I-cache with next-line prefetcher, 2 KiB 2-way write-back D-cache.
# BP_MODE: 0 none, 1 static BTFN, 2 1-bit, 3 bimodal, 4 gshare, 5 tournament
# *_REPL : 0 PLRU, 1 random, 2 FIFO        DC_WT: 0 write-back, 1 write-through
CFG_baseline   := -GBP_MODE=0 -GIC_EN=0 -GDC_EN=0
CFG_bp_only    := -GIC_EN=0 -GDC_EN=0
CFG_caches     := -GBP_MODE=0
CFG_static     := -GBP_MODE=1 -GBP_RAS=0 -GBP_BTB=0
CFG_onebit     := -GBP_MODE=2
CFG_bimodal    := -GBP_MODE=3
CFG_gshare     := -GBP_MODE=4
CFG_tournament := -GBP_MODE=5
CFG_wt         := -GDC_WT=1
CFG_full       :=
GPARAMS        ?= $(CFG_$(CONFIG))

# ---- sources ---------------------------------------------------------------------------------
DV_FILES := \
  $(REPO)/dv/tb/tb_pkg.sv \
  $(REPO)/dv/checkers/obi_checker.sv \
  $(REPO)/dv/checkers/rvfi_pc_checker.sv \
  $(REPO)/dv/checkers/mem_scoreboard.sv \
  $(REPO)/dv/checkers/redirect_checker.sv \
  $(REPO)/dv/coverage/uarch_coverage.sv \
  $(REPO)/dv/tb/tb_mem.sv \
  $(REPO)/dv/tb/ibex_tb_subsystem.sv \
  $(REPO)/dv/tb/tb_top.sv

RTL_DEPS := $(shell sed -n 's#^\([a-z].*\.sv\)$$#$(REPO)/\1#p' $(REPO)/rtl/rtl_files.f) \
            $(wildcard $(REPO)/rtl/include/*.svh)

VERILATOR_FLAGS := --binary --timing --assert -j $(JOBS) \
  --top-module tb_top +define+RVFI \
  -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
  --x-assign fast --x-initial fast \
  -O3 --output-split 20000 \
  $(if $(WAVES),--trace-fst --trace-structs +define+TB_WAVES) \
  $(if $(COV),--coverage-user --coverage-line)

SIM_BIN := $(SIMDIR)/obj_dir/Vtb_top

.PHONY: build run lint clean print-gparams FORCE
build: $(SIM_BIN)

print-gparams:
	@echo "$(GPARAMS)"

# The parameter set is a build input: rewrite the stamp only when GPARAMS change
$(SIMDIR)/gparams.txt: FORCE
	@mkdir -p $(SIMDIR)
	@echo "$(GPARAMS)" | cmp -s - $@ || echo "$(GPARAMS)" > $@

$(SIM_BIN): $(RTL_DEPS) $(DV_FILES) $(REPO)/sim/Makefile $(SIMDIR)/gparams.txt
	@mkdir -p $(SIMDIR)
	@echo "[sim] building CONFIG=$(CONFIG): $(GPARAMS)"
	cd $(REPO) && verilator $(VERILATOR_FLAGS) $(GPARAMS) \
	  ibex/lint/verilator_waiver.vlt -f rtl/rtl_files.f $(DV_FILES) \
	  -Mdir $(SIMDIR)/obj_dir -o Vtb_top > $(SIMDIR)/build.log 2>&1 \
	  || (tail -40 $(SIMDIR)/build.log; exit 1)
	@echo "[sim] built $(SIM_BIN)"

TEST     ?= hello
PLUSARGS ?=
LOG      := $(SIMDIR)/$(TEST).log

run: build
	@$(MAKE) -s -C $(REPO)/sw $(TEST)
	@echo "[sim] running $(TEST) on CONFIG=$(CONFIG)"
	cd $(SIMDIR) && ./obj_dir/Vtb_top +firmware=$(SWDIR)/$(TEST).hex \
	  +cov_file=$(SIMDIR)/$(TEST).cov $(PLUSARGS) | tee $(LOG)
	@grep -q "TEST PASSED" $(LOG)

# ---- block-level (unit) testbenches ----------------------------------------------------------
#   make unit UNIT=tb_l1_cache UCONFIG=rw_2w UPARAMS="-GWAYS=2 -GRO=0" SEED=3
UNIT     ?= tb_l1_cache
UCONFIG  ?= default
UPARAMS  ?=
SEED     ?= 1
UNIT_DIR := $(BUILD)/unit/$(UNIT)/$(UCONFIG)
UNIT_BIN := $(UNIT_DIR)/obj_dir/V$(UNIT)
UNIT_SRC := $(REPO)/dv/tb/tb_pkg.sv $(REPO)/dv/coverage/uarch_coverage.sv $(REPO)/dv/unit/$(UNIT).sv

$(UNIT_DIR)/uparams.txt: FORCE
	@mkdir -p $(UNIT_DIR)
	@echo "$(UPARAMS)" | cmp -s - $@ || echo "$(UPARAMS)" > $@

$(UNIT_BIN): $(RTL_DEPS) $(UNIT_SRC) $(REPO)/sim/Makefile $(UNIT_DIR)/uparams.txt
	@echo "[unit] building $(UNIT) ($(UCONFIG)): $(UPARAMS)"
	cd $(REPO) && verilator --binary --timing --assert -j $(JOBS) --top-module $(UNIT) 	  -Wno-fatal -Wno-lint -Wno-style -O3 $(UPARAMS) 	  -f rtl/rtl_files.f $(UNIT_SRC) -Mdir $(UNIT_DIR)/obj_dir -o V$(UNIT) 	  > $(UNIT_DIR)/build.log 2>&1 || (tail -40 $(UNIT_DIR)/build.log; exit 1)

.PHONY: unit unit-build
unit-build: $(UNIT_BIN)
unit: unit-build
	cd $(UNIT_DIR) && ./obj_dir/V$(UNIT) +verilator+seed+$(SEED) | tee seed$(SEED).log
	@grep -q "TEST PASSED" $(UNIT_DIR)/seed$(SEED).log

lint:
	cd $(REPO) && verilator --lint-only -Wall --top-module ibex_cc_top +define+RVFI \
	  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-IMPORTSTAR \
	  ibex/lint/verilator_waiver.vlt -f rtl/rtl_files.f
	@echo "[lint] ibex_cc_top: clean"

clean:
	rm -rf $(BUILD)/sim
