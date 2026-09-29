#!/usr/bin/env python3
# Copyright 2026 RISC_microarchitecture contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""Performance evaluation of the micro-architecture extensions.

Runs the benchmark suite on a series of configurations, reads the hardware performance counters
that each workload reports for its measured region (PERF lines), and derives CPI, IPC, branch and
jump prediction accuracy, MPKI, cache miss rates and prefetcher effectiveness.

  python3 scripts/evaluate.py                 # all studies
  python3 scripts/evaluate.py --study ladder  # one study
  python3 scripts/evaluate.py --plots-only    # re-plot / re-tabulate from results/*.csv

Studies
  ladder    baseline -> +BP -> +I$ -> +I$+D$ -> +prefetch -> full (the headline result)
  bp        direction predictor (none/static/1-bit/bimodal/gshare/tournament), caches on, no RAS/BTB
  indirect  return address stack and indirect-jump BTB on/off (tournament, caches on)
  pht       direction-table size sweep for bimodal, gshare and tournament
  prefetch  I-cache next-line prefetcher on/off at two I-cache sizes
  wpolicy   D-cache write-back/allocate vs write-through/no-allocate
  csize     L1 capacity sweep (I$ and D$ each 512 B .. 16 KiB, 2-way, 16 B lines)
  assoc     associativity sweep at 2 KiB
  line      line-size sweep at 2 KiB
  repl      replacement policy at 2 KiB 4-way
  latency   main-memory latency sensitivity (1..40 cycles) for baseline / caches / full

