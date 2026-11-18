#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Regression results page (Markdown) and the sign-off verdict.

    python3 tools/report.py SUMMARY.csv COVERAGE.csv -o results.md \\
        --goals tb/uvm/coverage_goals.txt --logs logs/regress \\
        --manifest logs/regress/manifest.csv \\
        --configs ram_d1,ram_d2,ram_d4,ram_d6,orig_d2 \\
        --neg neg_rdata,neg_bresp,neg_aw_unstable,neg_ptr_glitch,neg_slave_wrap \\
        [--traces trace_compare.csv] [--mode full|quick] [--meta KEY=VALUE ...]

Inputs: SUMMARY.csv has one row per run (sim/common.sh run_case; negative
tests have set "neg" and result CAUGHT or MISSED). COVERAGE.csv comes from
tools/merge_cov.py (hits of every bin per configuration, plus "all"). The
manifest is the plan that sim/regress.sh writes before it starts any run:
every run and negative test, with test, seed, configuration and whether the
run writes a trace.

Sign-off (docs/vplan.md, section 5). Anything missing counts as a failure,
never as a pass:
  * every planned run and negative test has exactly one result, with the
    planned test, seed and configuration, and there is no unplanned result;
  * every result has an accepted simulator exit status (exit_ok = 1);
  * every required negative test is present and CAUGHT;
  * every other run is PASS, with 0 assertion fires;
  * every run's log lists exactly the bins of the goal file, and so does
    COVERAGE.csv;
  * every required configuration has runs and a coverage column;
  * full mode: every bin is hit over all runs, and every configuration hits
    all of its txn, flow and order bins;
  * every trace pair in the plan was compared, no other pair, and every
    pair has the same transactions on both DUTs.
