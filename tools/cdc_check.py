#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Structural clock-domain-crossing (CDC) check of the DUT netlist.

    python3 tools/cdc_check.py                 # all configurations, report in logs/cdc/
    python3 tools/cdc_check.py --self-test     # the checker on small designs with known faults

Yosys (with the slang frontend; `pip install yowasp-yosys`) elaborates
tools/cdc/cdc_top.sv into a flat word-level netlist (proc, flatten, opt,
memory -nomap). This script then looks at every flip-flop bit, memory port
and output bit, assigns each to the clock domain of its clock input, and
follows every input backwards through combinational cells to the sequential
elements it depends on. A crossing is any dependence on another domain.
Every crossing must fit one of three structures:

  SYNC  a synchronizer chain: the other domain's flop drives the first
        stage directly (no logic, so no glitch can be captured), the first
        stage drives only the second, and there are at least 2 stages.
        Bits launched from the same source register form one group; a group
        wider than one bit is safe only if the register is gray-coded. That
        cannot be seen in a netlist, so the report points to the SVA_GRAY
        assertion, which checks it in every simulation run.
  MEM   a dual-clock memory: write port and read port in different domains,
        every port's address, data and enable driven from its own domain only.
  MUX   a FIFO read multiplexer: other-domain storage flops reach the
        destination flop only through the data inputs of multiplexers whose
        select comes from the destination domain.
MEM and MUX are safe by the FIFO protocol (an entry is written only while
the synchronized read pointer shows it free and read only after the
synchronized write pointer shows it written); the report says so and points
to the simulation checks of that protocol.

Rules (each one is a violation):
  CDC-UNSYNC      other-domain data used without a synchronizer
  CDC-SYNC-LOGIC  combinational logic in front of a synchronizer
  CDC-SYNC-DEPTH  fewer than 2 synchronizer stages
  CDC-SYNC-FANOUT the first synchronizer stage drives more than the second
  CDC-RECONV      signals from different synchronized groups combined
  CDC-MUXSEL      a read multiplexer selected from the other domain
  CDC-MEMPORT     a memory port driven from another domain
  CDC-OUTPUT      an output that depends combinationally on another domain
  CDC-RESET       an asynchronous reset from another domain, or through logic
  CDC-CLOCK       a flop clocked by something other than a clock input
  CDC-STRUCTURE   counts differ from what the design must contain (5 FIFOs,
                  10 gray pointers, 2-stage synchronizers, 5 RAMs or 291
                  read-mux bits), so the check itself has lost track
Exit code 0 if no violations (and, in --self-test, if every test design
gives exactly the rules it expects).
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join("logs", "cdc")                       # relative to ROOT (Yosys/WASM sees only the cwd)
CONFIGS = [("ram_d1", 1, 1), ("ram_d2", 1, 2), ("ram_d4", 1, 4), ("ram_d6", 1, 6), ("orig_d2", 0, 2)]
FF = {"$dff", "$dffe", "$adff", "$adffe", "$aldff", "$aldffe", "$sdff", "$sdffe", "$sdffce", "$dffsr", "$dffsre"}
LATCH = {"$dlatch", "$adlatch", "$dlatchsr", "$sr"}
SELECT = {"$mux": "S", "$pmux": "S", "$bmux": "S", "$shiftx": "B", "$shift": "B", "$bwmux": "S", "$demux": "S"}
PASS = {"$pos", "$buf"}
KINDS = ["direct", "mux", "logic", "select"]            # increasing severity
SEV = {k: i for i, k in enumerate(KINDS)}


def worst(a, b):
    return a if SEV[a] >= SEV[b] else b


def port_domain(name):
    for d in ("src", "dst"):
        if name.startswith(d + "_"):
            return d
    return None


