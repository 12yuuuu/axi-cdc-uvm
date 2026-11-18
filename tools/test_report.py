#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Tests for tools/report.py and tools/compare_traces.py: incomplete or bad
results must never sign off, and different traces must never match.

    python3 tools/test_report.py      # exit code 0 if every case behaves
"""
import contextlib
import csv
import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import compare_traces  # noqa: E402
import report  # noqa: E402

GOALS = os.path.join(HERE, "..", "tb", "uvm", "coverage_goals.txt")
CONFIGS = ["ram_d1", "ram_d2", "ram_d4", "ram_d6", "orig_d2"]
NEGS = ["neg_rdata", "neg_bresp", "neg_aw_unstable", "neg_ptr_glitch", "neg_slave_wrap"]
FIELDS = ["name", "set", "test", "seed", "use_ram", "log_depth", "result", "writes_ok", "reads_ok",
          "beats_ok", "wbeats_ok", "resp_err_ok", "bad", "src_stall_aw", "src_stall_w", "src_stall_ar",
          "dst_stall_b", "dst_stall_r", "sva_errors", "sim_end_us"]


def complete():
    """A data set that must sign off."""
    goals = sorted(report.read_goals(GOALS))
    runs = []
    for c in CONFIGS:
        ram, depth = ("1", c[-1]) if c.startswith("ram") else ("0", c[-1])
        for s in (1, 2):
            runs.append(dict(name=f"rand_{c}_s{s}", set="rand", test="rand_cov_test", seed=str(s), use_ram=ram,
                             log_depth=depth, result="PASS", writes_ok="10", reads_ok="10", beats_ok="40",
                             wbeats_ok="40", resp_err_ok="0", bad="0", src_stall_aw="1", src_stall_w="1",
                             src_stall_ar="1", dst_stall_b="1", dst_stall_r="1", sva_errors="0", sim_end_us="5"))
    negs = [dict(name=n, set="neg", test="smoke_test", seed="1", use_ram="1", log_depth="2", result="CAUGHT",
                 bad="0", sva_errors="1") for n in NEGS]
    logs = {r["name"]: [f"[COVBIN] {g} 1" for g in goals] for r in runs}
    cov = {g: {c: 1 for c in CONFIGS + ["all"]} for g in goals}
    traces = [dict(ram="rand_ram_d2_s1", orig="rand_orig_d2_s1", same_transactions="1", same_order="1")]
    return dict(runs=runs, negs=negs, logs=logs, cov=cov, traces=traces, mode="full")


def run(d):
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "summary.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore", restval="")
            w.writeheader()
            for r in d["runs"] + d["negs"]:
                w.writerow(r)
        for name, lines in d["logs"].items():
            with open(os.path.join(tmp, name + ".log"), "w") as f:
                f.write("UVM_INFO some line\n" + "\n".join(lines) + "\n")
        with open(os.path.join(tmp, "coverage.csv"), "w", newline="") as f:
            if d["cov"]:
                cols = list(next(iter(d["cov"].values())).keys())
                w = csv.writer(f)
                w.writerow(["bin"] + cols)
                for b, v in d["cov"].items():
                    w.writerow([b] + [v[c] for c in cols])
        args = [os.path.join(tmp, "summary.csv"), os.path.join(tmp, "coverage.csv"),
                "-o", os.path.join(tmp, "results.md"), "--goals", GOALS, "--logs", tmp,
                "--configs", ",".join(CONFIGS), "--neg", ",".join(NEGS), "--mode", d["mode"]]
        if d["traces"] is not None:
            with open(os.path.join(tmp, "traces.csv"), "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=["ram", "orig", "same_transactions", "same_order"])
                w.writeheader()
                for p in d["traces"]:
                    w.writerow(p)
            args += ["--traces", os.path.join(tmp, "traces.csv")]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = report.main(args)
        return rc, out.getvalue()


def case(name, want, change):
    """want is None for a case that must sign off, or text the failure reason must contain."""
    d = complete()
    change(d)
    rc, out = run(d)
    if want is None:
        ok = rc == 0 and "== SIGNED OFF" in out
    else:
        ok = rc != 0 and "NOT SIGNED OFF" in out and want in out
    verdict = "signed off" if rc == 0 else "not signed off"
    print(f"  {'ok  ' if ok else 'FAIL'} {name}: {verdict}")
    if not ok:
        print("       " + (out.strip().splitlines() or [""])[-1])
    return ok


def drop_bins_but_one(d):            # the reviewer's case: coverage with 1 hit bin
    first = sorted(d["cov"])[0]
    d["cov"] = {first: d["cov"][first]}
    d["runs"] = d["runs"][:1]
    d["negs"] = d["negs"][:3]


def main():
    results = [
        case("complete results", None, lambda d: None),
        case("coverage file with one bin, one run, three negative tests", "negative test", drop_bins_but_one),
        case("empty coverage file", "coverage file is missing or empty", lambda d: d.update(cov={})),
        case("one bin missing from the coverage file", "1 bins missing", lambda d: d["cov"].pop(sorted(d["cov"])[5])),
        case("unknown bin in the coverage file", "1 unknown",
             lambda d: d["cov"].update({"txn.bogus.X": dict(next(iter(d["cov"].values())))})),
        case("a log without coverage lines", "no coverage in the log", lambda d: d["logs"].update({"rand_ram_d2_s1": []})),
        case("a log with one bin missing", "coverage bins differ",
             lambda d: d["logs"]["rand_ram_d4_s2"].pop(0)),
        case("a log file missing", "log missing", lambda d: d["logs"].pop("rand_orig_d2_s1")),
        case("a configuration without runs", "configuration ram_d6: no runs",
             lambda d: d.update(runs=[r for r in d["runs"] if not r["name"].startswith("rand_ram_d6")])),
        case("a configuration without a coverage column", "configuration ram_d4: no coverage column",
             lambda d: [v.pop("ram_d4") for v in d["cov"].values()]),
        case("a negative test missing", "negative test neg_rdata is missing", lambda d: d.update(negs=d["negs"][1:])),
        case("a negative test not caught", "neg_aw_unstable was not caught", lambda d: d["negs"][2].update(result="MISSED")),
        case("a failing run", "failed", lambda d: d["runs"][3].update(result="FAIL")),
        case("an assertion fire in a passing run", "assertion fires", lambda d: d["runs"][0].update(sva_errors="2")),
        case("a txn bin not hit in one configuration", "ram_d1: txn coverage 74/75",
             lambda d: d["cov"][[b for b in sorted(d["cov"]) if b.startswith("txn.")][0]].update(ram_d1=0)),
        case("a bin not hit over all runs", "merged coverage",
             lambda d: d["cov"][[b for b in sorted(d["cov"]) if b.startswith("scen.")][0]].update(all=0)),
        case("traces differ", "traces differ", lambda d: d["traces"][0].update(same_transactions="0")),
        case("no trace pairs", "no trace pairs", lambda d: d.update(traces=[])),
        case("quick mode, clock bins not hit", None,
             lambda d: (d.update(mode="quick"),
                        [v.update(all=0) for b, v in d["cov"].items() if b.startswith("clk.")])),
    ]
    results += trace_cases()
    print(f"{sum(results)}/{len(results)} cases behave as expected")
    return 0 if all(results) else 1


T1 = "W id=3 addr=00010000 len=3 size=3 burst=1 cache=0 prot=0 qos=0 region=0 user=1 data=1a2b3c4d resp=050c5d1f"
T2 = "R id=5 addr=00010040 len=0 size=2 burst=1 cache=2 prot=1 qos=0 region=0 user=0 data=99887766 resp=050c5d1f"
T3 = "R id=5 addr=00010040 len=0 size=2 burst=1 cache=2 prot=1 qos=0 region=0 user=0 data=99887767 resp=050c5d1f"


def tcase(name, ram, orig, want_same, want_order=None):
    with tempfile.TemporaryDirectory() as tmp:
        for tag, lines in (("ram", ram), ("orig", orig)):
            if lines is not None:
                with open(os.path.join(tmp, f"rand_{tag}_d2_s1.trace"), "w") as f:
                    f.write("".join(ln + "\n" for ln in lines))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = compare_traces.main([tmp, "-o", os.path.join(tmp, "t.csv")])
        with open(os.path.join(tmp, "t.csv")) as f:
            rows = list(csv.DictReader(f))
    ok = len(rows) == 1 and rows[0]["same_transactions"] == ("1" if want_same else "0") and (rc == 0) == want_same
    if want_order is not None:
        ok = ok and rows[0]["same_order"] == ("1" if want_order else "0")
    print(f"  {'ok  ' if ok else 'FAIL'} traces, {name}: {'same' if rc == 0 else 'different'}")
    return ok


def trace_cases():
    return [
        tcase("identical", [T1, T2], [T1, T2], True, True),
        tcase("same transactions, other order", [T1, T2], [T2, T1], True, False),
        tcase("one data hash differs", [T1, T2], [T1, T3], False),
        tcase("one transaction missing", [T1, T2], [T1], False),
        tcase("one transaction twice", [T1, T2, T2], [T1, T2], False),
        tcase("both empty", [], [], False),
        tcase("partner file missing", [T1, T2], None, False),
    ]


if __name__ == "__main__":
    sys.exit(main())