Outputs: results/<study>.csv, results/evaluation.md, docs/figures/*.png
"""

import argparse
import concurrent.futures as cf
import csv
import datetime
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from simlib import REPO, build_sim, build_software, run_sim, sh  # noqa: E402
from uarch_configs import REGRESS_CONFIGS, cfg, describe  # noqa: E402

RESULTS = REPO / "results"
FIGURES = REPO / "docs" / "figures"

# Programs to run and the PERF regions that count as workloads
PROGRAMS = ["coremark", "qsort", "matmul", "bsearch", "crc32", "linked_list", "stream", "fib",
            "sieve", "interp", "bp_patterns"]
WORKLOADS = ["coremark", "qsort", "matmul", "bsearch", "crc32", "linked_list", "stream", "fib",
             "sieve", "interp_switch", "interp_threaded"]
KERNELS = ["bp_always", "bp_alternate", "bp_period4", "bp_period8", "bp_random", "bp_correlated"]
INDIRECT_WL = ["coremark", "qsort", "fib", "interp_switch", "interp_threaded"]
DEFAULT_LATENCY = 10

NO_IND = dict(BP_RAS=0, BP_BTB=0)

STUDIES = {
    "ladder": [
        ("baseline", REGRESS_CONFIGS["baseline"], "Baseline Ibex"),
        ("bp_only", REGRESS_CONFIGS["bp_only"], "+ BP only"),
        ("ev_ic", cfg(BP_MODE=0, IC_PF=0, DC_EN=0), "+ I$"),
        ("ev_icdc", cfg(BP_MODE=0, IC_PF=0), "+ I$ + D$"),
        ("caches", REGRESS_CONFIGS["caches"], "+ prefetch"),
        ("full", REGRESS_CONFIGS["full"], "+ BP (full)"),
    ],
    "bp": [
        ("ev_bp_none", cfg(BP_MODE=0), "none"),
        ("ev_bp_static", cfg(BP_MODE=1, **NO_IND), "static"),
        ("ev_bp_1bit", cfg(BP_MODE=2, **NO_IND), "1-bit"),
        ("ev_bp_bim", cfg(BP_MODE=3, **NO_IND), "bimodal"),
        ("ev_bp_gsh", cfg(BP_MODE=4, **NO_IND), "gshare"),
        ("ev_bp_tour", cfg(BP_MODE=5, **NO_IND), "tournament"),
    ],
    "indirect": [
        ("ev_bp_tour", cfg(BP_MODE=5, **NO_IND), "no RAS/BTB"),
        ("ev_ras", cfg(BP_BTB=0), "RAS"),
        ("ev_btb", cfg(BP_RAS=0), "BTB"),
        ("full", REGRESS_CONFIGS["full"], "RAS + BTB"),
    ],
    "pht": [
        ("ev_bim64", cfg(BP_MODE=3, BP_PHT=64, **NO_IND), "bimodal-64"),
        ("ev_bp_bim", cfg(BP_MODE=3, **NO_IND), "bimodal-512"),
        ("ev_bim4096", cfg(BP_MODE=3, BP_PHT=4096, **NO_IND), "bimodal-4096"),
        ("ev_gsh64", cfg(BP_MODE=4, BP_PHT=64, BP_GHR=6, **NO_IND), "gshare-64"),
        ("ev_bp_gsh", cfg(BP_MODE=4, **NO_IND), "gshare-512"),
        ("ev_gsh4096", cfg(BP_MODE=4, BP_PHT=4096, BP_GHR=12, **NO_IND), "gshare-4096"),
        ("ev_tour64", cfg(BP_MODE=5, BP_PHT=64, BP_GHR=6, **NO_IND), "tournament-64"),
        ("ev_bp_tour", cfg(BP_MODE=5, **NO_IND), "tournament-512"),
        ("ev_tour4096", cfg(BP_MODE=5, BP_PHT=4096, BP_GHR=12, **NO_IND), "tournament-4096"),
    ],
    "prefetch": [
        ("ev_ic512", cfg(IC_SETS=16, IC_PF=0), "512 B, no prefetch"),
        ("ev_ic512pf", cfg(IC_SETS=16), "512 B + prefetch"),
        ("ev_ic2k", cfg(IC_PF=0), "2 KiB, no prefetch"),
        ("full", REGRESS_CONFIGS["full"], "2 KiB + prefetch"),
    ],
    "wpolicy": [
        ("full", REGRESS_CONFIGS["full"], "write-back"),
        ("ev_wt", cfg(DC_WT=1), "write-through"),
    ],
    "csize": [
        ("ev_sz512", cfg(IC_SETS=16, DC_SETS=16), "512 B"),
        ("ev_sz1k", cfg(IC_SETS=32, DC_SETS=32), "1 KiB"),
        ("full", REGRESS_CONFIGS["full"], "2 KiB"),
        ("ev_sz4k", cfg(IC_SETS=128, DC_SETS=128), "4 KiB"),
        ("ev_sz8k", cfg(IC_SETS=256, DC_SETS=256), "8 KiB"),
        ("ev_sz16k", cfg(IC_SETS=512, DC_SETS=512), "16 KiB"),
    ],
    "assoc": [
        ("ev_w1", cfg(IC_SETS=128, IC_WAYS=1, DC_SETS=128, DC_WAYS=1), "1-way"),
        ("full", REGRESS_CONFIGS["full"], "2-way"),
        ("ev_w4", cfg(IC_SETS=32, IC_WAYS=4, DC_SETS=32, DC_WAYS=4), "4-way"),
        ("ev_w8", cfg(IC_SETS=16, IC_WAYS=8, DC_SETS=16, DC_WAYS=8), "8-way"),
    ],
    "line": [
        ("ev_l8", cfg(IC_SETS=128, IC_LINE=8, DC_SETS=128, DC_LINE=8), "8 B"),
        ("full", REGRESS_CONFIGS["full"], "16 B"),
        ("ev_l32", cfg(IC_SETS=32, IC_LINE=32, DC_SETS=32, DC_LINE=32), "32 B"),
        ("ev_l64", cfg(IC_SETS=16, IC_LINE=64, DC_SETS=16, DC_LINE=64), "64 B"),
    ],
    "repl": [
        ("ev_w4", cfg(IC_SETS=32, IC_WAYS=4, DC_SETS=32, DC_WAYS=4), "PLRU"),
        ("ev_w4_fifo", cfg(IC_SETS=32, IC_WAYS=4, IC_REPL=2, DC_SETS=32, DC_WAYS=4, DC_REPL=2), "FIFO"),
        ("ev_w4_rand", cfg(IC_SETS=32, IC_WAYS=4, IC_REPL=1, DC_SETS=32, DC_WAYS=4, DC_REPL=1), "random"),
    ],
    "latency": [
        ("baseline", REGRESS_CONFIGS["baseline"], "Baseline Ibex"),
        ("caches", REGRESS_CONFIGS["caches"], "+ caches"),
        ("full", REGRESS_CONFIGS["full"], "full"),
    ],
}
LATENCIES = [1, 5, 10, 20, 40]


# ---------------------------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------------------------
def ratio(a, b):
    return a / b if b else float("nan")


def metrics(p):
    ins = p["instret"]
    jpred = p["ras_pred"] + p["btb_pred"]
    return {
        "cycles": p["cycles"],
        "instret": ins,
        "cpi": ratio(p["cycles"], ins),
        "ipc": ratio(ins, p["cycles"]),
        "branches": p["branches"],
        "br_mispred": p["br_mispred"],
        "br_acc": 100.0 * (1 - ratio(p["br_mispred"], p["branches"])) if p["branches"] else float("nan"),
        "br_mpki": 1000.0 * ratio(p["br_mispred"], ins),
        "jalr": p["jalr"],
        "jalr_cov": 100.0 * ratio(jpred, p["jalr"]),                  # JALRs predicted at all
        "jalr_acc": 100.0 * (1 - ratio(p["jalr_mispred"], jpred)) if jpred else float("nan"),
        "jalr_ok": 100.0 * ratio(jpred - p["jalr_mispred"], p["jalr"]),  # JALRs predicted right
        "ic_miss_rate": 100.0 * ratio(p["ic_miss"], p["ic_access"]),
        "dc_miss_rate": 100.0 * ratio(p["dc_miss"], p["dc_access"]),
        "ic_mpki": 1000.0 * ratio(p["ic_miss"], ins),
        "dc_mpki": 1000.0 * ratio(p["dc_miss"], ins),
        "wb_pki": 1000.0 * ratio(p["dc_writeback"], ins),
        "pf_acc": 100.0 * ratio(p["ic_pf_hit"], p["ic_pf_issue"]),     # prefetches that were used
        "pf_cov": 100.0 * ratio(p["ic_pf_hit"], p["ic_miss"]),         # misses served by prefetch
        "iside_frac": 100.0 * ratio(p["iside_wait"], p["cycles"]),
        "dside_frac": 100.0 * ratio(p["dside_wait"], p["cycles"]),
        **{k: p[k] for k in ("ic_access", "ic_miss", "ic_pf_issue", "ic_pf_hit", "dc_access",
                              "dc_miss", "dc_writeback", "dc_bypass", "loads", "stores", "taken",
                              "jumps", "ras_pred", "btb_pred", "jalr_mispred")},
    }


def geomean(xs):
    xs = [x for x in xs if x == x and x > 0]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def mean(xs):
    xs = [x for x in xs if x == x]
    return sum(xs) / len(xs) if xs else float("nan")


# ---------------------------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------------------------
def run_study(study, jobs, build_jobs):
    rows = []
    configs = STUDIES[study]
    for name, params, _ in configs:
        print(f"[eval] building {name:<14} {describe(params)}")
        build_sim(name, params, jobs=build_jobs)
    latencies = LATENCIES if study == "latency" else [DEFAULT_LATENCY]
    work = [(name, label, params, prog, lat) for name, params, label in configs
            for prog in PROGRAMS for lat in latencies]
    print(f"[eval] {study}: {len(work)} simulations")
    with cf.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = {pool.submit(run_sim, name, prog, f"+mem_latency={lat}",
                            tag=f"eval_l{lat}"): (name, label, params, prog, lat)
                for name, label, params, prog, lat in work}
        for fut in cf.as_completed(futs):
            name, label, params, prog, lat = futs[fut]
            r = fut.result()
            if not r.passed:
                raise SystemExit(f"[eval] {name}/{prog} FAILED ({r.status}), see {r.log}")
            for p in r.perf:
                rows.append({"study": study, "config": name, "label": label,
                             "desc": describe(params), "latency": lat, "workload": p["name"],
                             **metrics(p)})
    order = {n: i for i, (n, _, _) in enumerate(configs)}
    rows.sort(key=lambda r: (order[r["config"]], r["latency"], r["workload"]))
    RESULTS.mkdir(exist_ok=True)
    with open(RESULTS / f"{study}.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return rows


def load(study):
    path = RESULTS / f"{study}.csv"
    if not path.exists():
        return []
    rows = list(csv.DictReader(open(path)))
    for r in rows:
        for k, v in r.items():
            if k not in ("study", "config", "label", "desc", "workload"):
                r[k] = float(v)
    return rows


# ---------------------------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------------------------
def fmt(x, d=2):
    return "-" if x != x else f"{x:.{d}f}"


def table_md(header, lines):
    s = "| " + " | ".join(header) + " |\n|" + "|".join("---" for _ in header) + "|\n"
    for ln in lines:
        s += "| " + " | ".join(ln) + " |\n"
    return s


def labels_in_order(rows):
    seen = []
    for r in rows:
        if r["label"] not in seen:
            seen.append(r["label"])
    return seen


def cell(rows, label, workload, key):
    for r in rows:
        if r["label"] == label and r["workload"] == workload:
            return r[key]
    return float("nan")


def per_workload_table(rows, workloads, labels, key, digits=2, suffix=""):
    lines = []
    for w in workloads:
        lines.append([w] + [fmt(cell(rows, l, w, key), digits) + suffix for l in labels])
    return lines


def report():
    md = ["# Evaluation results", "",
          f"Generated by `scripts/evaluate.py` on {datetime.date.today().isoformat()}. "
          f"Main-memory latency {DEFAULT_LATENCY} cycles unless stated otherwise. Every number is "
          "read from the hardware performance counters over each workload's measured region. "
          "Analysis: [docs/evaluation.md](../docs/evaluation.md).", ""]
    meta = json.loads((RESULTS / "meta.json").read_text()) if (RESULTS / "meta.json").exists() else {}
    if meta:
        md += [f"Toolchain: {meta.get('verilator', '?')}; {meta.get('gcc', '?')}", ""]

    ladder = [r for r in load("ladder") if r["workload"] in WORKLOADS]
    if ladder:
        labels = labels_in_order(ladder)
        base = {r["workload"]: r["cpi"] for r in ladder if r["label"] == labels[0]}
        md += ["## 1. Architecture ladder: CPI", ""]
        lines = per_workload_table(ladder, WORKLOADS, labels, "cpi")
        lines.append(["**geomean CPI**"] + [
            f"**{fmt(geomean([r['cpi'] for r in ladder if r['label'] == l]), 3)}**" for l in labels])
        lines.append(["**geomean IPC**"] + [
            f"**{fmt(geomean([r['ipc'] for r in ladder if r['label'] == l]), 3)}**" for l in labels])
        lines.append(["**speedup vs baseline**"] + [
            f"**{fmt(geomean([base[r['workload']] / r['cpi'] for r in ladder if r['label'] == l]))}x**"
            for l in labels])
        md.append(table_md(["workload"] + labels, lines))
        md += ["Fetch-stall / data-stall cycles as % of all cycles:", ""]
        lines = []
        for w in WORKLOADS:
            lines.append([w] + [f"{fmt(cell(ladder, l, w, 'iside_frac'), 0)} / "
                                f"{fmt(cell(ladder, l, w, 'dside_frac'), 0)}" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    bp = load("bp")
    if bp:
        labels = labels_in_order(bp)
        md += ["## 2. Direction predictors (caches on, RAS/BTB off)", "",
               "Conditional-branch accuracy % / MPKI (mispredicts per 1000 instructions).", ""]
        lines = []
        for w in WORKLOADS + KERNELS:
            lines.append([w] + [f"{fmt(cell(bp, l, w, 'br_acc'), 1)} / {fmt(cell(bp, l, w, 'br_mpki'), 1)}"
                                for l in labels])
        real = [r for r in bp if r["workload"] in WORKLOADS]
        lines.append(["**mean accuracy (workloads)**"] + [
            f"**{fmt(mean([r['br_acc'] for r in real if r['label'] == l]), 1)}%**" for l in labels])
        lines.append(["**mean MPKI (workloads)**"] + [
            f"**{fmt(mean([r['br_mpki'] for r in real if r['label'] == l]), 1)}**" for l in labels])
        lines.append(["**geomean CPI (workloads)**"] + [
            f"**{fmt(geomean([r['cpi'] for r in real if r['label'] == l]), 3)}**" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    ind = load("indirect")
    if ind:
        labels = labels_in_order(ind)
        md += ["## 3. Return address stack and indirect-jump BTB (tournament, caches on)", "",
               "% of executed JALRs predicted *correctly* / CPI.", ""]
        lines = []
        for w in INDIRECT_WL:
            lines.append([w] + [f"{fmt(cell(ind, l, w, 'jalr_ok'), 1)} / {fmt(cell(ind, l, w, 'cpi'), 3)}"
                                for l in labels])
        real = [r for r in ind if r["workload"] in WORKLOADS]
        lines.append(["**geomean CPI (all workloads)**"] + [
            f"**{fmt(geomean([r['cpi'] for r in real if r['label'] == l]), 3)}**" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    pht = [r for r in load("pht") if r["workload"] in WORKLOADS]
    if pht:
        labels = labels_in_order(pht)
        md += ["## 4. Direction-table size", "", "Averages over the workloads.", ""]
        lines = []
        for l in labels:
            rs = [r for r in pht if r["label"] == l]
            lines.append([l, fmt(mean([r["br_acc"] for r in rs]), 2) + "%",
                          fmt(mean([r["br_mpki"] for r in rs]), 2),
                          fmt(geomean([r["cpi"] for r in rs]), 3)])
        md.append(table_md(["predictor", "mean accuracy", "mean MPKI", "geomean CPI"], lines))

    pf = [r for r in load("prefetch") if r["workload"] in WORKLOADS]
    if pf:
        labels = labels_in_order(pf)
        md += ["## 5. I-cache next-line prefetcher", "",
               "I-cache miss rate % / % of misses served by the prefetcher / CPI.", ""]
        lines = []
        for w in WORKLOADS:
            lines.append([w] + [f"{fmt(cell(pf, l, w, 'ic_miss_rate'), 2)} / {fmt(cell(pf, l, w, 'pf_cov'), 0)} / "
                                f"{fmt(cell(pf, l, w, 'cpi'), 3)}" for l in labels])
        lines.append(["**prefetch accuracy (used / issued)**"] + [
            f"**{fmt(100 * sum(r['ic_pf_hit'] for r in pf if r['label'] == l) / max(1, sum(r['ic_pf_issue'] for r in pf if r['label'] == l)), 1)}%**"
            for l in labels])
        lines.append(["**geomean CPI**"] + [
            f"**{fmt(geomean([r['cpi'] for r in pf if r['label'] == l]), 3)}**" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    wp = [r for r in load("wpolicy") if r["workload"] in WORKLOADS]
    if wp:
        labels = labels_in_order(wp)
        md += ["## 6. D-cache write policy", "",
               "D-cache miss rate % / memory write transactions per 1000 instructions / CPI "
               "(write-back: dirty lines x words per line; write-through: every store).", ""]
        lines = []
        for w in WORKLOADS:
            vals = []
            for l in labels:
                wb = cell(wp, l, w, "dc_writeback") * 4 if l == "write-back" else cell(wp, l, w, "stores")
                vals.append(f"{fmt(cell(wp, l, w, 'dc_miss_rate'), 1)} / "
                            f"{fmt(1000 * wb / cell(wp, l, w, 'instret'), 1)} / {fmt(cell(wp, l, w, 'cpi'), 3)}")
            lines.append([w] + vals)
        lines.append(["**geomean CPI**"] + [
            f"**{fmt(geomean([r['cpi'] for r in wp if r['label'] == l]), 3)}**" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    for study, title in (("csize", "7. L1 capacity (I$ and D$ each)"),
                         ("assoc", "8. Associativity (2 KiB)"),
                         ("line", "9. Line size (2 KiB, 2-way)"),
                         ("repl", "10. Replacement policy (2 KiB, 4-way)")):
        rows = [r for r in load(study) if r["workload"] in WORKLOADS]
        if not rows:
            continue
        labels = labels_in_order(rows)
        md += [f"## {title}", "", "D-cache miss rate % (I-cache miss rate %); geomean CPI.", ""]
        lines = []
        for w in WORKLOADS:
            lines.append([w] + [f"{fmt(cell(rows, l, w, 'dc_miss_rate'), 1)} "
                                f"({fmt(cell(rows, l, w, 'ic_miss_rate'), 1)})" for l in labels])
        lines.append(["**geomean CPI**"] + [
            f"**{fmt(geomean([r['cpi'] for r in rows if r['label'] == l]), 3)}**" for l in labels])
        md.append(table_md(["workload"] + labels, lines))

    lat = [r for r in load("latency") if r["workload"] in WORKLOADS]
    if lat:
        labels = labels_in_order(lat)
        md += ["## 11. Memory latency sensitivity", "", "Geomean CPI over the workloads.", ""]
        lines = []
        for L in LATENCIES:
            lines.append([str(L)] + [fmt(geomean([r["cpi"] for r in lat if r["label"] == l and
                                                   r["latency"] == L]), 3) for l in labels])
        md.append(table_md(["latency (cycles)"] + labels, lines))

    (RESULTS / "evaluation.md").write_text("\n".join(md) + "\n")
    print(f"[eval] wrote {RESULTS / 'evaluation.md'}")


# ---------------------------------------------------------------------------------------------
# Figures (matplotlib; validated categorical palette, one y-axis per chart, legend + tables)
# ---------------------------------------------------------------------------------------------
PALETTE = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
SURFACE, INK, INK2, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#e1e0d9", "#c3c2b7"


def setup_axes(ax, ylabel, title):
    ax.set_facecolor(SURFACE)
    ax.figure.set_facecolor(SURFACE)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(AXIS)
    ax.tick_params(colors=INK2, labelsize=9, length=0)
    ax.set_ylabel(ylabel, color=INK2, fontsize=10)
    ax.set_title(title, color=INK, fontsize=12, loc="left", pad=12)


def grouped_bars(path, groups, series, values, ylabel, title, value_fmt=None, ylim=None,
                 figsize=(11, 4.4)):
    import matplotlib.pyplot as plt
    n = len(series)
    width = 0.82 / n
    fig, ax = plt.subplots(figsize=figsize, dpi=150)
    for i, s in enumerate(series):
        xs = [g + (i - (n - 1) / 2) * width for g in range(len(groups))]
        ax.bar(xs, values[s], width=width, color=PALETTE[i], label=s,
               edgecolor=SURFACE, linewidth=1.0)
        if value_fmt:  # label only the last group (the summary)
            ax.annotate(value_fmt(values[s][-1]), (xs[-1], values[s][-1]), ha="center",
                        va="bottom", fontsize=7, color=INK2, xytext=(0, 2),
                        textcoords="offset points")
    setup_axes(ax, ylabel, title)
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels(groups, fontsize=8.5, color=INK2, rotation=20, ha="right")
    if ylim:
        ax.set_ylim(*ylim)
    ax.legend(frameon=False, fontsize=8.5, ncol=min(n, 6), loc="upper left",
              bbox_to_anchor=(0, 1.0), labelcolor=INK2)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)


def lines_chart(path, xs, xlabels, series, values, ylabel, title, xlabel):
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8, 4.2), dpi=150)
    for i, s in enumerate(series):
        ax.plot(xs, values[s], color=PALETTE[i], linewidth=2, marker="o", markersize=5,
                markeredgecolor=SURFACE, markeredgewidth=1.5, label=s)
        ax.annotate(s, (xs[-1], values[s][-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=8.5, color=INK2)
    setup_axes(ax, ylabel, title)
    ax.set_xticks(xs)
    ax.set_xticklabels(xlabels, fontsize=9, color=INK2)
    ax.set_xlabel(xlabel, color=INK2, fontsize=10)
    ax.set_xlim(xs[0] - 0.3, xs[-1] + 1.6)
    ax.legend(frameon=False, fontsize=9, loc="upper left", labelcolor=INK2)
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)


def plots():
    try:
        import matplotlib
        matplotlib.use("Agg")
    except ImportError:
        print("[eval] matplotlib not available: skipping figures (tables are still written)")
        return
    FIGURES.mkdir(parents=True, exist_ok=True)

    ladder = [r for r in load("ladder") if r["workload"] in WORKLOADS]
    if ladder:
        labels = labels_in_order(ladder)
        base = {r["workload"]: r["cpi"] for r in ladder if r["label"] == labels[0]}
        series = labels[1:]
        vals = {}
        for l in series:
            per = {r["workload"]: base[r["workload"]] / r["cpi"] for r in ladder if r["label"] == l}
            vals[l] = [per[w] for w in WORKLOADS] + [geomean(per.values())]
        grouped_bars(FIGURES / "ladder_speedup.png", WORKLOADS + ["geomean"], series, vals,
                     "speedup over baseline Ibex (x)",
                     "Speedup of each step over baseline Ibex (memory latency 10 cycles)",
                     value_fmt=lambda v: f"{v:.2f}x")

    bp = load("bp")
    if bp:
        labels = [l for l in labels_in_order(bp) if l != "none"]
        groups = WORKLOADS + ["bp_alternate", "bp_period4", "bp_correlated"]
        vals = {l: [cell(bp, l, w, "br_acc") for w in groups] for l in labels}
        grouped_bars(FIGURES / "bp_accuracy.png", groups, labels, vals,
                     "conditional-branch accuracy (%)", "Branch direction accuracy by predictor",
                     ylim=(0, 105), figsize=(12, 4.4))

    ind = load("indirect")
    if ind:
        labels = labels_in_order(ind)
        vals = {l: [cell(ind, l, w, "jalr_ok") for w in INDIRECT_WL] for l in labels}
        grouped_bars(FIGURES / "indirect_accuracy.png", INDIRECT_WL, labels, vals,
                     "JALRs predicted correctly (%)",
                     "Register-indirect jump prediction: RAS and BTB", ylim=(0, 105),
                     figsize=(9, 4.2))

    pht = [r for r in load("pht") if r["workload"] in WORKLOADS]
    if pht:
        sizes = [64, 512, 4096]
        fams = {f: [f"{f}-{s}" for s in sizes] for f in ("bimodal", "gshare", "tournament")}
        vals = {f: [mean([r["br_mpki"] for r in pht if r["label"] == l]) for l in ls]
                for f, ls in fams.items()}
        lines_chart(FIGURES / "bp_pht_sweep.png", list(range(len(sizes))), [str(s) for s in sizes],
                    list(fams), vals, "mean mispredicts per 1000 instr.",
                    "Branch MPKI vs direction-table size", "table entries")

    csize = [r for r in load("csize") if r["workload"] in WORKLOADS]
    if csize:
        labels = labels_in_order(csize)
        show = ["linked_list", "sieve", "stream", "qsort", "coremark", "matmul"]
        vals = {w: [cell(csize, l, w, "dc_miss_rate") for l in labels] for w in show}
        lines_chart(FIGURES / "dcache_size_missrate.png", list(range(len(labels))), labels, show,
                    vals, "D-cache miss rate (%)", "D-cache miss rate vs capacity (2-way, 16 B lines)",
                    "capacity (each of I$ and D$)")

    lat = [r for r in load("latency") if r["workload"] in WORKLOADS]
    if lat:
        labels = labels_in_order(lat)
        vals = {l: [geomean([r["cpi"] for r in lat if r["label"] == l and r["latency"] == L])
                    for L in LATENCIES] for l in labels}
        lines_chart(FIGURES / "latency_cpi.png", list(range(len(LATENCIES))),
                    [str(L) for L in LATENCIES], labels, vals, "geomean CPI",
                    "CPI vs main-memory latency", "memory latency (cycles)")
    print(f"[eval] figures in {FIGURES}")


def write_meta():
    RESULTS.mkdir(exist_ok=True)
    _, ver = sh("verilator --version")
    _, gcc = sh("for p in riscv-none-elf- riscv64-unknown-elf- riscv32-unknown-elf-; do "
                "command -v ${p}gcc >/dev/null && ${p}gcc --version && break; done")
    meta = {"date": datetime.datetime.now().isoformat(timespec="seconds"),
            "verilator": ver.strip().splitlines()[0] if ver.strip() else "?",
            "gcc": gcc.strip().splitlines()[0] if gcc.strip() else "?",
            "memory_latency": DEFAULT_LATENCY}
    (RESULTS / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--study", default="all", choices=["all"] + list(STUDIES))
    ap.add_argument("-j", "--jobs", type=int, default=6)
    ap.add_argument("--build-jobs", type=int, default=3)
    ap.add_argument("--plots-only", action="store_true")
    args = ap.parse_args()
    sys.stdout.reconfigure(line_buffering=True)

    if not args.plots_only:
        t0 = time.time()
        build_software()
        write_meta()
        for s in (list(STUDIES) if args.study == "all" else [args.study]):
            run_study(s, args.jobs, args.build_jobs)
        print(f"[eval] simulations finished in {time.time() - t0:.0f}s")
    report()
    plots()


if __name__ == "__main__":
    main()
