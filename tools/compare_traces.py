#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Compare the transaction traces of axi_cdc_ram and axi_cdc runs.

    python3 tools/compare_traces.py TRACE_DIR -o trace_compare.csv [--pair _ram_d2_:_orig_d2_]

Every run started with +TRACE_FILE=<dir>/<name>.trace writes one line per
transaction finished at src (axi_scoreboard::trace_line): every request
field, a hash of the data, strobes and user bits, and a hash of the
responses. A pair is <x>_ram_d2_<y>.trace and <x>_orig_d2_<y>.trace (same
test, same seed, the two DUTs).

  same_transactions  1 if both files hold the same lines as a multiset.
                     This is the check for vplan F13. The completion order
                     may differ: the DUTs differ by a cycle or so, and AXI
                     only orders responses with the same ID.
  same_order         1 if the lines are also in the same order (for
                     information only).

--pair A:B changes the two name parts that make a pair (sim/postfit.sh uses
_rtl_:_gate_ for RTL vs. post-fit netlist). A missing partner or an empty
file counts as different. Exit code 0 if every pair has the same
transactions and there is at least one pair.
"""
import argparse
import collections
import csv
import glob
import os
import sys

RAM, ORIG = "_ram_d2_", "_orig_d2_"


def read(path):
    if not os.path.exists(path):
        return None
    with open(path, errors="replace") as f:
        return [ln.strip() for ln in f if ln.strip()]


def compare(ram, orig):
    """Return the CSV row for one pair (lists of lines, or None if missing)."""
    row = dict(n_ram=-1 if ram is None else len(ram), n_orig=-1 if orig is None else len(orig),
               same_transactions="0", same_order="0", first_diff="")
    if ram is None or orig is None:
        row["first_diff"] = "trace file missing"
        return row
    if not ram or not orig:
        row["first_diff"] = "empty trace"
        return row
    a, b = collections.Counter(ram), collections.Counter(orig)
    if a == b:
        row["same_transactions"] = "1"
        row["same_order"] = "1" if ram == orig else "0"
    else:
        only_ram = sorted((a - b).elements())
        only_orig = sorted((b - a).elements())
        row["first_diff"] = ("ram only: " + only_ram[0]) if only_ram else ("orig only: " + only_orig[0])
    return row


def pairs_in(d, a=RAM, b=ORIG):
    names = {os.path.basename(p)[:-len(".trace")] for p in glob.glob(os.path.join(d, "*.trace"))}
    keys = set()
    for n in names:
        if a in n:
            keys.add(n)
        elif b in n:
            keys.add(n.replace(b, a, 1))
    return sorted(keys)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--pair", default=f"{RAM}:{ORIG}", help="the two name parts that make a pair")
    a = ap.parse_args(argv)
    pa, pb = a.pair.split(":", 1)
    rows = []
    for ram_name in pairs_in(a.dir, pa, pb):
        orig_name = ram_name.replace(pa, pb, 1)
        r = compare(read(os.path.join(a.dir, ram_name + ".trace")), read(os.path.join(a.dir, orig_name + ".trace")))
        rows.append(dict(ram=ram_name, orig=orig_name, **r))
    with open(a.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["ram", "orig", "n_ram", "n_orig", "same_transactions", "same_order",
                                          "first_diff"])
        w.writeheader()
        w.writerows(rows)
    same = sum(r["same_transactions"] == "1" for r in rows)
    print(f"== traces: {len(rows)} pairs, {same} with the same transactions, "
          f"{sum(r['same_order'] == '1' for r in rows)} also in the same order")
    for r in rows:
        if r["same_transactions"] != "1":
            print(f"   differ: {r['ram']} vs {r['orig']}: {r['first_diff'][:160]}")
    return 0 if rows and same == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
