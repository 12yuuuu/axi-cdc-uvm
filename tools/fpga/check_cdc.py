#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# From the pulp-platform/axi#294 FPGA study (same author), used unchanged here
# except for paths.
"""Check that the CDC constraints cover every crossing, in every corner.

Usage: python3 tools/fpga/check_cdc.py <output_files dir> --bundles N --bits B [--corners C]

Reads the reports written by tools/fpga/sta_extra.tcl:
  sta_extra_groups.rpt      CDC groups discovered from the netlist (independent of the SDC)
  sta_extra_net_delay.rpt   set_net_delay results, one marked block per corner
  sta_extra_max_skew.rpt    set_max_skew results, one marked block per corner
  sta_extra_data_delay.rpt  set_data_delay coverage: total + per data group, per corner
  sta_extra_cut_paths.rpt   every src<->dst path cut by the clock groups (corner 0 listing)
  *.sta.rpt                 Setup Data Delay Summary / Setup Summary / Hold Summary

Checks (any failure -> exit 1, reasons printed):
  corners   every multi-corner report has the same list of >= 1 distinct named corners,
            equal as a set to the main report's "Delay Models" list (--corners pins the
            expected number)
  bundles   per corner exactly N set_net_delay groups, each with exactly B nets whose
            source bits are {0..B-1} once each, whose destination is the matching
            gen_sync[bit].i_sync|reg_q[0] of the partner pointer of the SAME FIFO,
            all slacks >= 0; the same N groups appear in every corner; N set_max_skew
            groups per corner with exactly the same (from,to) identities as the net-delay
            groups, all slacks >= 0; the discovered pointer groups agree
  data      every discovered data group (original data array, or memory array the
            Fitter left in fabric registers) is covered by set_data_delay in every
            corner: covered (from,to) pairs == number of source registers, worst
            slack >= 0; the main report's Setup Data Delay Summary shows 0 failing
            endpoints; total covered pairs == sum over groups (nothing unexplained)
  cut       both directions are counted in every corner; the corner-0 listing has exactly
            as many rows per direction as declared and no duplicate (from,to) pair; every
            listed path is a pointer bit (present in the net-delay listing) or belongs to a
            covered data group; anything else fails
Prints worst net delay / skew, data-delay slacks, and the setup/hold summary of the
main report (informational: the SDC target is a probe, Fmax is read from the report).
"""
import argparse, glob, os, re, sys

def swap_src_dst(path):
    return "|".join(seg.replace("src", "\0").replace("dst", "src").replace("\0", "dst") for seg in path.split("|"))

def split_by_marker(path):
    """-> list of (corner_name, [lines]) using 'axi294_corner: <name>' marker lines"""
    if not os.path.exists(path): return None
    blocks, cur = [], None
    for line in open(path, errors="replace"):
        m = re.match(r"^axi294_corner:\s*(.+?)\s*$", line)
        if m:
            cur = (m.group(1), []); blocks.append(cur); continue
        if cur is not None: cur[1].append(line)
    return blocks

def parse_net_delay_block(lines):
    groups, grp = [], None
    for line in lines:
        m = re.match(r"^;\s*set_net_delay\s*;\s*([-\d.]+)\s*;\s*([\d.]+)\s*;\s*([\d.]+)\s*;\s*(.*?)\s*;\s*(.*?)\s*;", line)
        if m:
            grp = {"slack": float(m.group(1)), "req": float(m.group(2)), "act": float(m.group(3)),
                   "from": m.group(4), "to": m.group(5), "rows": []}
            groups.append(grp); continue
        m = re.match(r"^;\s*--\s*;\s*([-\d.]+)\s*;\s*([\d.]+)\s*;\s*([\d.]+)\s*;\s*(\S+)\s*;\s*(\S+)\s*;", line)
        if m and grp is not None:
            grp["rows"].append({"slack": float(m.group(1)), "act": float(m.group(3)), "from": m.group(4), "to": m.group(5)})
    return groups

def parse_max_skew_block(lines):
    """-> list of set_max_skew groups with their from/to collection patterns (same strings as the net-delay headers)"""
    out, seen_summary = [], False
    for line in lines:
        if line.startswith(";") and "Summary of Paths" in line: seen_summary = True; continue
        m = re.match(r"^;\s*set_max_skew\s*;\s*([-\d.]+)\s*;\s*([\d.]+)\s*;\s*([\d.]+)\s*;\s*(.*?)\s*;\s*(.*?)\s*;", line)
        if m and seen_summary:
            out.append({"slack": float(m.group(1)), "req": float(m.group(2)), "act": float(m.group(3)),
                        "from": m.group(4), "to": m.group(5)})
    return out

