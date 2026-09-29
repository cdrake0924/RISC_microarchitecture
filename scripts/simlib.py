# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Helpers to build and run the Verilator simulator and parse its output."""

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from uarch_configs import gparams

REPO = Path(__file__).resolve().parent.parent
BUILD = REPO / "build"
SW_BUILD = BUILD / "sw"

PERF_RE = re.compile(r"^PERF (.*)$")
KV_RE = re.compile(r"(\w+)=(\S+)")


def sh(cmd, cwd=REPO, log=None, timeout=None):
    """Run a shell command; returns (returncode, output)."""
    try:
        p = subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        out += f"\n[harness] TIMEOUT after {timeout}s\n"
        rc = -1
    if log:
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        Path(log).write_text(out)
    return rc, out


def build_software(jobs=8):
    rc, out = sh(f"make -C sw -j{jobs} all")
    if rc != 0:
        raise SystemExit("software build failed:\n" + out[-3000:])


def list_programs():
    rc, out = sh("make -s -C sw list")
    return out.split()


def sim_binary(config_name):
    return BUILD / "sim" / config_name / "obj_dir" / "Vtb_top"


def build_sim(config_name, params, jobs=4):
    """Build (or incrementally rebuild) the simulator for one configuration."""
    t0 = time.time()
    rc, out = sh(f'make -s -C sim build CONFIG={config_name} GPARAMS="{gparams(params)}" JOBS={jobs}')
    if rc != 0:
        raise SystemExit(f"simulator build for {config_name} failed:\n" + out[-3000:])
    return time.time() - t0


@dataclass
class RunResult:
    config: str
    program: str
    passed: bool
    status: str
    cycles: int = 0
    wall: float = 0.0
    perf: list = field(default_factory=list)   # list of dicts, one per PERF line
    log: str = ""


def run_sim(config_name, program, plusargs="", timeout=600, max_cycles=30_000_000, tag=""):
    """Run one program on one configuration and parse the result."""
    out_dir = BUILD / "runs" / config_name
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = program + (f".{tag}" if tag else "")
    log = out_dir / f"{stem}.log"
    cov = out_dir / f"{stem}.cov"
    hexfile = SW_BUILD / f"{program}.hex"
    cmd = (f"{sim_binary(config_name)} +firmware={hexfile} +cov_file={cov} "
           f"+maxcycles={max_cycles} {plusargs}")
    t0 = time.time()
    rc, out = sh(cmd, cwd=out_dir, log=log, timeout=timeout)
    wall = time.time() - t0

    passed = "[TB] TEST PASSED" in out
    if passed:
        status = "PASS"
    elif "TIMEOUT" in out:
        status = "TIMEOUT"
    elif "ASSERT FAILED" in out or "Assertion failed" in out:
        status = "ASSERTION"
    elif "ERROR:" in out:
        status = "CHECKER"
    else:
        status = "FAIL"

    cycles = 0
    m = re.search(r"\[TB\] simulated (\d+) cycles", out)
    if m:
        cycles = int(m.group(1))

    perf = []
    for line in out.splitlines():
        pm = PERF_RE.match(line.strip())
        if pm:
            d = {}
            for k, v in KV_RE.findall(pm.group(1)):
                d[k] = int(v) if v.isdigit() else v
            perf.append(d)
    return RunResult(config_name, program, passed, status, cycles, wall, perf, str(log))


def build_unit(tb, name, uparams, jobs=4):
    rc, out = sh(f'make -s -C sim unit-build UNIT={tb} UCONFIG={name} UPARAMS="{uparams}" JOBS={jobs}')
    if rc != 0:
        raise SystemExit(f"unit testbench build {tb}/{name} failed:\n" + out[-3000:])


def run_unit(tb, name, seed, timeout=900):
    run_dir = BUILD / "unit" / tb / name
    log = run_dir / f"seed{seed}.log"
    t0 = time.time()
    rc, out = sh(f"./obj_dir/V{tb} +verilator+seed+{seed} +cov_file=seed{seed}.cov",
                 cwd=run_dir, log=log, timeout=timeout)
    passed = "[TB] TEST PASSED" in out
    status = "PASS" if passed else ("TIMEOUT" if "TIMEOUT" in out else "FAIL")
    return RunResult(f"unit:{name}", f"{tb}#seed{seed}", passed, status, 0, time.time() - t0,
                     [], str(log))


def read_cov(path):
    bins = {}
    if os.path.exists(path):
        for line in Path(path).read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                bins[parts[0]] = int(parts[1])
    return bins
