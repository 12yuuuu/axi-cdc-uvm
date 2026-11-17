# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# List every AXI handshake (valid && ready at a clock edge) on both sides of the DUT.
# Usage: python3 tools/vcd_handshakes.py waves.vcd
import vcdvcd, sys
v = vcdvcd.VCDVCD(sys.argv[1], store_tvs=True)
def tv(n): return v[n].tv
def val_at(n, t):
    last = 'x'
    for (tt, vv) in tv(n):
        if tt < t: last = vv
        else: break
    return last
def posedges(clk):
    return [t for (t, vv) in tv(clk) if vv == '1']
res = {}
for side, clk in [('src', 'tb_top.src_clk'), ('dst', 'tb_top.dst_clk')]:
    pe = posedges(clk)
    for ch in ['aw', 'w', 'b', 'ar', 'r']:
        hs = []
        for t in pe:
            if val_at(f'tb_top.{side}_if.{ch}_valid', t) == '1' and val_at(f'tb_top.{side}_if.{ch}_ready', t) == '1':
                hs.append(t)
        res[(side, ch)] = hs
        print(f'{side} {ch:2s} handshakes at (ns):', [x/1000 for x in hs])
# first time valid rises on dst side for AW/W/AR and on src side for B/R
def rises(n):
    out=[]; prev='0'
    for (t,vv) in tv(n):
        if vv=='1' and prev!='1': out.append(t)
        prev=vv
    return out
print()
for side, ch in [('dst','aw'),('dst','w'),('dst','ar'),('src','b'),('src','r')]:
    print(f'{side} {ch}_valid rises at (ns):', [x/1000 for x in rises(f"tb_top.{side}_if.{ch}_valid")])