def parse_groups(path):
    if not os.path.exists(path): return None
    groups = []
    for line in open(path, errors="replace"):
        m = re.match(r"^group kind=(\S+) parent=(\S+) from=(.*?) to=(.*?) n_from=(\d+) n_to=(\d+)\s*$", line)
        if m:
            groups.append({"kind": m.group(1), "parent": m.group(2), "from": m.group(3), "to": m.group(4),
                           "n_from": int(m.group(5)), "n_to": int(m.group(6))})
    return groups

def parse_data_delay_block(lines):
    total, per_group, rows = None, [], []
    for line in lines:
        m = re.match(r"^axi294_data_delay_total:\s*pairs=(\d+)\s*worst=(\S+)", line)
        if m: total = (int(m.group(1)), m.group(2)); continue
        m = re.match(r"^axi294_group:\s*(\S+)\s+(\S+)\s+pairs=(\d+)\s*worst=(\S+)(?:\s+n_from=(\d+)\s+n_to=(\d+))?", line)
        if m:
            per_group.append({"kind": m.group(1), "parent": m.group(2), "pairs": int(m.group(3)), "worst": m.group(4)}); continue
        m = re.match(r"^;\s*([-\d.]+)\s*;\s*(\S+)\s*;\s*(\S+)\s*;\s*(\w+)\s*;\s*(\w+)\s*;", line)
        if m: rows.append({"slack": float(m.group(1)), "from": m.group(2), "to": m.group(3)})
    return total, per_group, rows

def parse_cut_block(lines):
    counts, rows = {}, []
    for line in lines:
        m = re.match(r"^axi294_cut_paths:\s*(\S+)->(\S+)\s*pairs=(\d+)", line)
        if m: counts[(m.group(1), m.group(2))] = int(m.group(3)); continue
        m = re.match(r"^;\s*([-\d.]+)\s*;\s*(\S+)\s*;\s*(\S+)\s*;\s*(\w+)\s*;\s*(\w+)\s*;", line)
        if m: rows.append({"slack": float(m.group(1)), "from": m.group(2), "to": m.group(3), "launch": m.group(4), "latch": m.group(5)})
    return counts, rows

def parse_sta_summaries(sta_rpt):
    """-> dict title -> list of (clock, slack, failing); titles: 'Setup Summary', 'Hold Summary', 'Setup Data Delay Summary'; plus 'models' list"""
    out, title, models, in_models = {}, None, [], False
    for line in open(sta_rpt, errors="replace"):
        m = re.match(r"^; (Setup Summary|Hold Summary|Setup Data Delay Summary)\s*;", line)
        if m: title = m.group(1); out.setdefault(title, []); continue
        if title:
            m = re.match(r"^;\s*(\w+)\s*;\s*([-\d.]+)\s*;\s*([-\d.]+)\s*;\s*(\d+)\s*;", line)
            if m: out[title].append((m.group(1), float(m.group(2)), int(m.group(4)))); continue
            if line.startswith("Delay Models:"): in_models = True; continue
            if in_models:
                if line.strip() == "": in_models = False; title = None
                elif not models or line.strip() not in models: models.append(line.strip())
                continue
            if line.startswith("+") or line.startswith(";") or line.strip() == "": continue
            title = None
    out["models"] = models
    return out

PTR_FROM = re.compile(r"^(?P<parent>.+)\|i_(?P<side>src|dst)_ptr\|(?P<reg>wptr_q|rptr_q)\[(?P<bit>\d+)\]$")
PTR_TO   = re.compile(r"^(?P<parent>.+)\|i_(?P<side>src|dst)_ptr\|gen_sync\[(?P<bit>\d+)\]\.i_sync\|reg_q\[0\]$")

