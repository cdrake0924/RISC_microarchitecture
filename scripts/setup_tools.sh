#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup_tools.sh - install a self-contained simulation toolchain WITHOUT sudo.
#
# Installs into $TOOLS_DIR (default: <repo>/.tools):
#   * Verilator 5.x, g++, make, Python 3 + matplotlib  (conda-forge via micromamba)
#   * xPack riscv-none-elf-gcc (bare-metal RISC-V GCC with rv32 multilibs)
#
# Afterwards:   source <TOOLS_DIR>/env.sh
#
# If you have sudo on Ubuntu 24.04 you can skip this script entirely:
#   sudo apt install verilator gcc-riscv64-unknown-elf make g++ python3-matplotlib
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
VERILATOR_VERSION="${VERILATOR_VERSION:-5.020}"
XPACK_GCC_VERSION="${XPACK_GCC_VERSION:-14.2.0-3}"

mkdir -p "$TOOLS_DIR/bin"
cd "$TOOLS_DIR"
echo "[setup] installing into $TOOLS_DIR"

# ---- 1. micromamba (single static binary) ----------------------------------
if [ ! -x "$TOOLS_DIR/bin/micromamba" ]; then
  echo "[setup] downloading micromamba"
  curl -Ls https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xj -C "$TOOLS_DIR" bin/micromamba
fi

# ---- 2. Verilator + host C++ toolchain + Python -----------------------------
if [ ! -x "$TOOLS_DIR/env/bin/verilator" ]; then
  echo "[setup] creating conda env (verilator=$VERILATOR_VERSION, gxx, make, python, matplotlib)"
  export MAMBA_ROOT_PREFIX="$TOOLS_DIR/mamba"
  "$TOOLS_DIR/bin/micromamba" create -y -q -p "$TOOLS_DIR/env" -c conda-forge \
      "verilator=$VERILATOR_VERSION" gxx make "python=3.12" matplotlib-base \
    || "$TOOLS_DIR/bin/micromamba" create -y -q -p "$TOOLS_DIR/env" -c conda-forge \
      verilator gxx make "python=3.12" matplotlib-base
  "$TOOLS_DIR/bin/micromamba" clean -y -a -q >/dev/null 2>&1 || true
fi

# ---- 3. RISC-V bare-metal GCC (xPack) ---------------------------------------
XPACK_DIR="$TOOLS_DIR/xpack-riscv-none-elf-gcc-$XPACK_GCC_VERSION"
if [ ! -x "$XPACK_DIR/bin/riscv-none-elf-gcc" ]; then
  echo "[setup] downloading xPack riscv-none-elf-gcc $XPACK_GCC_VERSION"
  URL="https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$XPACK_GCC_VERSION/xpack-riscv-none-elf-gcc-$XPACK_GCC_VERSION-linux-x64.tar.gz"
  curl -L --fail -o xpack-gcc.tar.gz "$URL"
  tar -xzf xpack-gcc.tar.gz
  rm -f xpack-gcc.tar.gz
fi

# ---- 4. environment script --------------------------------------------------
cat > "$TOOLS_DIR/env.sh" <<EOF
# Source this file to put the project toolchain on PATH.
export PATH="$TOOLS_DIR/env/bin:$XPACK_DIR/bin:\$PATH"
EOF

# shellcheck disable=SC1091
source "$TOOLS_DIR/env.sh"
echo "[setup] done:"
verilator --version
riscv-none-elf-gcc --version | head -1
g++ --version | head -1
python3 -c "import matplotlib; print('matplotlib', matplotlib.__version__)"
echo "[setup] run:  source $TOOLS_DIR/env.sh"