Quick mode skips the two coverage-completeness rules (too few runs).
Exit code 0 only if signed off. tools/test_report.py tests these rules.
"""
import argparse
import csv
import os
import re
import sys

GROUPS = ["txn", "flow", "order", "clk", "scen"]
PER_CONFIG = ["txn", "flow", "order"]
SET_NAMES = {
    "dir": "Directed tests",
    "clk": "Clock sweep",
    "depth": "FIFO full at every depth",
    "rand": "Constrained random, random clocks",
    "ooo": "Out-of-order, interleaving, error responses",
    "deep": "Targeted random, deep FIFOs",
}
NEG_TEXT = {
    "neg_rdata": ("bit 0 of R data flipped at the DUT output", "scoreboard (data)"),
    "neg_bresp": ("B response OKAY turned into SLVERR at the DUT output", "scoreboard (response)"),
    "neg_aw_unstable": ("AW address changed while VALID=1, READY=0", "handshake SVA only"),
    "neg_ptr_glitch": ("2 bits of a crossing gray pointer flipped for one cycle", "CDC SVA only"),
    "neg_slave_wrap": ("slave model forgets to wrap WRAP bursts", "reference model only"),
}
CHANNELS = [("AW", "src_stall_aw"), ("W", "src_stall_w"), ("AR", "src_stall_ar"),
            ("B", "dst_stall_b"), ("R", "dst_stall_r")]
COVBIN = re.compile(r"^\[COVBIN\] (\S+) (\d+)\s*$")


def num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def config_of(r):
    return ("ram" if r.get("use_ram") == "1" else "orig") + "_d" + str(r.get("log_depth"))


def read_goals(path):
    with open(path) as f:
        return {ln.strip() for ln in f if ln.strip() and not ln.startswith("#")}


def log_bins(path):
    bins = set()
    with open(path, errors="replace") as f:
        for ln in f:
            m = COVBIN.match(ln)
            if m:
                bins.add(m.group(1))
    return bins


def check(a):
    """Return (problems, data for the page)."""
    problems = []
    goals = read_goals(a.goals)
    if not goals:
        problems.append("goal file is empty")

    rows = list(csv.DictReader(open(a.summary))) if os.path.exists(a.summary) else []
    neg = [r for r in rows if r.get("set") == "neg"]
    runs = [r for r in rows if r.get("set") != "neg"]
    if not runs:
        problems.append("no runs in the summary")

    # negative tests
    for name in a.neg:
        hits = [r for r in neg if r["name"] == name]
        if not hits:
            problems.append(f"negative test {name} is missing")
        elif hits[0].get("result") != "CAUGHT":
            problems.append(f"negative test {name} was not caught")
    for r in neg:
        if r["name"] not in a.neg and r.get("result") != "CAUGHT":
            problems.append(f"negative test {r['name']} was not caught")

    # runs
    for r in runs:
        if r.get("result") != "PASS":
            problems.append(f"{r['name']} failed")
    fires = sum(num(r.get("sva_errors")) for r in runs)
    if fires:
        problems.append(f"{fires} assertion fires in passing runs")

    # coverage in every log
    for r in runs:
        path = os.path.join(a.logs, r["name"] + ".log")
        if not os.path.exists(path):
            problems.append(f"{r['name']}: log missing")
            continue
        b = log_bins(path)
        if not b:
            problems.append(f"{r['name']}: no coverage in the log")
        elif b != goals:
            problems.append(f"{r['name']}: coverage bins differ from the goal file "
                            f"({len(goals - b)} missing, {len(b - goals)} unknown)")

    # merged coverage
    cov = list(csv.DictReader(open(a.coverage))) if os.path.exists(a.coverage) else []
    cov_bins = {c["bin"] for c in cov}
    if not cov:
        problems.append("coverage file is missing or empty")
    elif cov_bins != goals:
        problems.append(f"coverage file: {len(goals - cov_bins)} bins missing, {len(cov_bins - goals)} unknown")
    cols = [k for k in (cov[0].keys() if cov else []) if k != "bin"]
    run_cfgs = {config_of(r) for r in runs}
    for c in a.configs:
        if c not in run_cfgs:
            problems.append(f"configuration {c}: no runs")
        if c not in cols:
            problems.append(f"configuration {c}: no coverage column")

    def hit(col, grp=None):
        ks = [x for x in cov if grp is None or x["bin"].split(".", 1)[0] == grp]
        return sum(1 for x in ks if num(x.get(col)) > 0), len(ks)

    if a.mode == "full" and cov:
        if "all" not in cols:
            problems.append("coverage file has no 'all' column")
        else:
            h, n = hit("all")
            if h < len(goals):
                problems.append(f"merged coverage {h}/{len(goals)}")
        for c in a.configs:
            if c in cols:
                for g in PER_CONFIG:
                    h, n = hit(c, g)
                    if n == 0 or h < n:
                        problems.append(f"{c}: {g} coverage {h}/{n}")

    # transaction traces (same seed, both DUTs)
    pairs = []
    if a.traces is not None:
        pairs = list(csv.DictReader(open(a.traces))) if os.path.exists(a.traces) else []
        if not pairs:
            problems.append("no trace pairs compared")
        for p in pairs:
            if p.get("same_transactions") != "1":
                problems.append(f"traces differ: {p.get('ram')} vs {p.get('orig')}")

    # the plan: every planned result present, nothing else, traces as planned
    plan = list(csv.DictReader(open(a.manifest))) if os.path.exists(a.manifest) else []
    if not plan:
        problems.append("run manifest is missing or empty")
    keys = ("set", "test", "seed", "use_ram", "log_depth")
    by_name = {}
    for r in rows:
        by_name.setdefault(r.get("name"), []).append(r)
    planned = {p["name"]: p for p in plan}
    missing = [n for n in planned if n not in by_name]
    extra = [n for n in by_name if n not in planned]
    twice = [n for n, rr in by_name.items() if len(rr) > 1]
    differ = [n for n, p in planned.items() if n in by_name
              and any(str(by_name[n][0].get(k)) != str(p.get(k)) for k in keys)]
    for what, names in (("planned runs have no result", missing), ("results are not in the plan", extra),
                        ("results appear more than once", twice), ("results do not match the plan", differ)):
        if names:
            problems.append(f"{len(names)} {what} (e.g. {', '.join(sorted(names)[:3])})")
    if rows and "exit_ok" not in rows[0]:
        problems.append("summary has no simulator exit status")
    else:
        bad_exit = [r["name"] for r in rows if r.get("exit_ok") != "1"]
        if bad_exit:
            problems.append(f"{len(bad_exit)} runs with a simulator exit status that is not accepted "
                            f"(e.g. {', '.join(sorted(bad_exit)[:3])})")
    want = set()
    for n, p in planned.items():
        if p.get("trace") == "1" and "_ram_d2_" in n:
            twin = n.replace("_ram_d2_", "_orig_d2_", 1)
            if planned.get(twin, {}).get("trace") != "1":
                problems.append(f"plan: trace run {n} has no twin")
            want.add((n, twin))
    for n, p in planned.items():
        if p.get("trace") == "1" and "_orig_d2_" in n and (n.replace("_orig_d2_", "_ram_d2_", 1), n) not in want:
            problems.append(f"plan: trace run {n} has no twin")
    got = {(p.get("ram"), p.get("orig")) for p in pairs}
    if want and a.traces is None:
        problems.append("the plan has trace pairs but no trace comparison was given")
    elif want:
        lost = want - got
        if lost:
            problems.append(f"{len(lost)} planned trace pairs were not compared "
                            f"(e.g. {', '.join(sorted(r for r, _ in lost)[:3])})")
        if got - want:
            problems.append(f"{len(got - want)} trace pairs are not in the plan")
    plan_info = (len(plan), sum(p.get("set") == "neg" for p in plan), len(missing), len(want))
    return problems, rows, neg, runs, cov, cols, pairs, goals, hit, plan_info


def page(a, problems, rows, neg, runs, cov, cols, pairs, goals, hit, plan_info):
    ok = not problems
    L = ["# Regression results", ""]
    for m in a.meta:
        k, _, v = m.partition("=")
        L.append(f"- **{k}:** {v}")
    L += ["", f"**Verdict: {'SIGNED OFF' if ok else 'NOT SIGNED OFF'}**", ""]
    if problems:
        L += ["Open items:", ""] + [f"- {p}" for p in problems[:40]] + [""]

    tw = sum(num(r.get("writes_ok")) for r in runs)
    tr = sum(num(r.get("reads_ok")) for r in runs)
    twb = sum(num(r.get("wbeats_ok")) for r in runs)
    trb = sum(num(r.get("beats_ok")) for r in runs)
    te = sum(num(r.get("resp_err_ok")) for r in runs)
    L += [f"{len(runs)} runs, {sum(r.get('result') == 'PASS' for r in runs)} passed; "
          f"{tw:,} writes ({twb:,} beats) and {tr:,} reads checked; {trb:,} read beats matched the "
          f"reference model; {te:,} error responses checked; "
          f"{sum(num(r.get('sva_errors')) for r in runs)} assertion fires; "
          f"{len(neg)} negative tests, {sum(r.get('result') == 'CAUGHT' for r in neg)} caught.", ""]
    n_plan, n_pneg, n_missing, n_pairs = plan_info
    codes = {}
    for r in rows:
        codes[r.get("exit_code", "?")] = codes.get(r.get("exit_code", "?"), 0) + 1
    code_txt = ", ".join(f"{c} ({n})" for c, n in sorted(codes.items()))
    L += [f"Plan: {n_plan - n_pneg} runs and {n_pneg} negative tests in the manifest, "
          f"{n_plan - n_missing} of {n_plan} with a result; {n_pairs} planned trace pairs. "
          f"Simulator exit status (count): {code_txt}; a non-zero status is accepted only when the "
          "log has the known `*E,IMPDLL`, no other error except assertion failures (judged by the "
          "verdict), and the run reached `$finish`.", ""]

    L += ["## Runs", "",
          "| Set | Runs | Passed | Writes | Write beats | Reads | Read beats checked | Error responses | Longest run (simulated) |",
          "|---|---|---|---|---|---|---|---|---|"]
    for s, title in SET_NAMES.items():
        rr = [r for r in runs if r.get("set") == s]
        if not rr:
            continue
        L.append(f"| {title} | {len(rr)} | {sum(r.get('result') == 'PASS' for r in rr)} | "
                 f"{sum(num(r.get('writes_ok')) for r in rr):,} | {sum(num(r.get('wbeats_ok')) for r in rr):,} | "
                 f"{sum(num(r.get('reads_ok')) for r in rr):,} | {sum(num(r.get('beats_ok')) for r in rr):,} | "
                 f"{sum(num(r.get('resp_err_ok')) for r in rr):,} | {max(num(r.get('sim_end_us')) for r in rr):,} us |")
    L.append("")

    if neg:
        L += ["## Negative tests", "",
              "Each fault is injected on purpose; the run must fail, caught by the checker it is aimed at.", "",
              "| Test | Fault | Expected checker | Result | Scoreboard errors | Assertion errors |",
              "|---|---|---|---|---|---|"]
        for r in neg:
            f, c = NEG_TEXT.get(r["name"], ("", ""))
            L.append(f"| `{r['name']}` | {f} | {c} | {r.get('result')} | {r.get('bad')} | {r.get('sva_errors')} |")
        L.append("")

    if pairs:
        same = sum(p.get("same_transactions") == "1" for p in pairs)
        L += ["## Trace comparison, same seed on both DUTs", "",
              f"{len(pairs)} pairs of runs (`axi_cdc_ram` vs. `axi_cdc`, same test and seed): "
              f"{same} with the same transactions, compared as a multiset of trace lines (every "
              "request field, a 64-bit hash of data, strobes and user bits, and a hash of the "
              f"responses); {sum(p.get('same_order') == '1' for p in pairs)} also in the same order. "
              "This is regression evidence, not a formal equivalence proof.", ""]

    configs = sorted({config_of(r) for r in runs}, key=lambda c: (c.startswith("orig"), c))
    L += ["## FIFO full, per configuration", "",
          "Runs in which each DUT FIFO was full at least once (VALID=1, READY=0 at its input).", "",
          "| Configuration | Runs | " + " | ".join(ch for ch, _ in CHANNELS) + " | All five |",
          "|---|---|" + "---|" * (len(CHANNELS) + 1)]
    for c in configs:
        rr = [r for r in runs if config_of(r) == c]
        cells = [str(sum(1 for r in rr if num(r.get(k)) > 0)) for _, k in CHANNELS]
        all5 = sum(1 for r in rr if all(num(r.get(k)) > 0 for _, k in CHANNELS))
        L.append(f"| {c} | {len(rr)} | " + " | ".join(cells) + f" | {all5} |")
    L.append("")

    if cov:
        L += ["## Functional coverage", "",
              f"Bins hit / bins in the model ({len(goals)} bins, tb/uvm/coverage_goals.txt), "
              "merged over the runs of each configuration.", "",
              "| Configuration | " + " | ".join(GROUPS) + " | Total |", "|---|" + "---|" * (len(GROUPS) + 1)]
        for c in cols:
            cells = []
            for g in GROUPS:
                h, n = hit(c, g)
                cells.append(f"{h}/{n}")
            h, n = hit(c)
            L.append(f"| {c} | " + " | ".join(cells) + f" | {h}/{n} ({100.0 * h / max(n, 1):.0f}%) |")
        L.append("")
        holes = [x["bin"] for x in cov if "all" in x and num(x["all"]) == 0]
        L += [f"Bins never hit over all runs: {', '.join(holes) if holes else 'none'}.", ""]
    return "\n".join(L) + "\n", ok


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("summary")
    ap.add_argument("coverage")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--goals", required=True)
    ap.add_argument("--logs", required=True)
    ap.add_argument("--configs", required=True, type=lambda s: [x for x in s.split(",") if x])
    ap.add_argument("--neg", required=True, type=lambda s: [x for x in s.split(",") if x])
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--traces")
    ap.add_argument("--mode", choices=["full", "quick"], default="full")
    ap.add_argument("--meta", action="append", default=[])
    a = ap.parse_args(argv)
    res = check(a)
    text, ok = page(a, *res)
    with open(a.out, "w") as f:
        f.write(text)
    problems = res[0]
    print(f"== {'SIGNED OFF' if ok else 'NOT SIGNED OFF'}" + ("" if ok else ": " + "; ".join(problems[:6])))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