def classify_pointer_row(frm, to):
    """-> (ok, reason, kind) for one net-delay / cut row claimed to be a pointer bit"""
    mf, mt = PTR_FROM.match(frm), PTR_TO.match(to)
    if not mf or not mt: return False, "not a pointer-bit path", None
    if mf.group("bit") != mt.group("bit"): return False, f"bit {mf.group('bit')} lands on sync stage of bit {mt.group('bit')}", None
    if mf.group("reg") == "wptr_q":
        if mf.group("side") != "src" or mt.group("side") != "dst": return False, "wptr must go src_ptr -> dst_ptr", None
        exp_parent = swap_src_dst(mf.group("parent"))
    else:
        if mf.group("side") != "dst" or mt.group("side") != "src": return False, "rptr must go dst_ptr -> src_ptr", None
        exp_parent = swap_src_dst(mf.group("parent"))
    if mt.group("parent") not in (mf.group("parent"), exp_parent):
        return False, f"lands in another FIFO ({mt.group('parent')} vs {mf.group('parent')})", None
    return True, "", mf.group("reg")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir"); ap.add_argument("--bundles", type=int, required=True); ap.add_argument("--bits", type=int, required=True)
    ap.add_argument("--corners", type=int, default=0, help="expected number of corners (0 = any >= 1)")
    a = ap.parse_args()
    fails, info = [], []
    od = a.outdir
    def F(msg): fails.append(msg)

    groups = parse_groups(os.path.join(od, "sta_extra_groups.rpt"))
    nd = split_by_marker(os.path.join(od, "sta_extra_net_delay.rpt"))
    sk = split_by_marker(os.path.join(od, "sta_extra_max_skew.rpt"))
    dd = split_by_marker(os.path.join(od, "sta_extra_data_delay.rpt"))
    cut = split_by_marker(os.path.join(od, "sta_extra_cut_paths.rpt"))
    for name, blk in (("groups", groups), ("net_delay", nd), ("max_skew", sk), ("data_delay", dd), ("cut_paths", cut)):
        if blk is None: F(f"sta_extra_{name}.rpt missing")
    if fails:
        for f in fails: print("  FAIL:", f)
        sys.exit(1)

    # ---- corners -------------------------------------------------------------
    corner_names = [c for c, _ in nd]
    if not corner_names: F("no corner markers in net-delay report (old sta_extra.tcl?)")
    if len(set(corner_names)) != len(corner_names): F(f"duplicate corner names: {corner_names}")
    for name, blk in (("max_skew", sk), ("data_delay", dd), ("cut_paths", cut)):
        if [c for c, _ in blk] != corner_names: F(f"{name} corners {[c for c, _ in blk]} != net-delay corners {corner_names}")
    if a.corners and len(corner_names) != a.corners: F(f"{len(corner_names)} corners, expected {a.corners}")
    sta = glob.glob(os.path.join(od, "*.sta.rpt"))
    summ = parse_sta_summaries(sta[0]) if sta else {"models": []}
    if not sta: F("no *.sta.rpt (main Timing Analyzer report) found")
    norm = lambda n: " ".join(n.split()).lower()
    if summ["models"]:
        if set(map(norm, summ["models"])) != set(map(norm, corner_names)):
            F(f"corner names {corner_names} do not match the main report's delay models {summ['models']}")
    else:
        F("main report has no 'Delay Models' list to check the corner names against")

    # ---- discovered groups ---------------------------------------------------
    ptr_groups = [g for g in groups if g["kind"] in ("wptr", "rptr")]
    data_groups = [g for g in groups if g["kind"] in ("data_orig", "data_fallback")]
    if len(ptr_groups) != a.bundles: F(f"netlist discovery found {len(ptr_groups)} pointer groups, expected {a.bundles}")
    for g in ptr_groups:
        if g["n_from"] != a.bits or g["n_to"] != a.bits:
            F(f"pointer group {g['kind']} {g['parent']}: {g['n_from']} pointer bits / {g['n_to']} sync stages, expected {a.bits}")
    for g in data_groups:
        if g["n_from"] > 0 and g["n_to"] == 0: F(f"data group {g['kind']} {g['parent']}: {g['n_from']} source registers but no destination registers")
        if g["n_from"] == 0 and g["n_to"] > 0: F(f"data group {g['kind']} {g['parent']}: destination registers but no source registers")

    # ---- net delay per corner ------------------------------------------------
    worst_nd, worst_sk = 0.0, 0.0
    header_sets, ptr_rows_c0 = [], set()
    for ci, (cname, lines) in enumerate(nd):
        gs = parse_net_delay_block(lines)
        header_sets.append(sorted((g["from"], g["to"]) for g in gs))
        if len(gs) != a.bundles: F(f"net-delay corner '{cname}': {len(gs)} bundles, expected {a.bundles}")
        for g in gs:
            bits_seen = []
            if len(g["rows"]) != a.bits: F(f"net-delay corner '{cname}' bundle {g['from']} -> {g['to']}: {len(g['rows'])} nets, expected {a.bits}")
            for r in g["rows"]:
                worst_nd = max(worst_nd, r["act"])
                if r["slack"] < 0: F(f"net-delay violation {r['from']} -> {r['to']}: slack {r['slack']}")
                ok, why, kind = classify_pointer_row(r["from"], r["to"])
                if not ok: F(f"net-delay corner '{cname}' row {r['from']} -> {r['to']}: {why}")
                else:
                    bits_seen.append(int(PTR_FROM.match(r["from"]).group("bit")))
                if ci == 0: ptr_rows_c0.add((r["from"], r["to"]))
            if sorted(bits_seen) != list(range(a.bits)) and len(g["rows"]) == a.bits:
                F(f"net-delay corner '{cname}' bundle {g['from']}: bits {sorted(bits_seen)} are not 0..{a.bits-1} once each")
    if header_sets and any(h != header_sets[0] for h in header_sets[1:]): F("net-delay bundles differ between corners")
    if header_sets and len(set(header_sets[0])) != len(header_sets[0]): F("duplicate net-delay bundle headers within a corner")
    for ci, (cname, lines) in enumerate(sk):
        gs = parse_max_skew_block(lines)
        if len(gs) != a.bundles: F(f"max-skew corner '{cname}': {len(gs)} bundles, expected {a.bundles}")
        ids = [(g["from"], g["to"]) for g in gs]
        if len(set(ids)) != len(ids): F(f"max-skew corner '{cname}': duplicate skew groups {sorted(set(i for i in ids if ids.count(i) > 1))}")
        if ci < len(header_sets) and sorted(set(ids)) != header_sets[ci]:
            F(f"max-skew corner '{cname}': skew groups {sorted(set(ids))} differ from the net-delay bundles {header_sets[ci]}")
        for g in gs:
            worst_sk = max(worst_sk, g["act"])
            if g["slack"] < 0: F(f"max-skew violation in corner '{cname}' ({g['from']} -> {g['to']}): slack {g['slack']}")

    # ---- data delay per corner -----------------------------------------------
    dd_lines = []
    for ci, (cname, lines) in enumerate(dd):
        total, per_group, rows = parse_data_delay_block(lines)
        if total is None: F(f"data-delay corner '{cname}': no total line"); continue
        covered = {(p["kind"], p["parent"]): p for p in per_group}
        sum_pairs = 0
        for g in data_groups:
            if g["n_from"] == 0: continue
            p = covered.get((g["kind"], g["parent"]))
            if p is None: F(f"data-delay corner '{cname}': no coverage line for {g['kind']} {g['parent']}"); continue
            sum_pairs += p["pairs"]
            if p["pairs"] != g["n_from"]:
                F(f"data-delay corner '{cname}': {g['kind']} {g['parent']} covers {p['pairs']} (from,to) pairs, expected {g['n_from']} (one per source register)"
                  + (" -> NOT CONSTRAINED" if p["pairs"] == 0 else ""))
            try:
                if float(p["worst"]) < 0: F(f"data-delay corner '{cname}': {g['kind']} {g['parent']} worst slack {p['worst']}")
            except ValueError:
                if p["pairs"] > 0: F(f"data-delay corner '{cname}': {g['kind']} {g['parent']} worst slack unreadable: {p['worst']}")
        if total[0] != sum_pairs: F(f"data-delay corner '{cname}': {total[0]} covered pairs in total but groups account for {sum_pairs}")
        for r in rows:
            if r["slack"] < 0: F(f"data-delay path {r['from']} -> {r['to']}: slack {r['slack']}")
        if ci == 0:
            dd_lines = [f"{p['kind']} {p['parent'].split('|')[-1]}: {p['pairs']} pairs, worst {p['worst']} ns" for p in per_group]
    dds = summ.get("Setup Data Delay Summary", [])
    active_data = [g for g in data_groups if g["n_from"] > 0]
    if active_data:
        if not dds: F("data groups exist but the main report has no Setup Data Delay Summary")
        for clk, slack, failing in dds:
            if failing != 0 or slack < 0: F(f"Setup Data Delay Summary {clk}: slack {slack}, {failing} failing endpoints")
    elif dds:
        F("main report has a Setup Data Delay Summary but no data group was discovered (unexplained set_data_delay)")

    # ---- cut paths -----------------------------------------------------------
    cut_counts_all = []
    kinds = {"pointer": 0, "data_orig": 0, "data_fallback": 0}
    for ci, (cname, lines) in enumerate(cut):
        counts, rows = parse_cut_block(lines)
        cut_counts_all.append(counts)
        for d in (("src_clk", "dst_clk"), ("dst_clk", "src_clk")):
            if d not in counts: F(f"cut-paths corner '{cname}': no count line for {d[0]}->{d[1]}")
        if ci != 0: continue
        # the corner-0 listing must be complete: per direction as many rows as declared, every (from,to) pair once
        by_dir = {}
        for r in rows: by_dir[(r["launch"], r["latch"])] = by_dir.get((r["launch"], r["latch"]), 0) + 1
        for d, n in counts.items():
            if by_dir.get(d, 0) != n: F(f"cut-paths corner '{cname}': {by_dir.get(d, 0)} listed paths for {d[0]}->{d[1]} but {n} declared (listing truncated or missing)")
        for d in by_dir:
            if d not in counts: F(f"cut-paths corner '{cname}': listed paths for undeclared direction {d}")
        pairs = [(r["from"], r["to"]) for r in rows]
        if len(set(pairs)) != len(pairs): F(f"cut-paths corner '{cname}': {len(pairs) - len(set(pairs))} duplicate (from,to) rows")
        per_data_group = {}
        for r in rows:
            frm, to = r["from"], r["to"]
            ok, why, _ = classify_pointer_row(frm, to)
            if ok:
                kinds["pointer"] += 1
                if (frm, to) not in ptr_rows_c0: F(f"cut pointer path {frm} -> {to} is not in the net-delay listing (unconstrained)")
                continue
            g = None
            for cand in data_groups:
                P = cand["parent"]
                if cand["kind"] == "data_orig" and frm.startswith(P + "|i_src_data|data_q") and "a_data_q" in to and to.startswith(swap_src_dst(P) + "|i_dst_data|"):
                    g = cand; break
                if cand["kind"] == "data_fallback" and frm.startswith(P + "|mem[") and to.startswith(P + "|rdata_q["):
                    g = cand; break
            if g is None: F(f"cut path {frm} -> {to} ({r['launch']}->{r['latch']}) is neither a pointer bit nor a known data group: UNCONSTRAINED crossing"); continue
            kinds[g["kind"]] += 1
            per_data_group[(g["kind"], g["parent"])] = per_data_group.get((g["kind"], g["parent"]), 0) + 1
        if dd:
            total0, per_group0, _ = parse_data_delay_block(dd[0][1])
            cov0 = {(p["kind"], p["parent"]): p["pairs"] for p in per_group0}
            for key, n in per_data_group.items():
                pairs = cov0.get(key, 0)
                if n > pairs: F(f"cut listing has {n} {key[0]} paths for {key[1]} but only {pairs} are covered by set_data_delay")
    if cut_counts_all and any(c != cut_counts_all[0] for c in cut_counts_all[1:]): F(f"cut-path counts differ between corners: {cut_counts_all}")

    # ---- report ----------------------------------------------------------------
    print(f"check_cdc: corners {corner_names}; {a.bundles} bundles x {a.bits} bits; "
          f"worst net delay {worst_nd:.3f} ns, worst skew {worst_sk:.3f} ns")
    print(f"  data groups: {len(active_data)} ({', '.join(dd_lines) if dd_lines else 'none'})"
          + (f"; main report data-delay: " + ", ".join(f"{c} {s:+.3f} ns {f} failing" for c, s, f in dds) if dds else ""))
    print(f"  cut src<->dst paths (corner 0): pointer {kinds['pointer']}, data-array {kinds['data_orig']}, fabric-fallback {kinds['data_fallback']}"
          + (f"; counts per corner {cut_counts_all[0]}" if cut_counts_all else ""))
    for title in ("Setup Summary", "Hold Summary"):
        rows = summ.get(title, [])
        if rows: print(f"  {title} at SDC target (informational): " + ", ".join(f"{c} {s:+.3f} ns ({f} failing)" for c, s, f in rows))
    if fails:
        for f in fails: print("  FAIL:", f)
        sys.exit(1)
    print("  PASS: every pointer bit and every fabric data crossing is constrained in every corner; nothing cut is unaccounted for")

if __name__ == "__main__":
    main()
