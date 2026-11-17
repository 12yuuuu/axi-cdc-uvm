# Regression results

- **Mode:** full
- **Simulator:** Cadence Xcelium 23.09-s006, UVM 1.2 (CDNS-1.2)
- **Host:** EECG ug136 (Debian 12), University of Toronto
- **Date:** 2026-11-17 13:50 EST
- **Wall time:** 3 min 1 s (one machine, runs in sequence)

**Verdict: SIGNED OFF**

198 runs, 198 passed; 38,714 writes, 67,233 reads and 1,024,510 data beats checked; 0 assertion fires; 3 negative tests, 3 caught.

## Runs

| Set | Runs | Passed | Writes | Reads | Data beats | Longest run (simulated) |
|---|---|---|---|---|---|---|
| Directed tests (Stage 4) | 5 | 5 | 424 | 1,144 | 16,867 | 117 us |
| Clock sweep (Stage 5) | 30 | 30 | 3,360 | 7,620 | 106,905 | 427 us |
| FIFO full at every depth | 3 | 3 | 212 | 596 | 6,992 | 40 us |
| Constrained random, random clocks | 120 | 120 | 24,401 | 42,599 | 716,333 | 1,012 us |
| Targeted random, deep FIFOs | 40 | 40 | 10,317 | 15,274 | 177,413 | 587 us |

## Negative tests

Each fault is injected on purpose; the run must fail, caught by the checker it is aimed at.

| Test | Fault | Expected checker | Result | Scoreboard errors | Assertion errors |
|---|---|---|---|---|---|
| `neg_rdata` | bit 0 of R data flipped at the DUT output | scoreboard | CAUGHT | 7 | 0 |
| `neg_aw_unstable` | AW address changed while VALID=1, READY=0 | handshake SVA only | CAUGHT | 0 | 1 |
| `neg_ptr_glitch` | 2 bits of a crossing gray pointer flipped for one cycle | CDC SVA only | CAUGHT | 0 | 9 |

## FIFO full, per configuration

Runs in which each DUT FIFO was full at least once (VALID=1, READY=0 at its input).

| Configuration | Runs | AW | W | AR | B | R | All five |
|---|---|---|---|---|---|---|---|
| ram_d1 | 11 | 11 | 11 | 11 | 6 | 11 | 6 |
| ram_d2 | 77 | 42 | 73 | 59 | 37 | 76 | 26 |
| ram_d4 | 41 | 8 | 40 | 13 | 4 | 36 | 1 |
| ram_d6 | 41 | 6 | 40 | 7 | 12 | 35 | 2 |
| orig_d2 | 28 | 19 | 28 | 23 | 8 | 27 | 8 |

## Functional coverage

Bins hit / bins in the model (tb/uvm/axi_coverage.svh), merged over the runs of each configuration.

| Configuration | txn | flow | order | clk | scen | Total |
|---|---|---|---|---|---|---|
| ram_d1 | 66/66 | 11/11 | 6/6 | 13/17 | 35/35 | 131/135 (97%) |
| ram_d2 | 66/66 | 11/11 | 6/6 | 17/17 | 35/35 | 135/135 (100%) |
| ram_d4 | 66/66 | 11/11 | 6/6 | 15/17 | 34/35 | 132/135 (98%) |
| ram_d6 | 66/66 | 11/11 | 6/6 | 15/17 | 34/35 | 132/135 (98%) |
| orig_d2 | 66/66 | 11/11 | 6/6 | 16/17 | 35/35 | 134/135 (99%) |
| all | 66/66 | 11/11 | 6/6 | 17/17 | 35/35 | 135/135 (100%) |

Bins never hit over all runs: none.

