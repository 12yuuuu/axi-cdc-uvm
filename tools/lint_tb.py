#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Compile the whole testbench (RTL, UVM classes, SVA, tb_top) with slang.

    python3 tools/lint_tb.py --uvm /path/to/uvm-core/src

A second, free front end next to Xcelium: it elaborates the same file list
as sim/common.sh against the Accellera UVM library and fails on any error.
Warnings are counted, not fatal. Used by the CI workflow; needs pyslang.
"""
import argparse
import os
import re
import sys

import pyslang

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def file_list():
    """The SRC=( ... ) list of sim/common.sh, with $R and $T expanded."""
    with open(os.path.join(ROOT, "sim", "common.sh")) as f:
        text = f.read()
    body = re.search(r"^SRC=\((.*?)^\)", text, re.S | re.M).group(1)
    files = re.findall(r'"\$(R|T)/([^"]+)"', body)
    return [os.path.join(ROOT, "rtl" if d == "R" else "tb", p) for d, p in files]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uvm", required=True, help="uvm-core/src directory (contains uvm_pkg.sv)")
    a = ap.parse_args(argv)
    srcs = file_list()
    inc = [os.path.join(ROOT, p) for p in ("rtl/axi/include", "rtl/common_cells/include", "tb/uvm")]
    args = ["slang", "--top", "tb_top", "--timescale", "1ns/1ps", "-I", a.uvm]
    for i in inc:
        args += ["-I", i]
    args += [os.path.join(a.uvm, "uvm_pkg.sv")] + srcs

    d = pyslang.driver.Driver()
    d.addStandardArgs()
    if not d.parseCommandLine(" ".join(args), pyslang.driver.CommandLineOptions()) or not d.processOptions():
        print("slang: bad command line")
        return 2
    if not d.parseAllSources():
        print("slang: parse failed")
        return 1
    comp = d.createCompilation()
    diags = comp.getAllDiagnostics()

    eng = pyslang.DiagnosticEngine(comp.sourceManager)
    client = pyslang.TextDiagnosticClient()
    eng.addClient(client)
    errors = [dg for dg in diags if dg.isError()]
    for dg in errors:
        eng.issue(dg)
    if errors:
        print(client.getString())
    n_warn = len(diags) - len(errors)
    print(f"== slang: {len(srcs)} files + UVM, top tb_top: {len(errors)} errors, {n_warn} warnings")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
