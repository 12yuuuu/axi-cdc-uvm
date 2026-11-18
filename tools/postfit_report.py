#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Results page and verdict of the post-fit simulation (sim/postfit.sh).

    python3 tools/postfit_report.py LOGDIR [--meta KEY=VALUE ...]

LOGDIR holds summary.csv (one row per run, sim/common.sh format; set
"pf_rtl" or "pf_gate"), trace_compare.csv (pairs _rtl_ / _gate_),
quartus_summary.txt, netlist_ports.txt, check_cdc.log/.rc and
check_cdc_selftest.log/.rc (exit codes). Writes LOGDIR/results.md.

Verdict, post-fit simulation: every planned test ran on the RTL and on the
netlist, every run passed with an accepted exit status and 0 assertion
fires, and every pair has the same transactions. Same order and equal
cycle counts are reported (a functional netlist should match the RTL cycle
by cycle). Verdict, CDC timing: tools/fpga/check_cdc.py passed and its
self-test caught every planted defect. Exit code 0 only if both pass.
"""
import argparse
import csv
import os
import sys

CYCLE_KEYS = ["writes_ok", "reads_ok", "beats_ok", "wbeats_ok", "resp_err_ok", "src_stall_aw", "src_stall_w",
              "src_stall_ar", "dst_stall_b", "dst_stall_r", "sim_end_us"]


def read(path):
    return open(path, errors="replace").read() if os.path.exists(path) else ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logdir")
    ap.add_argument("--meta", action="append", default=[])
    ap.add_argument("--planned", type=int, required=True, help="number of tests run on each model")
    a = ap.parse_args(argv)
    d = a.logdir
    rows = list(csv.DictReader(open(os.path.join(d, "summary.csv")))) if os.path.exists(os.path.join(d, "summary.csv")) else []
    pairs = list(csv.DictReader(open(os.path.join(d, "trace_compare.csv")))) \
        if os.path.exists(os.path.join(d, "trace_compare.csv")) else []
    rtl = {r["name"]: r for r in rows if r.get("set") == "pf_rtl"}
    gate = {r["name"]: r for r in rows if r.get("set") == "pf_gate"}

    problems = []
    if len(rtl) != a.planned or len(gate) != a.planned:
        problems.append(f"{len(rtl)} RTL and {len(gate)} netlist runs, {a.planned} each planned")
    for r in rows:
        if r.get("result") != "PASS":
            problems.append(f"{r['name']} failed")
        if r.get("exit_ok") != "1":
            problems.append(f"{r['name']}: simulator exit status {r.get('exit_code')} not accepted")
        if r.get("sva_errors") not in ("0", ""):
            problems.append(f"{r['name']}: {r.get('sva_errors')} assertion fires")
    if len(pairs) != a.planned:
        problems.append(f"{len(pairs)} trace pairs, {a.planned} planned")
    for p in pairs:
        if p.get("same_transactions") != "1":
            problems.append(f"traces differ: {p.get('ram')} vs {p.get('orig')}")
    cycle_same = 0
    for name, g in gate.items():
        r = rtl.get(name.replace("_gate_", "_rtl_", 1))
        if r and all(r.get(k) == g.get(k) for k in CYCLE_KEYS):
            cycle_same += 1
    ports = read(os.path.join(d, "netlist_ports.txt"))
    cdc = read(os.path.join(d, "check_cdc.log"))
    selftest = read(os.path.join(d, "check_cdc_selftest.log"))
    rc = lambda f: read(os.path.join(d, f)).strip()
    cdc_ok = rc("check_cdc.rc") == "0" and "  PASS:" in cdc
    st_lines = [ln for ln in selftest.splitlines() if ln.strip()]
    st_ok = rc("check_cdc_selftest.rc") == "0" and "defects caught" in selftest
    sim_ok = not problems
    ok = sim_ok and cdc_ok and st_ok

    L = ["# Post-fit simulation and CDC timing", ""]
    for m in a.meta:
        k, _, v = m.partition("=")
        L.append(f"- **{k}:** {v}")
    L += ["", f"**Post-fit simulation: {'PASS' if sim_ok else 'FAIL'}**  ",
          f"**CDC timing constraints: {'PASS' if cdc_ok and st_ok else 'FAIL'}**", ""]
    if problems:
        L += ["Open items:", ""] + [f"- {p}" for p in problems[:30]] + [""]

    L += ["## Quartus", "", "```", read(os.path.join(d, "quartus_summary.txt")).strip(), "```", "",
          "Netlist top-level ports (`axi_cdc_ram_flat`):", "", "```", ports.strip(), "```", ""]

    L += ["## Same tests on the RTL and on the post-fit netlist", "",
          "Each test runs twice with the same seed: once on the RTL `axi_cdc_ram`, once on the Quartus "
          "post-fit functional netlist (Arria 10 atoms, zero delay; timing is covered by static timing "
          "analysis, not by this simulation). The scoreboard, the reference model and the handshake "
          "assertions check both runs; the CDC assertions are bound to RTL modules and do not apply "
          "to the netlist.", "",
          "| Test | Seed | RTL | Netlist | Writes | Reads | Read beats | Same transactions | Same order | "
          "Same cycle counts |", "|---|---|---|---|---|---|---|---|---|---|"]
    pmap = {p.get("orig"): p for p in pairs}
    for name in sorted(gate):
        g = gate[name]
        r = rtl.get(name.replace("_gate_", "_rtl_", 1), {})
        p = pmap.get(name, {})
        same_cyc = "yes" if r and all(r.get(k) == g.get(k) for k in CYCLE_KEYS) else "no"
        L.append(f"| `{g.get('test')}` | {g.get('seed')} | {r.get('result', '-')} | {g.get('result')} | "
                 f"{g.get('writes_ok')} | {g.get('reads_ok')} | {g.get('beats_ok')} | "
                 f"{'yes' if p.get('same_transactions') == '1' else 'no'} | "
                 f"{'yes' if p.get('same_order') == '1' else 'no'} | {same_cyc} |")
    L += ["", f"{sum(p.get('same_transactions') == '1' for p in pairs)} of {len(pairs)} pairs with the same "
          f"transactions (multiset of trace lines: every request field, 64-bit hashes of data and responses); "
          f"{sum(p.get('same_order') == '1' for p in pairs)} also in the same order; {cycle_same} with identical "
          "transaction, beat and stall counts and end time.", ""]

    L += ["## CDC timing constraints", "",
          "`tools/fpga/constraints.sdc` cuts the two clocks into asynchronous groups and bounds every "
          "crossing instead: `set_net_delay` and `set_max_skew` on each gray-pointer bundle, "
          "`set_data_delay` on data crossings in fabric registers. `tools/fpga/check_cdc.py` reads the "
          "Timing Analyzer reports of every corner and fails unless every bundle and data group is "
          "constrained and met, and every path cut by the clock groups is one of them; its self-test "
          "plants defects in copies of the same reports and must catch each one.", "",
          "```", cdc.strip()[-3000:], "```", "", "Self-test:", "", "```", "\n".join(st_lines[-3:]), "```", ""]
    with open(os.path.join(d, "results.md"), "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"== post-fit simulation {'PASS' if sim_ok else 'FAIL'}; CDC timing {'PASS' if cdc_ok and st_ok else 'FAIL'}"
          + ("" if ok else ": " + "; ".join(problems[:4])))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
