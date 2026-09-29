# Getting started

This page takes you from a fresh machine to running the regression and the performance evaluation.
The flow is plain Verilator + GCC + Make + Python. It runs on Linux, on Windows under WSL2, and
natively on Windows with MSYS2.

## 1. Required software

| Tool | Versions tested | Purpose |
|---|---|---|
| [Verilator](https://verilator.org) | 5.020 (Ubuntu 24.04), 5.050 (MSYS2). **≥ 5.020 required** (`--timing`, `--binary`, SVA) | SystemVerilog simulator (compiles RTL + testbench to C++) |
| g++ and make | g++ 13 (Ubuntu), g++ 16 (MSYS2) | builds the Verilator model (needs C++20 coroutines) |
| Bare-metal RISC-V GCC | `riscv64-unknown-elf-gcc` 13.2 (Ubuntu), xPack `riscv-none-elf-gcc` 14.2 / 15.2 | cross-compiles tests and benchmarks for RV32IMC |
| Python 3 | 3.12 | regression and evaluation scripts (standard library only) |
| matplotlib *(optional)* | 3.x | figures in `docs/figures/` (tables are produced without it) |
| GTKWave or Surfer *(optional)* | any | waveform viewing |

No commercial simulator, FuseSoC, Spike or RISC-V `newlib` is needed. The testbench is pure
SystemVerilog and the software is freestanding.

## 2. Install the tools

### Option A: Ubuntu 24.04 (native or WSL2), system packages

```bash
sudo apt update
sudo apt install -y verilator gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
                    g++ make python3 python3-matplotlib gtkwave
```

Ubuntu 24.04 ships Verilator 5.020 and RISC-V GCC 13.2, which is the combination CI uses. Ubuntu
22.04 ships Verilator 4.038, which is too old; use option B there.

### Option B: any x86-64 Linux, no sudo

```bash
make tools                # runs scripts/setup_tools.sh, installs into ./.tools (~1.5 GB)
source .tools/env.sh      # add to ~/.bashrc to make it permanent
```

This installs Verilator, g++, make, Python and matplotlib from conda-forge (via a standalone
`micromamba`), plus the xPack RISC-V GCC.

### Option C: Windows, native (MSYS2)

1. Install [MSYS2](https://www.msys2.org) and open the **MSYS2 UCRT64** shell.
2. Install the simulator toolchain:

   ```bash
   pacman -S --needed make diffutils python mingw-w64-ucrt-x86_64-verilator mingw-w64-ucrt-x86_64-gcc
   ```

3. Download the xPack RISC-V GCC `win32-x64.zip` from the
   [releases page](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases), unzip it,
   and put its `bin/` on `PATH`, for example in `~/.bashrc`:

   ```bash
   export PATH=/c/tools/xpack-riscv-none-elf-gcc-15.2.0-1/bin:$PATH
   ```

Run everything from the UCRT64 shell. `python3` there is MSYS2's own Python, which the scripts
need because they call `make` and the simulator through a POSIX shell. Do not install the
`mingw-w64-ucrt-x86_64-python` package: it would take over `python3`. Figures need matplotlib,
which MSYS2's Python does not have. Generate them from any Windows Python instead, since plotting
only reads the CSV files: `python scripts\evaluate.py --plots-only`.

### Option D: Windows, WSL2

1. In an **administrator PowerShell**: `wsl --install -d Ubuntu-24.04`, then reboot and create a
   Linux user when prompted.
2. Open *Ubuntu* from the Start menu and follow option A.
3. **Clone the repository inside the Linux file system** (e.g. `~/RISC_microarchitecture`), not
   under `/mnt/c/...`. Builds on the Windows drive work but are several times slower.

> **`Insufficient system resources ... 0x800705aa` when starting WSL.** WSL2 reserves up to half of
> physical RAM for its VM. Close memory-hungry applications, or cap the VM in
> `C:\Users\<you>\.wslconfig`:
>
> ```ini
> [wsl2]
> memory=3GB
> ```
>
> then run `wsl --shutdown` and start Ubuntu again. 3 GB is enough for this project (build with
> `JOBS=2` if the C++ compile runs out of memory).

### Check the installation

```bash
verilator --version                           # Verilator 5.0xx ...
riscv64-unknown-elf-gcc --version | head -1   # or riscv-none-elf-gcc
```

The software Makefile uses the first of `riscv-none-elf-`, `riscv64-unknown-elf-` and
`riscv32-unknown-elf-` it finds on `PATH` (override with `RISCV_PREFIX=...`).

## 3. Build and run

```bash
make sw                                  # cross-compile all 70 programs -> build/sw/*.hex
make run TEST=hello                      # build the 'full' configuration and run one program
make run TEST=coremark CONFIG=baseline   # same program on unmodified Ibex
```

Expected output of `make run TEST=hello` (abridged):

```
[TB] config: bp=tournament pht=512 ghr=8 ras=8 btb=16 | icache=on 64x2x16B plru +prefetch | dcache=on 64x2x16B plru write-back
[TB_MEM] RAM 1024 KiB, latency 10 cycles, gnt stall 0%, rvalid jitter 0
Hello from the extended Ibex core complex!
  branch predictor : tournament + RAS + BTB
  L1 I-cache       : enabled + next-line prefetch
  L1 D-cache       : write-back
PERF name=hello cycles=... instret=... br_mispred=... ic_miss=... dc_miss=...
[COV] functional coverage (this test): ...
[TB] TEST PASSED
[REDIRECT] ... pipeline redirects checked
[RVFI] retired ... instructions, control flow checked on ...
[MEM_SB] checked ... loads, ... stores, ... fetches
```

The first build of a configuration takes 1–3 minutes (Verilator + C++ compile). Later runs only
rebuild what changed. Each configuration gets its own model in `build/sim/<CONFIG>/`.

### Named configurations

| `CONFIG` | Branch prediction | L1 I-cache | L1 D-cache |
|---|---|---|---|
| `baseline` | none (upstream Ibex default) | – | – |
| `static` | static BTFN (upstream experimental predictor) | – | – |
| `bp_only` | tournament 512 + RAS 8 + BTB 16 | – | – |
| `caches` | none | 2 KiB 2-way 16 B + prefetcher | 2 KiB 2-way 16 B write-back |
| `full` *(default)* | tournament 512 + RAS 8 + BTB 16 | 2 KiB 2-way 16 B + prefetcher | 2 KiB 2-way 16 B write-back |
| `onebit`, `bimodal`, `gshare`, `tournament` | that direction predictor + RAS + BTB | as `full` | as `full` |
| `wt` | as `full` | as `full` | write-through, no write-allocate |

Any other design point is available with explicit parameters, e.g.

```bash
make -C sim run CONFIG=my4way TEST=qsort \
     GPARAMS="-GBP_MODE=3 -GDC_SETS=32 -GDC_WAYS=4 -GDC_REPL=2"
```

`BP_MODE` is 0 none, 1 static, 2 1-bit, 3 bimodal, 4 gshare, 5 tournament. `*_REPL` is 0 PLRU,
1 random, 2 FIFO. `dv/tb/tb_top.sv` lists all parameters.

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

## 4. Verification and evaluation

```bash
make lint                     # Verilator -Wall on the RTL (expect: clean)
make smoke                    # 5 directed tests on 'full', ~1 minute
make unit                     # block-level constrained-random cache + predictor benches
make regress                  # everything (see verification.md for the suite contents)
make eval                     # performance study -> results/*.csv, results/evaluation.md,
                              #                      docs/figures/*.png
```

`make regress` writes `build/regress/report.md` (pass/fail per configuration and merged functional
coverage) and `build/regress/junit.xml`. Logs of every run are in `build/runs/<config>/`.
Use `JOBS=N` to control how many simulations run in parallel.

## 5. Writing your own program

Create `sw/tests/<name>/main.c`. It is picked up automatically. Bracket the code you want to
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

`make run TEST=<name>` then builds and runs it. `CHECK(cond)` aborts with a failure message.
`tb_printf` supports `%d %u %x %s %c` with widths and `ll`.

## 6. Recommended VS Code setup

| Extension | Why |
|---|---|
| **Verilog-HDL/SystemVerilog/Bluespec SystemVerilog** (`mshr-h.veriloghdl`) | Syntax highlighting, and linting on save with Verilator as the linter. |
| **RISC-V Support** (`zhwu95.riscv`) | Highlighting for the `.S` assembly tests. |
| **Python** (`ms-python.python`) | For the regression / evaluation scripts. |
| **Surfer** waveform viewer | Opens `.fst`/`.vcd` waveforms inside VS Code; GTKWave is the standalone alternative. |
| **WSL** (`ms-vscode-remote.remote-wsl`) | Only for option D: open the repository with **WSL: Open Folder in WSL**. |

For the Verilog extension's linter, set *Verilog › Linting › Linter* to `verilator` and add the
include paths `rtl/include`, `ibex/rtl` and `ibex/vendor/lowrisc_ip/ip/prim/rtl`.