class Netlist:
    def __init__(self, path, top):
        mod = json.load(open(path))["modules"][top]
        self.ports, self.cells = mod["ports"], mod["cells"]
        self.name_of = {}                                   # bit -> readable name
        for n, v in sorted(mod["netnames"].items(), key=lambda kv: (kv[1].get("hide_name", 0), kv[0])):
            for i, b in enumerate(v["bits"]):
                if isinstance(b, int) and b not in self.name_of:
                    self.name_of[b] = n if len(v["bits"]) == 1 else f"{n}[{i}]"
        self.driver, self.loads = {}, {}
        self.clock = {}                                     # clock bit -> domain
        self.reset = {}                                     # reset bit -> domain
        for pn, p in self.ports.items():
            for i, b in enumerate(p["bits"]):
                if p["direction"] == "input":
                    self.driver[b] = ("in", pn, i)
                    if "clk" in pn:
                        self.clock[b] = port_domain(pn)
                    if "rst" in pn:
                        self.reset[b] = port_domain(pn)
                else:
                    self.loads.setdefault(b, []).append(("out", pn, i))
        for cn, c in self.cells.items():
            for port, bits in c["connections"].items():
                d = c["port_directions"][port]
                for i, b in enumerate(bits):
                    if not isinstance(b, int):
                        continue
                    if d == "output":
                        self.driver[b] = ("cell", cn, port, i)
                    else:
                        self.loads.setdefault(b, []).append(("cell", cn, port, i))
        self.ffbit = {}                                     # Q bit -> (cell, i)
        for cn, c in self.cells.items():
            if c["type"] in FF:
                for i, b in enumerate(c["connections"]["Q"]):
                    self.ffbit[b] = (cn, i)
        self.memo = {}

    def nm(self, b):
        return self.name_of.get(b, f"net{b}") if isinstance(b, int) else f"const {b}"

    def clk_domain(self, b):
        return self.clock.get(b)

    def ff_domain(self, cn):
        return self.clk_domain(self.cells[cn]["connections"]["CLK"][0])

    def mem_ports(self, cn):
        c = self.cells[cn]
        p = c["parameters"]
        nrd, nwr, width = int(p["RD_PORTS"], 2), int(p["WR_PORTS"], 2), int(p["WIDTH"], 2)
        rd_clk_en = p["RD_CLK_ENABLE"][::-1]                # bit i = port i
        return nrd, nwr, width, rd_clk_en

    def source_domain(self, src):
        kind, ref = src[0], src[1]
        if kind == "ff":
            return self.ff_domain(ref[0])
        if kind == "in":
            return port_domain(ref)
        if kind == "memrd":                                 # synchronous read port output
            cn, port = ref
            return self.clk_domain(self.cells[cn]["connections"]["RD_CLK"][port])
        if kind == "memdata":                               # memory contents (written by WR_CLK)
            return self.clk_domain(self.cells[ref]["connections"]["WR_CLK"][0])
        return None

    def cone(self, b):
        """Sources that bit b depends on: {source: path kind}. Sources are
        ("ff", (cell, bit)), ("in", port), ("memrd", (cell, port)), ("memdata", cell)."""
        if not isinstance(b, int):
            return {}
        if b in self.memo:
            return self.memo[b]
        self.memo[b] = {}                                   # breaks combinational loops
        res = {}

        def add(src, kind):
            res[src] = worst(res.get(src, kind), kind)

        drv = self.driver.get(b)
        if drv is None:
            pass
        elif drv[0] == "in":
            add(("in", drv[1]), "direct")
        else:
            _, cn, port, i = drv
            c = self.cells[cn]
            t = c["type"]
            if t in FF:
                add(("ff", (cn, i)), "direct")
            elif t == "$mem_v2":
                nrd, nwr, width, rd_clk_en = self.mem_ports(cn)
                p = i // width
                if rd_clk_en[p] == "1":
                    add(("memrd", (cn, p)), "direct")
                else:                                       # asynchronous read: contents + address
                    add(("memdata", cn), "mux")
                    abits = int(c["parameters"]["ABITS"], 2)
                    for ab in c["connections"]["RD_ADDR"][p * abits:(p + 1) * abits]:
                        for s, k in self.cone(ab).items():
                            add(s, "select")
            else:
                sel = SELECT.get(t)
                for ip, bits in c["connections"].items():
                    if c["port_directions"][ip] != "input":
                        continue
                    for ib in bits:
                        for s, k in self.cone(ib).items():
                            if t in PASS:
                                nk = k
                            elif ip == sel:
                                nk = "select"
                            elif sel is not None:
                                nk = "mux" if k == "direct" else k
                            else:
                                nk = worst(k, "logic")
                            add(s, nk)
        self.memo[b] = res
        return res

    def label(self, src):
        kind, ref = src[0], src[1]
        if kind == "ff":
            return self.nm(self.cells[ref[0]]["connections"]["Q"][ref[1]])
        if kind == "in":
            return ref
        if kind == "memrd":
            return f"{ref[0]} (read port {ref[1]})"
        return f"{ref} (contents)"


