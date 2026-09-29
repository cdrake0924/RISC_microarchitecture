# Getting started

This page takes you from a fresh machine to running the regression and the performance evaluation.
Everything runs on Linux; on Windows use **WSL2** (Windows Subsystem for Linux).

## 1. Required software

| Tool | Version tested | Purpose |
|---|---|---|
| Linux (native, or WSL2 on Windows) | Ubuntu 24.04 | host OS for the EDA flow |
| [Verilator](https://verilator.org) | **5.020** (≥ 5.020 required: `--timing`, `--binary`, SVA) | SystemVerilog simulator (compiles RTL + testbench to C++) |
| g++ and make | g++ 13 (Ubuntu), g++ 16 (conda) | builds the Verilator model (needs C++20 coroutines) |
| Bare-metal RISC-V GCC | `riscv64-unknown-elf-gcc` 13.2 (Ubuntu) **or** xPack `riscv-none-elf-gcc` 14.2 | cross-compiles tests and benchmarks for RV32IMC |
| Python 3 | 3.12 | regression and evaluation scripts |
| matplotlib *(optional)* | 3.x | figures in `docs/figures/` (tables are produced without it) |
| GTKWave or Surfer *(optional)* | any | waveform viewing |

No commercial simulator, FuseSoC, Spike, or RISC-V `newlib` is needed: the testbench is pure
SystemVerilog and the software is freestanding.

## 2. Windows only: set up WSL2

1. In an **administrator PowerShell**: `wsl --install -d Ubuntu-24.04`, then reboot and create a
   Linux user when prompted.
2. Open *Ubuntu* from the Start menu (or `wsl` in a terminal). All commands below run there.
3. **Clone the repository inside the Linux file system** (e.g. `~/RISC_microarchitecture`) rather
   than under `/mnt/c/...`. Builds on the Windows drive work but are several times slower and print
   harmless `make: Clock skew detected` warnings.

> **Troubleshooting: `Insufficient system resources ... 0x800705aa` when starting WSL.**
> WSL2 reserves up to half of physical RAM for its VM. On an 8 GB laptop with a browser open this
> can fail. Close memory-hungry applications, or cap the VM by creating
> `C:\Users\<you>\.wslconfig` containing
>
> ```ini
> [wsl2]
> memory=3GB
> ```
>
> then run `wsl --shutdown` and start Ubuntu again. 3 GB is enough for this project
> (build with `JOBS=2` if the C++ compile runs out of memory).

## 3. Install the tools

**Option A – system packages (needs sudo, recommended):**

```bash
sudo apt update
sudo apt install -y verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
                    g++ make python3 python3-matplotlib gtkwave
```

Ubuntu 24.04 ships Verilator 5.020 and RISC-V GCC 13.2, the combination used by CI. Ubuntu 22.04
ships Verilator 4.038, which is too old; use option B there.

**Option B – no sudo, self-contained (any x86-64 Linux):**

```bash
make tools                # runs scripts/setup_tools.sh, installs into ./.tools (~1.5 GB)
source .tools/env.sh      # add to ~/.bashrc to make it permanent
```

This installs Verilator 5.020, g++, make, Python and matplotlib from conda-forge (via a standalone
`micromamba`) plus the xPack RISC-V GCC. It is the exact environment the published results were
produced with.

Check the installation:

```bash
verilator --version                       # Verilator 5.020 ...
riscv64-unknown-elf-gcc --version | head -1   # or riscv-none-elf-gcc
```

The software Makefile picks whichever of `riscv-none-elf-`, `riscv64-unknown-elf-`,
`riscv32-unknown-elf-` it finds on `PATH` (override with `RISCV_PREFIX=...`).

## 4. Recommended VS Code setup

VS Code on Windows can drive everything inside WSL:

| Extension | Why |
|---|---|
| **WSL** (`ms-vscode-remote.remote-wsl`) | *Required on Windows.* Open the repository with **WSL: Open Folder in WSL** so the integrated terminal, tasks and linters run in Linux. |
| **Verilog-HDL/SystemVerilog/Bluespec SystemVerilog** (`mshr-h.veriloghdl`) | Syntax highlighting, and linting on save with Verilator as the linter. |
| **RISC-V Support** (`zhwu95.riscv`) | Highlighting for the `.S` assembly tests. |
| **Python** (`ms-python.python`) | For the regression / evaluation scripts. |
| **Surfer** waveform viewer (search "Surfer" in the marketplace) | Opens `.fst`/`.vcd` waveforms inside VS Code; GTKWave is the standalone alternative. |

For the Verilog extension's linter, set *Verilog › Linting › Linter* to `verilator` and add the
include paths `rtl/include`, `ibex/rtl` and `ibex/vendor/lowrisc_ip/ip/prim/rtl`.

## 5. Build and run

```bash
make sw                                  # cross-compile all 68 programs -> build/sw/*.hex
make run TEST=hello                      # build the 'full' configuration and run one program
make run TEST=coremark CONFIG=baseline   # same program on unmodified Ibex
```

Expected tail of `make run TEST=hello`:

```
Hello from the extended Ibex core complex!
  branch predictor : gshare
  L1 I-cache       : enabled
  L1 D-cache       : enabled
PERF name=hello cycles=... instret=... br_mispred=... ic_miss=... dc_miss=...
[RVFI] retired ... instructions, control flow checked on ...
[TB] TEST PASSED
```

The first build of a configuration takes 1–3 minutes (Verilator + C++ compile); later runs only
rebuild what changed. Each configuration gets its own model in `build/sim/<CONFIG>/`.

### Named configurations

| `CONFIG` | Branch predictor | L1 I-cache | L1 D-cache |
|---|---|---|---|
| `baseline` | none (upstream Ibex default) | – | – |
| `static` | static BTFN (upstream experimental predictor) | – | – |
| `bimodal` | bimodal, 512 entries | – | – |
| `gshare` | gshare, 512 entries, 8-bit history | – | – |
| `icache` | none | 2 KiB 2-way 16 B | – |
| `caches` | none | 2 KiB 2-way 16 B | 2 KiB 2-way 16 B |
| `full` *(default)* | gshare, 512 entries, 8-bit history | 2 KiB 2-way 16 B | 2 KiB 2-way 16 B |

Any other point is available with explicit parameters, e.g.

```bash
make -C sim run CONFIG=my4way TEST=qsort \
     GPARAMS="-GBP_MODE=2 -GDC_SETS=32 -GDC_WAYS=4 -GDC_REPL=1"
```

(`BP_MODE` 0 none / 1 static / 2 bimodal / 3 gshare; `*_REPL` 0 PLRU / 1 random / 2 FIFO; see
`dv/tb/tb_top.sv` for all parameters.)

### Runtime options (`PLUSARGS=`)

| Plusarg | Effect |
|---|---|
| `+mem_latency=N` | main-memory latency in cycles (default 10) |
| `+gnt_stall=P` | withhold the bus grant P% of cycles (protocol stress) |
| `+rvalid_jitter=N` | add 0..N random cycles to every response |
| `+trace` | write an instruction trace to `trace_core_00000000.log` |
| `+maxcycles=N` | timeout (default 20 M cycles) |
| `+verbose` | log every memory transaction |

### Waveforms

```bash
make waves TEST=branch_torture           # builds a tracing model, writes waves.fst
gtkwave build/sim/full-waves/waves.fst
```

## 6. Verification and evaluation

```bash
make lint                     # Verilator -Wall on the RTL (expect: clean)
make smoke                    # 5 directed tests on 'full', ~1 minute
make unit                     # block-level constrained-random cache + predictor benches
make regress                  # everything: ~700 simulations on 9 configurations
make eval                     # performance study -> results/*.csv, results/evaluation.md,
                              #                      docs/figures/*.png
```

`make regress` writes `build/regress/report.md` (pass/fail per configuration and merged functional
coverage) and `build/regress/junit.xml`. Logs of every run are in `build/runs/<config>/`.

## 7. Writing your own program

Create `sw/tests/<name>/main.c` (it is picked up automatically) and bracket the code you want to
measure with the HPM helpers:

```c
#include "perf.h"
#include "platform.h"

int main(void) {
  perf_start();                 // zero and start all counters
  /* ... code under test ... */
  perf_finish("my_kernel");     // stop, read and print one PERF line
  return 0;                     // 0 = pass
}
```

`make run TEST=<name>` then builds and runs it. `CHECK(cond)` aborts with a failure message;
`tb_printf` supports `%d %u %x %s %c` with widths and `ll`.
