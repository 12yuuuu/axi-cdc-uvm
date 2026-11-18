#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# From the pulp-platform/axi#294 FPGA study (same author), used unchanged here
# except for paths.
"""Negative-fixture self-test for tools/fpga/check_cdc.py.

Usage: python3 tools/fpga/test_check_cdc.py <output_files dir that PASSES> --bundles N --bits B
Copies the report directory into a temp dir once per mutation, applies one
defect, and requires check_cdc.py to FAIL (exit 1) on each; the unmodified
copy must PASS. Exit 0 only if every mutation is caught. run_sweep.sh /
run_fifo_synth.sh run this on the first build that passes, so a checker
that has gone blind fails the sweep. 
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

def run_checker(d, bundles, bits):
    p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "check_cdc.py"), d, "--bundles", str(bundles), "--bits", str(bits)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def mutate(src, name, fn):
    d = tempfile.mkdtemp(prefix=f"ccdc_{name}_")
    for f in os.listdir(src): shutil.copy(os.path.join(src, f), d)
    fn(d)
    return d

def edit(d, fname, fn):
    p = os.path.join(d, fname); s = open(p, errors="replace").read(); s2 = fn(s)
    assert s2 != s, f"mutation did not change {fname}"
    open(p, "w").write(s2)

NET_ROW = re.compile(r"^;\s*--\s*;\s*([-\d.]+)\s*;\s*([\d.]+)\s*;\s*([\d.]+)\s*;\s*(\S+)\s*;\s*(\S+)\s*;.*$", re.M)

def net_rows(s):
    """all net-delay rows as (full_line, from, to)"""
    return [(m.group(0), m.group(4), m.group(5)) for m in NET_ROW.finditer(s)]

def row_with_bit(s, bit):
    return next(r for r in net_rows(s) if re.search(r"ptr_q\[%d\]$" % bit, r[1]))

def ptr_prefix(node):
    return node[:node.index("|i_src_ptr|") if "|i_src_ptr|" in node else node.index("|i_dst_ptr|")]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir"); ap.add_argument("--bundles", type=int, required=True); ap.add_argument("--bits", type=int, required=True)
    a = ap.parse_args()
    rc, out = run_checker(a.outdir, a.bundles, a.bits)
    if rc != 0:
        print("baseline does not PASS; self-test needs a passing report directory:\n" + out); sys.exit(2)
    has_data = any(l.startswith("group kind=data_") for l in open(os.path.join(a.outdir, "sta_extra_groups.rpt")))
    groups_txt = open(os.path.join(a.outdir, "sta_extra_groups.rpt")).read()
    parents = re.findall(r"^group kind=wptr parent=(\S+)", groups_txt, re.M)

    muts = {}
    # bits: drop one net row
    muts["drop_net_row"] = lambda d: edit(d, "sta_extra_net_delay.rpt", lambda s: s.replace(net_rows(s)[0][0] + "\n", "", 1))
    # bit identity: the bit-1 row of some bundle becomes a second copy of its bit-0 row
    def dup_bit(s):
        r0 = row_with_bit(s, 0); r1 = next(r for r in net_rows(s) if r[1] == r0[1].replace("[0]", "[1]"))
        return s.replace(r1[0], r0[0], 1)
    muts["duplicate_bit"] = lambda d: edit(d, "sta_extra_net_delay.rpt", dup_bit)
    # wrong destination stage: bit 0 landing on gen_sync[1]
    def wrong_stage(s):
        r0 = row_with_bit(s, 0); return s.replace(r0[0], r0[0].replace("gen_sync[0]", "gen_sync[1]"), 1)
    muts["wrong_sync_stage"] = lambda d: edit(d, "sta_extra_net_delay.rpt", wrong_stage)
    # cross-FIFO: a bit lands in the synchronizer of another FIFO (needs >= 2 FIFOs)
    if len(parents) >= 2:
        def cross_fifo(s):
            rows = net_rows(s); a0 = rows[0]
            b = next(r for r in rows if ptr_prefix(r[2]) != ptr_prefix(a0[2]))
            new_to = ptr_prefix(b[2]) + a0[2][len(ptr_prefix(a0[2])):]
            return s.replace(a0[0], a0[0].replace(a0[2], new_to), 1)
        muts["cross_fifo_landing"] = lambda d: edit(d, "sta_extra_net_delay.rpt", cross_fifo)
    # corner handling: drop the last corner of the net-delay report
    def drop_corner(s):
        i = s.rfind("axi294_corner:"); assert i > 0; return s[:i]
    muts["missing_corner"] = lambda d: edit(d, "sta_extra_net_delay.rpt", drop_corner)
    muts["renamed_corner"] = lambda d: edit(d, "sta_extra_max_skew.rpt", lambda s: s.replace("axi294_corner: ", "axi294_corner: X ", 1))
    # slacks
    muts["negative_net_slack"] = lambda d: edit(d, "sta_extra_net_delay.rpt", lambda s: re.sub(r"^(;\s*--\s*;\s*)([\d.]+)", r"\1-0.100", s, count=1, flags=re.M))
    muts["negative_skew_slack"] = lambda d: edit(d, "sta_extra_max_skew.rpt", lambda s: re.sub(r"^(;\s*set_max_skew\s*;\s*)([\d.]+)", r"\1-0.100", s, count=1, flags=re.M))
    # cut paths: an unclassified crossing, and a count mismatch between corners
    muts["unconstrained_cut_path"] = lambda d: edit(d, "sta_extra_cut_paths.rpt", lambda s: s.replace("axi294_cut_paths: dst_clk->src_clk", "; 1.000 ; top|some_ctrl_q[0] ; top|other_q[0] ; src_clk ; dst_clk ; 3.333 ; 0.0 ; 1.0 ; x ;\naxi294_cut_paths: dst_clk->src_clk", 1))
    muts["cut_count_differs"] = lambda d: edit(d, "sta_extra_cut_paths.rpt", lambda s: re.sub(r"(axi294_cut_paths: src_clk->dst_clk pairs=)(\d+)", lambda m: m.group(1) + str(int(m.group(2)) + 1), s, count=1))
    # F1: listing truncated / one direction undeclared / a row repeated (counts preserved)
    muts["missing_cut_rows"] = lambda d: edit(d, "sta_extra_cut_paths.rpt", lambda s: re.sub(r"^;\s*[-\d.]+\s*;[^\n]*\n", "", s, flags=re.M))
    muts["missing_cut_direction"] = lambda d: edit(d, "sta_extra_cut_paths.rpt", lambda s: re.sub(r"^axi294_cut_paths: dst_clk->src_clk[^\n]*\n", "", s, flags=re.M))
    def dup_cut_row(s):
        rows = re.findall(r"^;\s*[-\d.]+\s*;[^\n]*$", s, re.M)
        same_dir = [r for r in rows if re.search(r";\s*src_clk\s*;\s*dst_clk\s*;", r)]
        assert len(same_dir) >= 2
        return s.replace(same_dir[1] + "\n", same_dir[0] + "\n", 1)
    muts["duplicate_cut_row"] = lambda d: edit(d, "sta_extra_cut_paths.rpt", dup_cut_row)
    # F2: every skew group replaced by a copy of the first one (count unchanged, identities lost)
    def dup_skew(s):
        parts = re.split(r"(?=^axi294_corner:)", s, flags=re.M)
        for i, part in enumerate(parts):
            first = re.search(r"^;\s*set_max_skew\s*;.*$", part, re.M)
            if first: parts[i] = re.sub(r"^;\s*set_max_skew\s*;.*$", lambda _: first[0], part, flags=re.M)
        return "".join(parts)
    muts["duplicate_skew_group"] = lambda d: edit(d, "sta_extra_max_skew.rpt", dup_skew)
    # F3: all four extra reports agree on a corner name that the main report does not have
    def rename_everywhere(d):
        for name in ("net_delay", "max_skew", "data_delay", "cut_paths"):
            edit(d, f"sta_extra_{name}.rpt", lambda s: s.replace("axi294_corner: ", "axi294_corner: Invented ", 1))
    muts["corner_not_in_main_report"] = rename_everywhere
    # groups / data coverage
    muts["missing_groups_file"] = lambda d: os.remove(os.path.join(d, "sta_extra_groups.rpt"))
    muts["fewer_pointer_groups"] = lambda d: edit(d, "sta_extra_groups.rpt", lambda s: re.sub(r"^group kind=rptr.*\n", "", s, count=1, flags=re.M))
    muts["hidden_fallback_group"] = lambda d: edit(d, "sta_extra_groups.rpt", lambda s: s + f"group kind=data_fallback parent={parents[0]} from={parents[0]}|mem[*][*] to={parents[0]}|rdata_q* n_from=28 n_to=7\n")
    if has_data:
        muts["data_group_uncovered"] = lambda d: edit(d, "sta_extra_data_delay.rpt", lambda s: re.sub(r"(axi294_group: data_\S+ \S+ pairs=)(\d+)", r"\g<1>0", s))
        muts["data_group_partial"] = lambda d: edit(d, "sta_extra_data_delay.rpt", lambda s: re.sub(r"(axi294_group: data_\S+ \S+ pairs=)(\d+)", lambda m: m.group(1) + str(int(m.group(2)) - 1), s))
        muts["data_group_line_missing"] = lambda d: edit(d, "sta_extra_data_delay.rpt", lambda s: re.sub(r"^axi294_group: data_.*\n", "", s, count=1, flags=re.M))
        def dd_failing(s):
            i = s.index("; Setup Data Delay Summary")
            return s[:i] + re.sub(r"^(;\s*\w+\s*;\s*[-\d.]+\s*;\s*[-\d.]+\s*;\s*)0(\s*;)", r"\g<1>1\2", s[i:], count=1, flags=re.M)
        sta = next(f for f in os.listdir(a.outdir) if f.endswith(".sta.rpt"))
        muts["data_delay_failing_endpoint"] = lambda d: edit(d, sta, dd_failing)
    else:
        muts["unexplained_data_delay_total"] = lambda d: edit(d, "sta_extra_data_delay.rpt", lambda s: s.replace("axi294_data_delay_total: pairs=0", "axi294_data_delay_total: pairs=3", 1))

    bad = []
    for name, fn in muts.items():
        try:
            d = mutate(a.outdir, name, fn)
        except AssertionError as e:
            bad.append(f"{name}: could not apply ({e})"); continue
        rc, out = run_checker(d, a.bundles, a.bits)
        caught = rc != 0
        reason = next((l.strip() for l in out.splitlines() if l.strip().startswith("FAIL:")), "")
        print(f"  {'caught ' if caught else 'MISSED '} {name:28s} {reason[:110]}")
        if not caught: bad.append(name)
        shutil.rmtree(d, ignore_errors=True)
    print(f"test_check_cdc: {len(muts) - len(bad)}/{len(muts)} defects caught")
    if bad:
        print("  NOT CAUGHT:", ", ".join(bad)); sys.exit(1)

if __name__ == "__main__":
    main()
