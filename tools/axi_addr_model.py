#!/usr/bin/env python3
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
"""Third, independent model of AXI4 burst addresses and byte lanes.

Written in Python from the transfer pseudo-code of the AXI spec (A3.4.2),
separately from the two SystemVerilog models. It checks the hand-computed
vectors that addr_model_test also uses, so a wrong vector cannot hide a
wrong model (or the other way round).

    python3 tools/axi_addr_model.py        # exit code 0 if every vector matches
"""
import sys

DATA_BUS_BYTES = 8
FIXED, INCR, WRAP = 0, 1, 2


def beats(start, size, length, burst):
    """[(address, lower_lane, upper_lane)] for each beat (length = AxLEN + 1)."""
    nbytes = 1 << size
    aligned_addr = (start // nbytes) * nbytes
    total = nbytes * length
    lower_wrap = (start // total) * total
    addr, aligned, out = start, aligned_addr == start, []
    for _ in range(length):
        lo = addr - (addr // DATA_BUS_BYTES) * DATA_BUS_BYTES
        hi = lo + nbytes - 1 if aligned else aligned_addr + nbytes - 1 - (addr // DATA_BUS_BYTES) * DATA_BUS_BYTES
        out.append((addr, lo, hi))
        if burst != FIXED:
            if aligned:
                addr += nbytes
                if burst == WRAP and addr >= lower_wrap + total:
                    addr = lower_wrap
            else:
                addr, aligned = aligned_addr + nbytes, True
    return out


# Same vectors as addr_model_test (tb/uvm/axi_tests.svh):
# (name, burst, size, AxLEN + 1, start, addresses, lower lanes, upper lanes)
VECTORS = [
    ("INCR 8B x4", INCR, 3, 4, 0x1000, [0x1000, 0x1008, 0x1010, 0x1018], [0, 0, 0, 0], [7, 7, 7, 7]),
    ("INCR 4B x3 unaligned", INCR, 2, 3, 0x1003, [0x1003, 0x1004, 0x1008], [3, 4, 0], [3, 7, 3]),
    ("INCR 8B x2 unaligned", INCR, 3, 2, 0x2005, [0x2005, 0x2008], [5, 0], [7, 7]),
    ("INCR 4B x2 unaligned", INCR, 2, 2, 0xD006, [0xD006, 0xD008], [6, 0], [7, 3]),
    ("INCR 2B x4 narrow", INCR, 1, 4, 0x3006, [0x3006, 0x3008, 0x300A, 0x300C], [6, 0, 2, 4], [7, 1, 3, 5]),
    ("INCR 1B x3", INCR, 0, 3, 0x4007, [0x4007, 0x4008, 0x4009], [7, 0, 1], [7, 0, 1]),
    ("INCR 8B x1 unaligned", INCR, 3, 1, 0xB00D, [0xB00D], [5], [7]),
    ("INCR 1B x256", INCR, 0, 256, 0xA000, [0xA000 + i for i in range(256)],
     [i % 8 for i in range(256)], [i % 8 for i in range(256)]),
    ("FIXED 4B x4", FIXED, 2, 4, 0x5010, [0x5010] * 4, [0] * 4, [3] * 4),
    ("FIXED 4B x2 unaligned", FIXED, 2, 2, 0x5011, [0x5011] * 2, [1] * 2, [3] * 2),
    ("WRAP 4B x4 from middle", WRAP, 2, 4, 0x6008, [0x6008, 0x600C, 0x6000, 0x6004], [0, 4, 0, 4], [3, 7, 3, 7]),
    ("WRAP 8B x8 from 0x30", WRAP, 3, 8, 0x7030,
     [0x7030, 0x7038, 0x7000, 0x7008, 0x7010, 0x7018, 0x7020, 0x7028], [0] * 8, [7] * 8),
    ("WRAP 1B x2", WRAP, 0, 2, 0x8001, [0x8001, 0x8000], [1, 0], [1, 0]),
    ("WRAP 2B x16 from 0x16", WRAP, 1, 16, 0x9016,
     [0x9016, 0x9018, 0x901A, 0x901C, 0x901E, 0x9000, 0x9002, 0x9004,
      0x9006, 0x9008, 0x900A, 0x900C, 0x900E, 0x9010, 0x9012, 0x9014],
     [6, 0, 2, 4] * 4, [7, 1, 3, 5] * 4),
    ("WRAP 8B x4 at boundary", WRAP, 3, 4, 0xC000, [0xC000, 0xC008, 0xC010, 0xC018], [0] * 4, [7] * 4),
]


def main():
    bad = 0
    for name, burst, size, length, start, addrs, los, his in VECTORS:
        got = beats(start, size, length, burst)
        want = list(zip(addrs, los, his))
        if got != want:
            bad += 1
            for i, (g, w) in enumerate(zip(got, want)):
                if g != w:
                    print(f"MISMATCH {name} beat {i}: model {g}, vector {w}")
                    break
            if len(got) != len(want):
                print(f"MISMATCH {name}: {len(got)} beats, vector has {len(want)}")
    print(f"{len(VECTORS)} vectors, {bad} mismatches")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
