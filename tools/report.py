#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Make the regression results page (Markdown) and the final verdict.

    python3 tools/report.py logs/regress/summary.csv logs/regress/coverage.csv \\
        -o logs/regress/results.md --meta "Simulator=Xcelium 23.09" ...

summary.csv: one row per run (sim/common.sh run_case; negative tests have
set "neg" and result CAUGHT/MISSED). coverage.csv: tools/merge_cov.py output,
hits of every bin per configuration plus "all".

Sign-off (docs/vplan.md): every negative test caught; every other run
passes; no assertion fires; every coverage bin hit over all runs; and in
every configuration all txn, flow and order bins hit.
Exit code 0 if signed off, 1 if not.
"""
import argparse
import csv
import sys

GROUPS = ["txn", "flow", "order", "clk", "scen"]
PER_CONFIG = ["txn", "flow", "order"]
SET_NAMES = {
    "dir": "Directed tests (Stage 4)",
    "clk": "Clock sweep (Stage 5)",
    "depth": "FIFO full at every depth",
    "rand": "Constrained random, random clocks",
    "deep": "Targeted random, deep FIFOs",
}
CHANNELS = [("AW", "src_stall_aw"), ("W", "src_stall_w"), ("AR", "src_stall_ar"),
            ("B", "dst_stall_b"), ("R", "dst_stall_r")]


def num(x):
    try:
        return int(x)
    except ValueError:
        return 0


def config_of(r):
    return ("ram" if r["use_ram"] == "1" else "orig") + "_d" + r["log_depth"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("summary")
    ap.add_argument("coverage")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--meta", action="append", default=[], help="KEY=VALUE line for the header")
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.summary)))
    neg = [r for r in rows if r["set"] == "neg"]
    runs = [r for r in rows if r["set"] != "neg"]

    cov = list(csv.DictReader(open(a.coverage)))
    cov_sets = [k for k in (cov[0].keys() if cov else []) if k != "bin"]

    def cov_row(s):
        out = {}
        for g in GROUPS:
            ks = [c for c in cov if c["bin"].split(".", 1)[0] == g]
            out[g] = (sum(1 for c in ks if num(c[s]) > 0), len(ks))
        out["total"] = (sum(1 for c in cov if num(c[s]) > 0), len(cov))
        return out

    # ---- sign-off checks
    problems = []
    for r in neg:
        if r["result"] != "CAUGHT":
            problems.append(f"negative test {r['name']} was not caught")
    for r in runs:
        if r["result"] != "PASS":
            problems.append(f"{r['name']} failed")
    fires = sum(num(r["sva_errors"]) for r in runs)
    if fires:
        problems.append(f"{fires} assertion fires in passing runs")
    if "all" in cov_sets:
        h, n = cov_row("all")["total"]
        if h < n:
            problems.append(f"merged coverage {h}/{n}")
    for s in cov_sets:
        if s == "all":
            continue
        c = cov_row(s)
        for g in PER_CONFIG:
            if c[g][0] < c[g][1]:
                problems.append(f"{s}: {g} coverage {c[g][0]}/{c[g][1]}")
    ok = not problems

    # ---- page
    L = ["# Regression results", ""]
    for m in a.meta:
        k, _, v = m.partition("=")
        L.append(f"- **{k}:** {v}")
    L += ["", f"**Verdict: {'SIGNED OFF' if ok else 'NOT SIGNED OFF'}**", ""]
    if problems:
        L += ["Open items:", ""] + [f"- {p}" for p in problems[:30]] + [""]

    tw = sum(num(r["writes_ok"]) for r in runs)
    tr = sum(num(r["reads_ok"]) for r in runs)
    tb = sum(num(r["beats_ok"]) for r in runs)
    L += [f"{len(runs)} runs, {sum(r['result'] == 'PASS' for r in runs)} passed; "
          f"{tw:,} writes, {tr:,} reads and {tb:,} data beats checked; "
          f"{fires} assertion fires; {len(neg)} negative tests, "
          f"{sum(r['result'] == 'CAUGHT' for r in neg)} caught.", ""]

    L += ["## Runs", "", "| Set | Runs | Passed | Writes | Reads | Data beats | Longest run (simulated) |",
          "|---|---|---|---|---|---|---|"]
    for s, title in SET_NAMES.items():
        rr = [r for r in runs if r["set"] == s]
        if not rr:
            continue
        L.append(f"| {title} | {len(rr)} | {sum(r['result'] == 'PASS' for r in rr)} | "
                 f"{sum(num(r['writes_ok']) for r in rr):,} | {sum(num(r['reads_ok']) for r in rr):,} | "
                 f"{sum(num(r['beats_ok']) for r in rr):,} | {max(num(r['sim_end_us']) for r in rr):,} us |")
    L.append("")

    if neg:
        L += ["## Negative tests", "",
              "Each fault is injected on purpose; the run must fail, caught by the checker it is aimed at.", "",
              "| Test | Fault | Expected checker | Result | Scoreboard errors | Assertion errors |",
              "|---|---|---|---|---|---|"]
        what = {"neg_rdata": ("bit 0 of R data flipped at the DUT output", "scoreboard"),
                "neg_aw_unstable": ("AW address changed while VALID=1, READY=0", "handshake SVA only"),
                "neg_ptr_glitch": ("2 bits of a crossing gray pointer flipped for one cycle", "CDC SVA only")}
        for r in neg:
            f, c = what.get(r["name"], ("", ""))
            L.append(f"| `{r['name']}` | {f} | {c} | {r['result']} | {r['bad']} | {r['sva_errors']} |")
        L.append("")

    configs = sorted({config_of(r) for r in runs}, key=lambda c: (c.startswith("orig"), c))
    L += ["## FIFO full, per configuration", "",
          "Runs in which each DUT FIFO was full at least once (VALID=1, READY=0 at its input).", "",
          "| Configuration | Runs | " + " | ".join(ch for ch, _ in CHANNELS) + " | All five |",
          "|---|---|" + "---|" * (len(CHANNELS) + 1)]
    for c in configs:
        rr = [r for r in runs if config_of(r) == c]
        cells = [str(sum(1 for r in rr if num(r[k]) > 0)) for _, k in CHANNELS]
        all5 = sum(1 for r in rr if all(num(r[k]) > 0 for _, k in CHANNELS))
        L.append(f"| {c} | {len(rr)} | " + " | ".join(cells) + f" | {all5} |")
    L.append("")

    if cov_sets:
        L += ["## Functional coverage", "",
              "Bins hit / bins in the model (tb/uvm/axi_coverage.svh), merged over the runs of each configuration.", "",
              "| Configuration | " + " | ".join(GROUPS) + " | Total |", "|---|" + "---|" * (len(GROUPS) + 1)]
        for s in cov_sets:
            c = cov_row(s)
            L.append(f"| {s} | " + " | ".join(f"{c[g][0]}/{c[g][1]}" for g in GROUPS) +
                     f" | {c['total'][0]}/{c['total'][1]} ({100.0 * c['total'][0] / max(c['total'][1], 1):.0f}%) |")
        L.append("")
        holes = [c["bin"] for c in cov if "all" in c and num(c["all"]) == 0]
        L += [f"Bins never hit over all runs: {', '.join(holes) if holes else 'none'}.", ""]

    open(a.out, "w").write("\n".join(L) + "\n")
    print(f"== {'SIGNED OFF' if ok else 'NOT SIGNED OFF'}" + ("" if ok else ": " + "; ".join(problems[:5])))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
