# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Builds every test and benchmark into $(BUILD)/<name>.{elf,hex,dis}
#
#   make                 build everything
#   make hello           build one program
#   make list            print the program names
#
# Toolchain: the first of riscv-none-elf-, riscv64-unknown-elf-, riscv32-unknown-elf- found on
# PATH is used (override with RISCV_PREFIX=...). Programs are freestanding (no libc/libgcc), so any
# bare-metal GCC with rv32 support works.

REPO    := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
SW      := $(REPO)/sw
BUILD   ?= $(REPO)/build/sw

RISCV_PREFIX ?= $(firstword $(foreach p,riscv-none-elf- riscv64-unknown-elf- riscv32-unknown-elf-,\
                  $(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
ifeq ($(RISCV_PREFIX),)
  $(error No RISC-V GCC found on PATH. See docs/getting_started.md)
endif

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

ARCH    ?= rv32imc_zicsr_zifencei
OPT     ?= -O2
CFLAGS  := -march=$(ARCH) -mabi=ilp32 -mcmodel=medany -static $(OPT) -g \
           -ffreestanding -nostdlib -nostartfiles -fno-builtin \
           -fno-tree-loop-distribute-patterns -ffunction-sections -fdata-sections \
           -Wall -Wextra -Wno-unused-parameter -I$(SW)/common
LDFLAGS := -T $(SW)/common/link.ld -Wl,--gc-sections -Wl,--no-warn-rwx-segments

COMMON_SRCS := $(SW)/common/crt0.S $(SW)/common/platform.c

# ---- programs ----------------------------------------------------------------------------------
# Directed tests: one directory per test, all .c/.S files in it are linked.
TESTS   := $(notdir $(patsubst %/,%,$(dir $(wildcard $(SW)/tests/*/main.c $(SW)/tests/*/main.S))))
# Benchmarks: one directory per workload (CoreMark's main() lives in the vendored EEMBC sources).
BENCH   := $(notdir $(patsubst %/,%,$(dir $(wildcard $(SW)/bench/*/main.c)))) coremark
# riscv-tests ISA suites (vendored subset in sw/riscv-tests, environment in sw/riscv-tests/env)
RVT_DIR := $(SW)/riscv-tests/isa
RVT_UI  := $(basename $(notdir $(wildcard $(RVT_DIR)/rv32ui/*.S)))
RVT_UM  := $(basename $(notdir $(wildcard $(RVT_DIR)/rv32um/*.S)))
RVT_UC  := $(basename $(notdir $(wildcard $(RVT_DIR)/rv32uc/*.S)))
RVT     := $(addprefix rv32ui-,$(RVT_UI)) $(addprefix rv32um-,$(RVT_UM)) $(addprefix rv32uc-,$(RVT_UC))

PROGRAMS := $(TESTS) $(BENCH) $(RVT)

.PHONY: all list clean $(PROGRAMS)
all: $(PROGRAMS)

list:
	@echo $(PROGRAMS)

$(PROGRAMS): %: $(BUILD)/%.hex $(BUILD)/%.dis

# ---- directed tests / benchmarks -------------------------------------------------------------
define PROGRAM_RULE
$(BUILD)/$(1).elf: $(wildcard $(2)/$(1)/*.c $(2)/$(1)/*.S $(2)/$(1)/*.h) $(COMMON_SRCS) $(SW)/common/link.ld $(wildcard $(SW)/common/*.h) $(3)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(4) $(LDFLAGS) -o $$@ $(COMMON_SRCS) $(wildcard $(2)/$(1)/*.c $(2)/$(1)/*.S) $(3)
endef

$(foreach t,$(TESTS),$(eval $(call PROGRAM_RULE,$(t),$(SW)/tests,,)))
$(foreach b,$(filter-out coremark,$(BENCH)),$(eval $(call PROGRAM_RULE,$(b),$(SW)/bench,,)))

# CoreMark: EEMBC sources vendored in ibex/vendor/eembc_coremark, port layer in sw/bench/coremark
CM_DIR  := $(REPO)/ibex/vendor/eembc_coremark
CM_SRCS := $(CM_DIR)/core_list_join.c $(CM_DIR)/core_main.c $(CM_DIR)/core_matrix.c \
           $(CM_DIR)/core_state.c $(CM_DIR)/core_util.c
CM_ITERATIONS ?= 2
CM_CFLAGS := -I$(CM_DIR) -I$(SW)/bench/coremark -DITERATIONS=$(CM_ITERATIONS) -DPERFORMANCE_RUN=1 \
             -Wno-implicit-fallthrough -Wno-sign-compare -Wno-maybe-uninitialized
$(eval $(call PROGRAM_RULE,coremark,$(SW)/bench,$(CM_SRCS),$(CM_CFLAGS)))

# ---- riscv-tests -----------------------------------------------------------------------------
RVT_CFLAGS := -I$(SW)/riscv-tests/env -I$(RVT_DIR)/macros/scalar
$(BUILD)/rv32ui-%.elf: $(RVT_DIR)/rv32ui/%.S $(SW)/riscv-tests/env/riscv_test.h $(SW)/common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(RVT_CFLAGS) $(LDFLAGS) -o $@ $<
$(BUILD)/rv32um-%.elf: $(RVT_DIR)/rv32um/%.S $(SW)/riscv-tests/env/riscv_test.h $(SW)/common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(RVT_CFLAGS) $(LDFLAGS) -o $@ $<
$(BUILD)/rv32uc-%.elf: $(RVT_DIR)/rv32uc/%.S $(SW)/riscv-tests/env/riscv_test.h $(SW)/common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(RVT_CFLAGS) $(LDFLAGS) -o $@ $<

# ---- image formats ---------------------------------------------------------------------------
$(BUILD)/%.hex: $(BUILD)/%.elf
	$(OBJCOPY) -O verilog $< $@

$(BUILD)/%.dis: $(BUILD)/%.elf
	$(OBJDUMP) -d -M no-aliases,numeric $< > $@ 2>/dev/null || $(OBJDUMP) -d $< > $@

.PRECIOUS: $(BUILD)/%.elf

clean:
	rm -rf $(BUILD)