def analyze(path, top):
    n = Netlist(path, top)
    viol, chains, mux, mems = [], [], [], []

    def v(rule, where, detail):
        viol.append((rule, where, detail))

    # clocks and resets of every flop
    nff = {"src": 0, "dst": 0}
    for cn, c in n.cells.items():
        if c["type"] in LATCH:
            v("CDC-CLOCK", cn, "latch")
        if c["type"] not in FF:
            continue
        d = n.ff_domain(cn)
        q0 = c["connections"]["Q"][0]
        if d is None:
            v("CDC-CLOCK", n.nm(q0), "clock is not a clock input")
            continue
        nff[d] = nff.get(d, 0) + len(c["connections"]["Q"])
        for rp in ("ARST", "AL", "CLR", "SET"):
            for rb in c["connections"].get(rp, []):
                if not isinstance(rb, int):
                    continue
                rd = n.reset.get(rb)
                if rd is None:
                    v("CDC-RESET", n.nm(q0), f"{rp} comes through logic ({n.nm(rb)})")
                elif rd != d:
                    v("CDC-RESET", n.nm(q0), f"{rp} from the {rd} reset, flop in {d}")

    # flop inputs
    first_stage = {}                                        # (cell, bit) -> launch source
    for cn, c in n.cells.items():
        if c["type"] not in FF:
            continue
        d = n.ff_domain(cn)
        if d is None:
            continue
        conns = c["connections"]
        for i, db in enumerate(conns["D"]):
            where = n.nm(conns["Q"][i])
            for cp in ("EN", "SRST", "CE"):
                for cb in conns.get(cp, []):
                    for s, k in n.cone(cb).items():
                        if n.source_domain(s) not in (d, None):
                            v("CDC-UNSYNC", where, f"{cp} depends on {n.label(s)} ({n.source_domain(s)})")
            foreign = {s: k for s, k in n.cone(db).items() if n.source_domain(s) not in (d, None)}
            if not foreign:
                continue
            kinds = set(foreign.values())
            if len(foreign) == 1 and kinds == {"direct"}:
                first_stage[(cn, i)] = next(iter(foreign))
            elif kinds == {"mux"}:
                mux.append((where, sorted({n.label(s) for s in foreign})))
            elif "select" in kinds:
                v("CDC-MUXSEL", where, "select depends on " + ", ".join(
                    sorted(n.label(s) for s, k in foreign.items() if k == "select")[:3]))
            else:
                # logic in front of something that then looks like a synchronizer?
                q = conns["Q"][i]
                ld = n.loads.get(q, [])
                looks_sync = len(ld) >= 1 and all(l[0] == "cell" and n.cells[l[1]]["type"] in FF and l[2] == "D"
                                                  and n.ff_domain(l[1]) == d for l in ld)
                srcs = ", ".join(sorted(n.label(s) for s in foreign)[:3])
                v("CDC-SYNC-LOGIC" if looks_sync else "CDC-UNSYNC", where, f"from {srcs} through logic")

    # synchronizer chains from each first stage
    final_of = {}                                           # final-stage Q bit -> group
    for (cn, i), launch in first_stage.items():
        stages, cur = [(cn, i)], (cn, i)
        fan = False
        while True:
            q = n.cells[cur[0]]["connections"]["Q"][cur[1]]
            ld = n.loads.get(q, [])
            nxt = [l for l in ld if l[0] == "cell" and n.cells[l[1]]["type"] in FF and l[2] == "D"
                   and n.ff_domain(l[1]) == n.ff_domain(cn)
                   and not n.cells[l[1]]["connections"].get("EN")
                   and n.cone(n.cells[l[1]]["connections"]["D"][l[3]]) == {("ff", cur): "direct"}]
            if len(nxt) == 1 and len(stages) < 8:
                if len(ld) > 1 and len(stages) == 1:
                    fan = True
                cur = (nxt[0][1], nxt[0][3])
                stages.append(cur)
            else:
                break
        where = n.nm(n.cells[cn]["connections"]["Q"][i])
        if fan:
            v("CDC-SYNC-FANOUT", where, "first stage also drives other logic")
        if len(stages) < 2:
            v("CDC-SYNC-DEPTH", where, f"{len(stages)} stage")
        group = launch[1][0] if launch[0] == "ff" else launch[1]
        final_q = n.cells[cur[0]]["connections"]["Q"][cur[1]]
        final_of[("ff", cur)] = group
        chains.append(dict(launch=n.label(launch), group=group, stages=len(stages), dst=where,
                           domain=n.ff_domain(cn), final=n.nm(final_q)))

    # reconvergence: one destination flop or output fed by two synchronized groups
    def groups_in(b):
        return {final_of[s] for s in n.cone(b) if s in final_of}
    sinks = []
    for cn, c in n.cells.items():
        if c["type"] in FF:
            for i, db in enumerate(c["connections"]["D"]):
                sinks.append((n.nm(c["connections"]["Q"][i]), [db] + c["connections"].get("EN", [])))
    for pn, p in n.ports.items():
        if p["direction"] == "output":
            for i, b in enumerate(p["bits"]):
                sinks.append((f"{pn}[{i}]", [b]))
    for where, bits in sinks:
        g = set()
        for b in bits:
            g |= groups_in(b)
        if len(g) > 1:
            v("CDC-RECONV", where, "combines " + ", ".join(sorted(n.label(("ff", (x, 0))) if x in n.cells else x
                                                                 for x in g)[:3]))

    # memories
    for cn, c in n.cells.items():
        if c["type"] != "$mem_v2":
            continue
        nrd, nwr, width, rd_clk_en = n.mem_ports(cn)
        conns = c["connections"]
        abits = int(c["parameters"]["ABITS"], 2)
        wd = n.clk_domain(conns["WR_CLK"][0])
        for port in ("WR_ADDR", "WR_DATA", "WR_EN"):
            for b in conns[port]:
                for s in n.cone(b):
                    if n.source_domain(s) not in (wd, None):
                        v("CDC-MEMPORT", cn, f"{port} depends on {n.label(s)} ({n.source_domain(s)})")
        rds = []
        for p in range(nrd):
            if rd_clk_en[p] != "1":
                continue
            rd = n.clk_domain(conns["RD_CLK"][p])
            rds.append(rd)
            for port, w in (("RD_ADDR", abits), ("RD_EN", 1), ("RD_SRST", 1)):
                for b in conns[port][p * w:(p + 1) * w]:
                    for s in n.cone(b):
                        if n.source_domain(s) not in (rd, None):
                            v("CDC-MEMPORT", cn, f"{port} depends on {n.label(s)} ({n.source_domain(s)})")
            for b in conns["RD_ARST"][p:p + 1]:
                if isinstance(b, int) and n.reset.get(b) not in (rd,):
                    v("CDC-RESET", cn, "read-port reset from another domain or logic")
        if any(r != wd for r in rds):
            mems.append(dict(name=cn, write=wd, read=sorted(set(rds)), width=width,
                             depth=int(c["parameters"]["SIZE"], 2)))

    # outputs
    for pn, p in n.ports.items():
        if p["direction"] != "output":
            continue
        d = port_domain(pn)
        for i, b in enumerate(p["bits"]):
            for s, k in n.cone(b).items():
                if n.source_domain(s) not in (d, None):
                    v("CDC-OUTPUT", f"{pn}[{i}]", f"depends on {n.label(s)} ({n.source_domain(s)})")

    viol = sorted(set(viol))
    return dict(flops=nff, chains=chains, mux=mux, mems=mems, viol=viol)


