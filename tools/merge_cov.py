#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Merge functional coverage over many simulation logs.

Every test prints one "[COVBIN] <bin> <hits>" line per coverage bin
(tb/uvm/axi_coverage.svh). This script adds up the hits of each bin over a
set of logs and reports, per set, how many bins were hit and which were not.

    python3 tools/merge_cov.py -o logs/stage7/coverage \\
        directed='logs/stage7/dir_*.log' rand='logs/stage7/v1_*.log'

A set is LABEL=GLOB (several globs: LABEL=GLOB1,GLOB2). The set "all" (every
log given) is added at the end. Writes OUT.md (tables + holes) and OUT.csv
(hits of every bin in every set) when -o is given.
"""
import argparse
import csv
import glob
import re
import sys

GROUPS = ["txn", "flow", "order", "clk", "scen"]
LINE = re.compile(r"^\[COVBIN\] (\S+) (\d+)\s*$")


def read_log(path):
    bins = {}
    with open(path, errors="replace") as f:
        for line in f:
            m = LINE.match(line)
            if m:
                bins[m.group(1)] = int(m.group(2))
    return bins


def merge(paths):
    total, used, empty = {}, 0, []
    for p in paths:
        b = read_log(p)
        if not b:
            empty.append(p)
            continue
        used += 1
        for k, v in b.items():
            total[k] = total.get(k, 0) + v
    return total, used, empty


def group_of(k):
    return k.split(".", 1)[0]


def summary(total):
    row = {}
    for g in GROUPS:
        ks = [k for k in total if group_of(k) == g]
        row[g] = (sum(1 for k in ks if total[k] > 0), len(ks))
    row["total"] = (sum(1 for v in total.values() if v > 0), len(total))
    return row


def pct(h, n):
    return 100.0 * h / n if n else 0.0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--out", help="write OUT.md and OUT.csv")
    ap.add_argument("sets", nargs="+", help="LABEL=GLOB[,GLOB...]")
    a = ap.parse_args()

    sets, every = [], []
    for s in a.sets:
        if "=" not in s:
            sys.exit("bad set (want LABEL=GLOB): " + s)
        label, pats = s.split("=", 1)
        paths = sorted({p for pat in pats.split(",") for p in glob.glob(pat)})
        sets.append((label, paths))
        every += paths
    sets.append(("all", sorted(set(every))))

    results = []
    for label, paths in sets:
        total, used, empty = merge(paths)
        results.append((label, total, used, empty))

    keys = sorted({k for _, t, _, _ in results for k in t})
    md = ["| set | logs | " + " | ".join(GROUPS) + " | total |",
          "|---|---|" + "---|" * (len(GROUPS) + 1)]
    for label, total, used, empty in results:
        row = summary(total)
        cells = [f"{h}/{n} ({pct(h, n):.0f}%)" for h, n in (row[g] for g in GROUPS + ["total"])]
        md.append(f"| {label} | {used} | " + " | ".join(cells) + " |")
    md.append("")
    for label, total, used, empty in results:
        holes = [k for k in sorted(total) if total[k] == 0]
        md.append(f"### {label}: {len(holes)} bins not hit")
        if empty:
            md.append(f"(no coverage lines in {len(empty)} log(s): {', '.join(empty[:5])}{' ...' if len(empty) > 5 else ''})")
        for g in GROUPS:
            gh = [k for k in holes if group_of(k) == g]
            if gh:
                md.append(f"- {g}: " + ", ".join(k.split('.', 1)[1] for k in gh))
        md.append("")
    text = "\n".join(md)
    print(text)

    if a.out:
        with open(a.out + ".md", "w") as f:
            f.write(text + "\n")
        with open(a.out + ".csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["bin"] + [label for label, _, _, _ in results])
            for k in keys:
                w.writerow([k] + [t.get(k, "") for _, t, _, _ in results])


if __name__ == "__main__":
    main()
