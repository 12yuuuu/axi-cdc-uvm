#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Figures for the README, in one paper-like style (muted palette, serif text).

    python3 tools/figures.py [--dark] arch     docs/fig1_testbench.svg
    python3 tools/figures.py [--dark] wave     docs/fig2_waveform.svg waves.vcd 340 445
    python3 tools/figures.py [--dark] coverage docs/fig3_coverage_closure.svg docs/data/coverage_closure.csv

wave: a VCD of tb_top, e.g. from `sim/run_one.sh smoke_test 1 1 2 +VCD`, and a
time window in ns around one write.
The background is transparent. --dark draws light ink for a dark page (the
README picks the version with prefers-color-scheme); the default is for a
white page. The output format follows the file extension (.svg, .pdf, .png).
"""
import csv
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle

# Muted palette. The pair passes the dataviz palette checks on white
# (lightness band, chroma floor, CVD and normal-vision separation, 3:1
# contrast); the stage ramp passes the ordinal checks.
# SURF is the page the figure sits on (the files themselves are transparent):
# box fills, washes and marker rings are drawn in it.
THEMES = {
    "light": dict(INK="#222222", INK2="#5a5a5a", GRID="#e3e3e3", SURF="#ffffff", DUT="#f3f3f3", RULE="#c9c9c9",
                  STAGE=["#A39DD2", "#6E64B0", "#3B2F8C"]),     # closure steps, light -> dark
    # GitHub dark page; same hues, the stage ramp runs dim -> bright (passes
    # the ordinal checks on #0d1117; SRC/DST pass the categorical checks)
    "dark": dict(INK="#e6edf3", INK2="#9198a1", GRID="#2d333b", SURF="#0d1117", DUT="#161b22", RULE="#444c56",
                 STAGE=["#5A4FA8", "#8C84CC", "#C3BEEA"]),
}
SRC, DST = "#6E64B0", "#CC6677"               # source / destination clock domain
INK = INK2 = GRID = SURF = DUT = RULE = None
STAGE = []
MONO = "DejaVu Sans Mono"
# no date or tool version in the files, so a rebuild without changes is byte-identical
META = {"svg": {"Date": None, "Creator": None}, "pdf": {"CreationDate": None, "Creator": None, "Producer": None}}



def use_theme(name):
    globals().update(THEMES[name])
    plt.rcParams.update({
        "font.family": "STIXGeneral", "mathtext.fontset": "stix", "font.size": 9,
        "axes.linewidth": 0.6, "axes.edgecolor": INK2, "svg.fonttype": "path",
        "xtick.major.width": 0.6, "ytick.major.width": 0.6, "xtick.color": INK2,
        "ytick.color": INK2, "axes.labelcolor": INK, "text.color": INK, "savefig.dpi": 220,
        "svg.hashsalt": "axi_cdc_uvm",
    })


def tint(hex_color, a):
    """Blend a color with the page (a = share of the color)."""
    h, p = hex_color.lstrip("#"), SURF.lstrip("#")
    rgb = [int(h[i:i + 2], 16) for i in (0, 2, 4)]
    page = [int(p[i:i + 2], 16) for i in (0, 2, 4)]
    return "#%02x%02x%02x" % tuple(round(q + (c - q) * a) for c, q in zip(rgb, page))


def save(fig, out):
    fig.savefig(out, transparent=True, metadata=META.get(out.rsplit(".", 1)[-1]))


# ----------------------------------------------------------------- figure 1
def arch(out):
    fig, ax = plt.subplots(figsize=(7.2, 4.9))
    ax.set_xlim(0, 100)
    ax.set_ylim(-15.5, 60)
    ax.axis("off")

    def box(x, y, w, h, title, sub=None, mono=False, ty=None):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=1.2",
                                    fc=SURF, ec=INK2, lw=0.7, zorder=2))
        ty = ty if ty is not None else (y + h * 0.64 if sub else y + h / 2)
        ax.text(x + w / 2, ty, title, ha="center", va="center", fontsize=8.5,
                family=MONO if mono else "STIXGeneral", zorder=3)
        if sub:
            ax.text(x + w / 2, ty - 2.6, sub, ha="center", va="top", fontsize=6.8, color=INK2,
                    zorder=3, linespacing=1.25)

    def arrow(p, q, style="-|>", lw=0.8, color=INK2, ls="-"):
        ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=7, color=color, lw=lw,
                                     ls=ls, shrinkA=0, shrinkB=0, zorder=4))

    def tag(x, y, w, h, text):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.8",
                                    fc=SURF, ec=INK, lw=0.6, ls=(0, (2, 1.5)), zorder=5))
        ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=6.3, zorder=6,
                linespacing=1.15)

    # clock-domain panels (identity: colored rule + 10 % wash; text stays ink)
    for x0, x1, col, name, ha in ((1, 34, SRC, "src_clk domain", "left"), (66, 99, DST, "dst_clk domain", "right")):
        ax.add_patch(Rectangle((x0, 3), x1 - x0, 56, fc=tint(col, 0.10), ec="none", zorder=0))
        ax.plot([x0, x1], [59, 59], color=col, lw=2.4, solid_capstyle="butt")
        ax.text(x0 + 1 if ha == "left" else x1 - 1, 56.6, name, ha=ha, fontsize=8, style="italic")

    # UVM test layer
    box(36.5, 47.0, 27, 9.5, "Tests + config object", "10 tests · one seed sets the clocks,\nthe knobs and the traffic", ty=53.6)

    arrow((36.5, 50.5), (31, 49.25))                          # test starts the sequences
    arrow((63.5, 50.5), (82.5, 41), ls=(0, (2, 1.5)))          # config knobs reach the slave
    ax.text(74.5, 47.6, "knobs", fontsize=6.5, color=INK2, ha="left")

    # source side
    box(4, 45, 27, 8.5, "Sequences", "directed · constrained-random")
    box(4, 18, 27, 23, "Pipelined AXI4 master", "driver + sequencer\n\u2264 72 transactions in flight\nW may lead AW\nrandom READY on B / R", ty=36.5)
    box(4, 5, 27, 8, "Monitor (source port)", "transactions · stall counters")
    arrow((17.5, 45), (17.5, 41))

    # destination side
    box(69, 18, 27, 23, "Reactive memory slave", "sparse memory · random READY, delays\nB out of order across IDs\nR interleaved across IDs\nSLVERR / DECERR pages\nhold knobs fill the FIFOs", ty=36.5)
    box(69, 5, 27, 8, "Monitor (dest. port)", "transactions · stall counters")

    # DUT
    ax.add_patch(FancyBboxPatch((38, 16.5), 24, 28, boxstyle="round,pad=0,rounding_size=1.2",
                                fc=DUT, ec=INK, lw=0.9, zorder=1))
    ax.text(50, 42.0, "axi_cdc_ram", ha="center", va="center", fontsize=8.5, family=MONO, zorder=3)
    ax.text(50, 39.6, "DUT (baseline: axi_cdc)", ha="center", va="center", fontsize=6.8, color=INK2, zorder=3)
    ax.plot([50, 50], [20.5, 37.5], color=INK2, lw=0.6, ls=(0, (3, 2)), zorder=2)
    lanes = (("AW", 36.0, 1), ("W", 32.5, 1), ("AR", 29.0, 1), ("B", 25.5, -1), ("R", 22.0, -1))
    for name, y, d in lanes:
        for i in range(4):
            ax.add_patch(Rectangle((46.6 + 1.7 * i, y - 1.0), 1.5, 2.0, fc=SURF, ec=INK2, lw=0.5, zorder=3))
        if d > 0:
            arrow((31, y), (46.4, y))
            arrow((53.6, y), (69, y))
        else:
            arrow((69, y), (53.6, y))
            arrow((46.4, y), (31, y))
        ax.text(34.6, y + 0.55, name, ha="center", va="bottom", fontsize=6.5, family=MONO, zorder=3)
        ax.text(65.4, y + 0.55, name, ha="center", va="bottom", fontsize=6.5, family=MONO, zorder=3)
    ax.text(50, 18.4, "gray pointers · 2-FF sync\ndual-clock RAM", ha="center", va="center",
            fontsize=6.2, color=INK2, zorder=3, linespacing=1.15)

    # monitors tap the ports
    for xt, xm in ((36.6, 31), (63.4, 69)):
        ax.plot([xt, xt], [21.2, 9], color=INK2, lw=0.6, ls=(0, (1, 1.5)), zorder=2)
        ax.plot([xt], [21.2], "o", ms=2.6, color=INK2, zorder=4)
        arrow((xt, 9), (xm, 9))

    # assertions
    tag(31.3, 39.2, 6.4, 4.0, "SVA\nhandshake")
    tag(62.3, 39.2, 6.4, 4.0, "SVA\nhandshake")
    tag(39.5, 11.2, 21.0, 3.4, "SVA (bind): gray · move · occupancy")
    ax.plot([50, 50], [14.6, 16.5], color=INK, lw=0.6, ls=(0, (2, 1.5)), zorder=4)

    # checkers
    box(4, -14.5, 40, 11, "Functional coverage", "5 covergroups · crosses · 146 bins\nmerged per configuration", ty=-6.6)
    box(56, -14.5, 40, 11, "Scoreboard", "bridge check (k-th in = k-th out)\nreference model (AXI spec pseudo-code)\nresponse check against the address map", ty=-6.2)
    arrow((12, 5), (12, -3.5))
    arrow((25, 5), (64, -3.5))
    arrow((82.5, 5), (82.5, -3.5))
    fig.subplots_adjust(0.005, 0.005, 0.995, 0.995)
    save(fig, out)


# ----------------------------------------------------------------- figure 2
def wave(out, vcd_path, t0, t1):
    import vcdvcd
    v = vcdvcd.VCDVCD(vcd_path, store_tvs=True)
    T0, T1 = t0 * 1000, t1 * 1000

    def series(name):
        tv = v[name].tv
        last = "x"
        for t, val in tv:
            if t <= T0:
                last = val
        pts = [(T0, last)] + [(t, val) for t, val in tv if T0 < t < T1]
        pts.append((T1, pts[-1][1]))
        return pts

    def val_at(name, t):
        last = "x"
        for tt, vv in v[name].tv:
            if tt < t:
                last = vv
            else:
                break
        return last

    def posedges(clk):
        return [t for t, val in v[clk].tv if val == "1" and T0 <= t <= T1]

    def side(p, clk, color):
        return [("clk", f"tb_top.{clk}", color, None, None),
                ("AW valid", f"tb_top.{p}.aw_valid", color, None, None),
                ("AW ready", f"tb_top.{p}.aw_ready", color, (f"tb_top.{p}.aw", f"tb_top.{clk}"), None),
                ("W valid", f"tb_top.{p}.w_valid", color, None, None),
                ("W ready", f"tb_top.{p}.w_ready", color, (f"tb_top.{p}.w", f"tb_top.{clk}"), None),
                ("W last", f"tb_top.{p}.w_last", color, None, f"tb_top.{p}.w_valid"),
                ("B valid", f"tb_top.{p}.b_valid", color, None, None),
                ("B ready", f"tb_top.{p}.b_ready", color, (f"tb_top.{p}.b", f"tb_top.{clk}"), None)]
    rows = side("src_if", "src_clk", SRC) + [None] + side("dst_if", "dst_clk", DST)
    rows[0] = ("src_clk",) + rows[0][1:]
    rows[9] = ("dst_clk",) + rows[9][1:]

    fig, ax = plt.subplots(figsize=(7.2, 4.6))
    H, GAP = 0.62, 1.0
    yt, yl, y = [], [], 0.0
    for row in rows:
        if row is None:
            y -= 1.15
            continue
        label, name, color, hs, gate = row
        base = y
        pts = series(name)
        xs, ys = [], []
        for i, (t, val) in enumerate(pts):
            lv = 1.0 if val == "1" else 0.0
            if i:
                xs.append(t / 1000); ys.append(ys[-1])
            xs.append(t / 1000); ys.append(lv)
        clk = "clk" in label
        if gate is None:
            if not clk:
                ax.fill_between(xs, base, [base + H * q for q in ys], color=color, alpha=0.12, lw=0)
            ax.plot(xs, [base + H * q for q in ys], color=color, lw=0.8 if clk else 1.25, zorder=3)
        else:
            gp = series(gate)

            def g_at(t):
                g = "x"
                for tt, vv in gp:
                    if tt <= t:
                        g = vv
                return g
            for i in range(len(xs) - 1):
                xa, xb, ya = xs[i], xs[i + 1], ys[i]
                if xb <= xa:
                    continue
                cuts = [xa] + [tt / 1000 for tt, _ in gp if xa < tt / 1000 < xb] + [xb]
                for ca, cb in zip(cuts[:-1], cuts[1:]):
                    if g_at((ca + cb) / 2 * 1000) == "1":
                        ax.fill_between([ca, cb], base, base + H * ya, color=color, alpha=0.12, lw=0)
                        ax.plot([ca, cb], [base + H * ya] * 2, color=color, lw=1.25, zorder=3)
                    else:
                        ax.plot([ca, cb], [base + H / 2] * 2, color=INK2, lw=0.6, ls=(0, (2, 2)), zorder=2)
            for i in range(1, len(xs)):
                if xs[i] == xs[i - 1] and ys[i] != ys[i - 1] and g_at(xs[i] * 1000 + 0.5) == "1" \
                        and g_at(xs[i] * 1000 - 0.5) == "1":
                    ax.plot([xs[i]] * 2, [base + H * ys[i - 1], base + H * ys[i]], color=color, lw=1.25, zorder=3)
        if hs:
            pre, ck = hs
            for t in posedges(ck):
                if val_at(pre + "_valid", t) == "1" and val_at(pre + "_ready", t) == "1":
                    ax.plot([t / 1000], [base + H], "o", ms=4.2, color=INK, mec=SURF, mew=1.0, zorder=5)
        yt.append(base + H / 2); yl.append(label)
        y -= GAP

    ax.set_yticks(yt)
    ax.set_yticklabels(yl, fontsize=7.5, family=MONO, color=INK2)
    ax.set_xlim(t0, t1)
    ax.set_xlabel("Time (ns)", fontsize=9)
    ax.tick_params(axis="x", labelsize=8, length=2.5)
    ax.tick_params(axis="y", length=0)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.grid(axis="x", color=GRID, lw=0.5)
    ax.set_axisbelow(True)
    for i, (title, color) in ((0, ("(a) Source port, src_clk = 10 ns", SRC)), (8, ("(b) Destination port, dst_clk = 3 ns", DST))):
        ax.plot([t0, t0 + 2.2], [yt[i] + 0.98] * 2, color=color, lw=2.2, solid_capstyle="butt", clip_on=False)
        ax.text(t0 + 3.0, yt[i] + 0.98, title, va="center", fontsize=8.5)
    ax.plot([t1 - 31.5], [yt[-1] - 1.05], "o", ms=4.2, color=INK, mec=SURF, mew=1.0, clip_on=False)
    ax.text(t1 - 30.3, yt[-1] - 1.05, "handshake    - - -  payload not valid", va="center", fontsize=7.5, color=INK2)
    ax.set_ylim(yt[-1] - 1.4, yt[0] + 1.35)
    fig.subplots_adjust(left=0.10, right=0.99, top=0.99, bottom=0.10)
    save(fig, out)


# ----------------------------------------------------------------- figure 3
def coverage(out, csv_path):
    rows = list(csv.DictReader(open(csv_path)))
    steps = [k for k in rows[0] if k not in ("config", "total", "note")]
    total = int(rows[0]["total"])
    fig, ax = plt.subplots(figsize=(7.2, 2.5))
    n = len(rows)
    ys = [n - 1 - i + (0.35 if i == 0 else 0.0) for i in range(n)]   # merged row sits apart
    lo = min(int(r[s]) for r in rows for s in steps)
    for y, r in zip(ys, rows):
        vals = [int(r[s]) for s in steps]
        ax.plot([min(vals), max(vals)], [y, y], color=RULE, lw=1.0, zorder=1)
        for v, c in zip(vals, STAGE):
            ax.plot([v], [y], "o", ms=6.5, color=c, mec=SURF, mew=1.2, zorder=3)
        ax.text(vals[0] - 0.9, y, str(vals[0]), ha="right", va="center", fontsize=8, color=INK2)
        ax.text(vals[-1] + 0.9, y, str(vals[-1]), ha="left", va="center", fontsize=8, color=INK)
        if r.get("note"):
            if vals[0] - lo > 10:   # room on the left: note before the first value
                ax.text(vals[0] - 4.2, y, r["note"], ha="right", va="center", fontsize=7, color=INK2,
                        style="italic")
            else:                   # otherwise just above the line
                ax.text(vals[0] + 1.2, y + 0.2, r["note"], ha="left", va="bottom", fontsize=7, color=INK2,
                        style="italic")
    ax.plot([total, total], [-0.5, ys[0] + 0.45], color=INK2, lw=0.6, zorder=0)
    ax.text(total, ys[0] + 0.55, f"all {total} bins", ha="center", va="bottom", fontsize=7.5, color=INK2)
    ax.set_yticks(ys)
    ax.set_yticklabels([r["config"] for r in rows], fontsize=8.5, color=INK)
    ax.set_xlim(lo - 6, total + 5)
    ax.set_ylim(-0.6, ys[0] + 1.0)
    ax.set_xlabel(f"Functional-coverage bins hit (of {total}); every run passes in every step", fontsize=9)
    ax.tick_params(axis="y", length=0)
    ax.tick_params(axis="x", labelsize=8, length=2.5)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.grid(axis="x", color=GRID, lw=0.5)
    ax.set_axisbelow(True)
    handles = [plt.Line2D([], [], ls="", marker="o", ms=6.5, color=c, mec=SURF, mew=1.2) for c in STAGE]
    ax.legend(handles, steps, loc="lower left", bbox_to_anchor=(0.0, 1.0), ncol=3, frameon=False,
              fontsize=8, handletextpad=0.3, columnspacing=1.6, borderaxespad=0)
    fig.subplots_adjust(left=0.15, right=0.98, top=0.86, bottom=0.19)
    save(fig, out)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dark"]
    use_theme("dark" if "--dark" in sys.argv[1:] else "light")
    if len(args) < 2 or args[0] not in ("arch", "wave", "coverage"):
        sys.exit(__doc__)
    kind, out = args[0], args[1]
    if kind == "arch":
        arch(out)
    elif kind == "wave":
        wave(out, args[2], float(args[3]), float(args[4]))
    else:
        coverage(out, args[2])