def yosys_cmd(a):
    if a.yosys:
        return a.yosys
    for c in ("yowasp-yosys", "yosys"):
        if shutil.which(c):
            return c
    sys.exit("no Yosys found: pip install yowasp-yosys (it includes the slang frontend)")


def rtl_files():
    text = open(os.path.join(ROOT, "sim", "common.sh")).read()
    body = re.search(r"^SRC=\((.*?)^\)", text, re.S | re.M).group(1)
    return [os.path.join("rtl", p) for d, p in re.findall(r'"\$(R|T)/([^"]+)"', body) if d == "R"]


def synth(a, files, top, out_json, params=()):
    gs = " ".join(f"-G {k}={v}" for k, v in params)
    script = (f"read_slang -j 1 -D SYNTHESIS -D COMMON_CELLS_ASSERTS_OFF -I rtl/axi/include "
              f"-I rtl/common_cells/include --top {top} {gs} {' '.join(files)}; "
              f"hierarchy -top {top}; proc; flatten; opt; memory -nomap; opt_clean; write_json {out_json}")
    r = subprocess.run([yosys_cmd(a), "-q", "-p", script], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(os.path.join(ROOT, out_json)):
        sys.exit(f"Yosys failed for {top} {gs}:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")


def summarize(name, r):
    groups = {}
    for c in r["chains"]:
        groups.setdefault(c["group"], []).append(c)
    multi = sum(1 for g in groups.values() if len(g) > 1)
    depth = sorted({c["stages"] for c in r["chains"]})
    return dict(name=name, ff_src=r["flops"].get("src", 0), ff_dst=r["flops"].get("dst", 0),
                sync_bits=len(r["chains"]), groups=len(groups), multi=multi, depth=depth,
                mems=len(r["mems"]), mux=len(r["mux"]), viol=len(r["viol"]))


def report(results, path):
    L = ["# Structural CDC check", "",
         "Generated by `tools/cdc_check.py` (Yosys + slang netlist, flat, word-level). "
         "Every flop, memory port and output is assigned the domain of its clock; every input is "
         "followed back through combinational logic. Each crossing must be a synchronizer chain "
         "(SYNC), a dual-clock memory (MEM) or a FIFO read multiplexer selected from the reading "
         "domain (MUX); anything else is a violation.", "",
         "| Configuration | Flops src / dst | SYNC bits (groups, multi-bit) | Stages | MEM | MUX bits | Violations |",
         "|---|---|---|---|---|---|---|"]
    for name, r in results:
        s = summarize(name, r)
        L.append(f"| {name} | {s['ff_src']} / {s['ff_dst']} | {s['sync_bits']} ({s['groups']}, {s['multi']}) | "
                 f"{'/'.join(map(str, s['depth'])) or '-'} | {s['mems']} | {s['mux']} | {s['viol']} |")
    L += ["", "Safety arguments for the structures that a netlist alone cannot prove:", "",
          "- **Multi-bit SYNC groups** are the gray-coded FIFO pointers (one group per pointer). Only "
          "one bit may change per update; `SVA_GRAY` checks this on every pointer in every simulation "
          "run (0 fires in the regression, and `neg_ptr_glitch` shows it fires).",
          "- **MEM / MUX**: an entry is written only while the synchronized read pointer shows it free "
          "and read only after the synchronized write pointer shows it written, so the data is stable "
          "for at least two destination cycles before it is used. `SVA_MOVE`, `SVA_OCC` and the data "
          "check cover this protocol in simulation.",
          "- Metastability itself (MTBF) and the timing of the crossing nets are outside a netlist "
          "check: they need the synchronizer constraints in static timing analysis.", ""]
    for name, r in results:
        L += [f"## {name}", ""]
        if r["viol"]:
            L += ["| Rule | Where | Detail |", "|---|---|---|"] + \
                 [f"| {a} | `{b}` | {c} |" for a, b, c in r["viol"]] + [""]
        groups = {}
        for c in r["chains"]:
            groups.setdefault((c["group"], c["domain"]), []).append(c)
        L += ["| SYNC group (launch register) | Into | Bits | Stages |", "|---|---|---|---|"]
        rows = sorted((re.sub(r"\[\d+\]$", "", cs[0]["launch"]), d, cs) for (g, d), cs in groups.items())
        for launch, d, cs in rows:
            L.append(f"| `{launch}` | {d} | {len(cs)} | {'/'.join(sorted({str(c['stages']) for c in cs}))} |")
        L.append("")
        if r["mems"]:
            L += ["| MEM | Write | Read | Depth x width |", "|---|---|---|---|"] + \
                 [f"| `{m['name']}` | {m['write']} | {', '.join(m['read'])} | {m['depth']} x {m['width']} |"
                  for m in r["mems"]] + [""]
        if r["mux"]:
            regs = {}
            for where, srcs in r["mux"]:
                regs.setdefault(re.sub(r"\[\d+\]$", "", where), set()).update(
                    re.sub(r"\[\d+\]$", "", s) for s in srcs)
            L += ["| MUX destination register | Bits | Storage read |", "|---|---|---|"] + \
                 [f"| `{d}` | {sum(1 for w, _ in r['mux'] if re.sub(r'\[\d+\]$', '', w) == d)} | "
                  f"{', '.join('`' + x + '`' for x in sorted(s)[:2])} |" for d, s in sorted(regs.items())] + [""]
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def self_test(a):
    tests = sorted(glob.glob(os.path.join(ROOT, "tools", "cdc", "tests", "*.sv")))
    os.makedirs(os.path.join(ROOT, OUT, "tests"), exist_ok=True)
    ok = 0
    for t in tests:
        exp = set()
        for ln in open(t):
            m = re.match(r"//\s*expect:\s*(.*)", ln)
            if m:
                exp = set() if m.group(1).strip() == "clean" else set(m.group(1).split())
        base = os.path.splitext(os.path.basename(t))[0]
        js = os.path.join(OUT, "tests", base + ".json")
        synth(a, [os.path.relpath(t, ROOT)], "t", js)
        r = analyze(os.path.join(ROOT, js), "t")
        got = {x[0] for x in r["viol"]}
        good = got == exp
        ok += good
        print(f"  {'ok  ' if good else 'FAIL'} {base}: expected {', '.join(sorted(exp)) or 'clean'}, "
              f"got {', '.join(sorted(got)) or 'clean'}")
        if not good:
            for x in r["viol"][:5]:
                print("       ", x)
    print(f"{ok}/{len(tests)} CDC checker test designs behave as expected")
    return 0 if ok == len(tests) else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--yosys", help="Yosys command (default: yowasp-yosys, else yosys)")
    ap.add_argument("--configs", default=",".join(c for c, _, _ in CONFIGS))
    ap.add_argument("-o", "--out", default=os.path.join(OUT, "cdc_report.md"))
    a = ap.parse_args(argv)
    if a.self_test:
        return self_test(a)
    os.makedirs(os.path.join(ROOT, OUT), exist_ok=True)
    files = rtl_files() + [os.path.join("tools", "cdc", "cdc_top.sv")]
    results = []
    for name, ram, depth in CONFIGS:
        if name not in a.configs.split(","):
            continue
        js = os.path.join(OUT, name + ".json")
        synth(a, files, "cdc_top", js, [("UseRam", ram), ("LogDepth", depth)])
        r = analyze(os.path.join(ROOT, js), "cdc_top")
        s = summarize(name, r)
        results.append((name, r))
        print(f"  {name}: flops {s['ff_src']}/{s['ff_dst']}, SYNC {s['sync_bits']} bits in {s['groups']} groups "
              f"({s['multi']} multi-bit, stages {'/'.join(map(str, s['depth']))}), MEM {s['mems']}, "
              f"MUX {s['mux']} bits, violations {s['viol']}")
        for x in r["viol"][:10]:
            print("     ", x)
        # the structure the design must have: 5 FIFOs, 2 gray pointers each of
        # LogDepth+1 bits, 2-stage synchronizers; data through 5 dual-clock RAMs
        # (axi_cdc_ram) or the read muxes of all 291 channel bits (axi_cdc). A
        # checker that finds less has lost track of something.
        want = dict(sync_bits=10 * (depth + 1), groups=10, depth=[2], mems=5 if ram else 0, mux=0 if ram else 291)
        for k, w in want.items():
            if s[k] != w:
                r["viol"].append(("CDC-STRUCTURE", name, f"{k} is {s[k]}, expected {w}"))
                print(f"      unexpected structure: {k} is {s[k]}, expected {w}")
    out = a.out if os.path.isabs(a.out) else os.path.join(ROOT, a.out)
    report(results, out)
    nv = sum(len(r["viol"]) for _, r in results)
    print(f"== CDC: {len(results)} configurations, {nv} violations; report {os.path.relpath(out, ROOT)}")
    return 0 if nv == 0 and results else 1


if __name__ == "__main__":
    sys.exit(main())
