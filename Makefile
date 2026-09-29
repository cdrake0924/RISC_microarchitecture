# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Top-level entry point. Run `make help` for the list of targets.

CONFIG ?= full
TEST   ?= hello
SUITE  ?= full
JOBS   ?= 6
PYTHON ?= python3

.PHONY: help tools sw sim run waves lint unit smoke regress eval plots clean

help:
	@echo "Extended Ibex core complex - branch prediction, L1 caches, HPM counters"
	@echo ""
	@echo "  make tools                     install Verilator + RISC-V GCC locally (no sudo)"
	@echo "  make sw                        build all tests and benchmarks"
	@echo "  make sim CONFIG=full           build the Verilator model for a configuration"
	@echo "  make run TEST=coremark CONFIG=full [PLUSARGS='+mem_latency=20 +trace']"
	@echo "  make waves TEST=hello          run with FST waveform dump (build/sim/<cfg>-waves/)"
	@echo "  make lint                      Verilator -Wall lint of the RTL"
	@echo "  make unit                      block-level cache + predictor testbenches"
	@echo "  make smoke                     quick regression (~1 min)"
	@echo "  make regress SUITE=full        full regression (isa/directed/bench/stress/unit)"
	@echo "  make eval                      performance evaluation -> results/, docs/figures/"
	@echo "  make clean"
	@echo ""
	@echo "  CONFIG: baseline static bp_only caches full onebit bimodal gshare tournament wt  (see sim/Makefile)"
	@echo "  TEST  : $$($(MAKE) -s -C sw list 2>/dev/null | tr ' ' '\n' | grep -v rv32 | tr '\n' ' ')"

tools:
	bash scripts/setup_tools.sh

sw:
	$(MAKE) -C sw -j$(JOBS)

sim:
	$(MAKE) -C sim build CONFIG=$(CONFIG)

run:
	$(MAKE) -C sim run CONFIG=$(CONFIG) TEST=$(TEST) PLUSARGS="$(PLUSARGS)"

waves:
	$(MAKE) -C sim run CONFIG=$(CONFIG)-waves GPARAMS="$$($(MAKE) -s --no-print-directory -C sim print-gparams CONFIG=$(CONFIG))" \
	  WAVES=1 TEST=$(TEST) PLUSARGS="+waves $(PLUSARGS)"
	@echo "waveform: build/sim/$(CONFIG)-waves/waves.fst  (open with: gtkwave build/sim/$(CONFIG)-waves/waves.fst)"

lint:
	$(MAKE) -C sim lint

unit:
	$(PYTHON) scripts/regress.py --suite unit -j $(JOBS)

smoke:
	$(PYTHON) scripts/regress.py --suite smoke -j $(JOBS)

regress:
	$(PYTHON) scripts/regress.py --suite $(SUITE) -j $(JOBS)

eval:
	$(PYTHON) scripts/evaluate.py -j $(JOBS)

plots:
	$(PYTHON) scripts/evaluate.py --plots-only

clean:
	rm -rf build
