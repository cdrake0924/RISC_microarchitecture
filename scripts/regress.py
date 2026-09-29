#!/usr/bin/env python3
# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Automated regression for the extended Ibex core complex.

Builds the software and one Verilator model per configuration, runs every (configuration, program)
pair of the selected suite in parallel, and reports pass/fail, merged functional coverage and a
JUnit XML file for CI.

  python3 scripts/regress.py                    # default: the "full" suite
  python3 scripts/regress.py --suite smoke
  python3 scripts/regress.py --suite isa --configs baseline,full -j 8

Suites
  smoke     a handful of directed tests on the full configuration (~1 minute)
  isa       riscv-tests rv32ui/um/uc on the architecture ladder and verification geometries
  directed  project directed tests (branch torture, FENCE.I, cache stress, traps, IRQs, HPM)
  bench     every benchmark, checked for correct results (not timed)
  stress    directed tests + benchmarks with random memory back-pressure
  unit      block-level constrained-random cache and branch-predictor testbenches, many seeds
  full      all of the above
"""

import argparse
import concurrent.futures as cf
import sys
import time
from pathlib import Path
from xml.sax.saxutils import escape

sys.path.insert(0, str(Path(__file__).resolve().parent))
from simlib import (BUILD, build_sim, build_software, build_unit, list_programs,  # noqa: E402
                    read_cov, run_sim, run_unit)
from uarch_configs import REGRESS_CONFIGS, STRESS_PLUSARGS, UNIT_CONFIGS, describe  # noqa: E402

LADDER = ["baseline", "static", "bp_only", "caches", "full"]
GEOMETRIES = ["tiny", "gshare_wt", "fifo_4w", "rand_8w", "dcache_only"]


def suite_jobs(suite, programs, configs_filter):
    tests = [p for p in programs if not p.startswith("rv32") and p in DIRECTED]
    isa = [p for p in programs if p.startswith("rv32")]
    bench = [p for p in programs if p in BENCH]
    jobs = []  # (config, program, plusargs, tag)

    def add(cfgs, progs, plusargs="", tag=""):
        for c in cfgs:
            if configs_filter and c not in configs_filter:
                continue
            for p in progs:
                jobs.append((c, p, plusargs, tag))

    if suite in ("smoke",):
        add(["full"], ["hello", "branch_torture", "hpm_counters", "fence_i_smc", "cache_stress"])
    if suite in ("isa", "full"):
        add(LADDER + GEOMETRIES, isa)
    if suite in ("directed", "full"):
        add(LADDER + GEOMETRIES, tests)
    if suite in ("bench", "full"):
        add(["baseline", "full", "tiny", "gshare_wt", "fifo_4w"], bench)
    if suite in ("stress", "full"):
        add(["full", "tiny", "rand_8w"], tests + ["qsort", "stream", "linked_list", "coremark", "interp"],
            STRESS_PLUSARGS, "stress")
        add(["full"], isa, STRESS_PLUSARGS, "stress")
    return jobs


DIRECTED = {"hello", "branch_torture", "hpm_counters", "fence_i_smc", "cache_stress",
            "bus_error", "timer_irq", "call_return"}
BENCH = {"coremark", "qsort", "matmul", "bsearch", "crc32", "linked_list", "stream", "fib",
         "sieve", "bp_patterns", "interp"}


def merge_coverage(results):
    merged = {}
    for r in results:
        cov_path = Path(r.log).with_suffix(".cov")
        for name, hits in read_cov(cov_path).items():
            merged[name] = merged.get(name, 0) + hits
    return merged


def coverage_summary(merged):
    groups = {}
    for name, hits in merged.items():
        g, b = name.split(".", 1)
        groups.setdefault(g, []).append((b, hits))
    lines = []
    total_bins = total_hit = 0
    for g in sorted(groups):
        bins = groups[g]
        hit = sum(1 for _, h in bins if h > 0)
        total_bins += len(bins)
        total_hit += hit
        missing = [b for b, h in bins if h == 0]
        lines.append((g, hit, len(bins), missing))
    return lines, total_hit, total_bins


def write_junit(results, path):
    cases = []
    for r in results:
        name = escape(f"{r.program}{'.stress' if 'stress' in r.log else ''}")
        body = "" if r.passed else f'<failure message="{r.status}">see {escape(r.log)}</failure>'
        cases.append(f'  <testcase classname="{r.config}" name="{name}" time="{r.wall:.2f}">'
                     f"{body}</testcase>")
    fails = sum(1 for r in results if not r.passed)
    Path(path).write_text(
        f'<?xml version="1.0"?>\n<testsuite name="ibex_uarch" tests="{len(results)}" '
        f'failures="{fails}">\n' + "\n".join(cases) + "\n</testsuite>\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--suite", default="full",
                    choices=["smoke", "isa", "directed", "bench", "stress", "unit", "full"])
    ap.add_argument("--configs", default="", help="comma-separated subset of configurations")
    ap.add_argument("-j", "--jobs", type=int, default=6, help="parallel simulations")
    ap.add_argument("--build-jobs", type=int, default=4, help="parallel C++ compile jobs")
    args = ap.parse_args()

    configs_filter = set(filter(None, args.configs.split(",")))
    t_start = time.time()
    sys.stdout.reconfigure(line_buffering=True)  # progress is visible when output is redirected

    print("[regress] building software")
    build_software()
    programs = list_programs()
    jobs = suite_jobs(args.suite, programs, configs_filter)
    configs = sorted({c for c, *_ in jobs}, key=lambda c: list(REGRESS_CONFIGS).index(c))
    all_configs = list(configs)

    for c in configs:
        print(f"[regress] building simulator {c:<12} {describe(REGRESS_CONFIGS[c])}")
        build_sim(c, REGRESS_CONFIGS[c], jobs=args.build_jobs)

    unit_jobs = []
    if args.suite in ("unit", "full") and not configs_filter:
        for tb, name, uparams, seeds in UNIT_CONFIGS:
            print(f"[regress] building unit testbench {tb}/{name}: {uparams}")
            build_unit(tb, name, uparams, jobs=args.build_jobs)
            unit_jobs += [(tb, name, s) for s in range(1, seeds + 1)]

    print(f"[regress] running {len(jobs)} system simulations on {len(configs)} configurations and "
          f"{len(unit_jobs)} unit simulations ({args.jobs} in parallel)")
    results = []
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = {pool.submit(run_sim, c, p, pa, tag=t): (c, p, t) for c, p, pa, t in jobs}
        futs.update({pool.submit(run_unit, tb, n, s): (f"unit:{n}", tb, "") for tb, n, s in unit_jobs})
        jobs = jobs + unit_jobs
        for i, fut in enumerate(cf.as_completed(futs), 1):
            r = fut.result()
            results.append(r)
            mark = "PASS" if r.passed else f"**{r.status}**"
            tag = " (stress)" if futs[fut][2] else ""
            print(f"  [{i:4d}/{len(jobs)}] {mark:<12} {r.config:<12} {r.program}{tag}"
                  f"  ({r.cycles} cycles, {r.wall:.1f}s)")

    # ---- report ----
    out = BUILD / "regress"
    out.mkdir(parents=True, exist_ok=True)
    failed = [r for r in results if not r.passed]
    merged = merge_coverage(results)
    cov_lines, cov_hit, cov_total = coverage_summary(merged)
    write_junit(results, out / "junit.xml")

    md = [f"# Regression report: suite `{args.suite}`", "",
          f"- simulations: **{len(results)}**, passed: **{len(results) - len(failed)}**, "
          f"failed: **{len(failed)}**",
          f"- configurations: {', '.join(configs)}",
          f"- functional coverage: **{cov_hit}/{cov_total} bins** "
          f"({100.0 * cov_hit / max(cov_total, 1):.1f}%)",
          f"- wall time: {time.time() - t_start:.0f}s", "",
          "| config | description | passed | total |", "|---|---|---|---|"]
    for c in all_configs:
        rs = [r for r in results if r.config == c]
        md.append(f"| {c} | {describe(REGRESS_CONFIGS[c])} | {sum(r.passed for r in rs)} | {len(rs)} |")
    for tb, name, uparams, _ in UNIT_CONFIGS:
        rs = [r for r in results if r.config == f"unit:{name}"]
        if rs:
            md.append(f"| unit:{name} | `{tb}` {uparams} | {sum(r.passed for r in rs)} | {len(rs)} |")
    md += ["", "## Functional coverage (merged over all runs)", "",
           "| group | bins hit | missing |", "|---|---|---|"]
    for g, hit, total, missing in cov_lines:
        md.append(f"| {g} | {hit}/{total} | {', '.join(missing) or '-'} |")
    if failed:
        md += ["", "## Failures", ""] + [f"- `{r.config}` / `{r.program}`: {r.status} ({r.log})"
                                         for r in failed]
    (out / "report.md").write_text("\n".join(md) + "\n")

    print()
    print(f"[regress] coverage: {cov_hit}/{cov_total} bins")
    for g, hit, total, missing in cov_lines:
        print(f"           {g:<8} {hit:3d}/{total:<3d} {('missing: ' + ', '.join(missing)) if missing else ''}")
    print(f"[regress] {len(results) - len(failed)}/{len(results)} passed "
          f"in {time.time() - t_start:.0f}s  -> {out / 'report.md'}")
    for r in failed:
        print(f"[regress] FAILED {r.config}/{r.program}: {r.status}  log: {r.log}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
