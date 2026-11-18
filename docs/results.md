# Regression results

- **Mode:** full
- **Simulator:** Cadence Xcelium 23.09-s006, UVM 1.2 (CDNS-1.2)
- **Host:** EECG ug136 (Debian 12), University of Toronto
- **Date:** 2026-11-17 19:54 EST
- **Wall time:** 4 min 18 s (one machine, runs in sequence)

**Verdict: SIGNED OFF**

269 runs, 269 passed; 59,761 writes (814,861 beats) and 107,195 reads checked; 1,565,019 read beats matched the reference model; 128,746 error responses checked; 0 assertion fires; 5 negative tests, 5 caught.

## Runs

| Set | Runs | Passed | Writes | Write beats | Reads | Read beats checked | Error responses | Longest run (simulated) |
|---|---|---|---|---|---|---|---|---|
| Directed tests | 6 | 6 | 426 | 3,838 | 1,146 | 16,872 | 0 | 117 us |
| Clock sweep | 30 | 30 | 3,360 | 27,075 | 7,620 | 106,905 | 0 | 427 us |
| FIFO full at every depth | 3 | 3 | 212 | 848 | 596 | 6,992 | 0 | 40 us |
| Constrained random, random clocks | 120 | 120 | 24,401 | 404,506 | 42,599 | 716,333 | 0 | 977 us |
| Out-of-order, interleaving, error responses | 70 | 70 | 21,045 | 351,012 | 39,960 | 540,504 | 128,746 | 1,611 us |
| Targeted random, deep FIFOs | 40 | 40 | 10,317 | 27,582 | 15,274 | 177,413 | 0 | 573 us |

## Negative tests

Each fault is injected on purpose; the run must fail, caught by the checker it is aimed at.

| Test | Fault | Expected checker | Result | Scoreboard errors | Assertion errors |
|---|---|---|---|---|---|
| `neg_rdata` | bit 0 of R data flipped at the DUT output | scoreboard (data) | CAUGHT | 7 | 0 |
| `neg_bresp` | B response OKAY turned into SLVERR at the DUT output | scoreboard (response) | CAUGHT | 4 | 0 |
| `neg_aw_unstable` | AW address changed while VALID=1, READY=0 | handshake SVA only | CAUGHT | 0 | 1 |
| `neg_ptr_glitch` | 2 bits of a crossing gray pointer flipped for one cycle | CDC SVA only | CAUGHT | 0 | 9 |
| `neg_slave_wrap` | slave model forgets to wrap WRAP bursts | reference model only | CAUGHT | 158 | 0 |

## Same seed, both DUTs

48 pairs of runs (`axi_cdc_ram` vs. `axi_cdc`, same test and seed): 48 with the same transactions (every field, data and response, compared as a set); 8 also in the same order.

## FIFO full, per configuration

Runs in which each DUT FIFO was full at least once (VALID=1, READY=0 at its input).

| Configuration | Runs | AW | W | AR | B | R | All five |
|---|---|---|---|---|---|---|---|
| ram_d1 | 21 | 21 | 21 | 21 | 12 | 21 | 12 |
| ram_d2 | 98 | 48 | 93 | 71 | 44 | 97 | 28 |
| ram_d4 | 51 | 9 | 45 | 10 | 4 | 45 | 1 |
| ram_d6 | 51 | 5 | 46 | 4 | 10 | 49 | 2 |
| orig_d2 | 48 | 22 | 48 | 33 | 17 | 47 | 11 |

## Functional coverage

Bins hit / bins in the model (146 bins, tb/uvm/coverage_goals.txt), merged over the runs of each configuration.

| Configuration | txn | flow | order | clk | scen | Total |
|---|---|---|---|---|---|---|
| ram_d1 | 75/75 | 13/13 | 6/6 | 12/17 | 29/35 | 135/146 (92%) |
| ram_d2 | 75/75 | 13/13 | 6/6 | 17/17 | 35/35 | 146/146 (100%) |
| ram_d4 | 75/75 | 13/13 | 6/6 | 15/17 | 31/35 | 140/146 (96%) |
| ram_d6 | 75/75 | 13/13 | 6/6 | 15/17 | 32/35 | 141/146 (97%) |
| orig_d2 | 75/75 | 13/13 | 6/6 | 16/17 | 34/35 | 144/146 (99%) |
| all | 75/75 | 13/13 | 6/6 | 17/17 | 35/35 | 146/146 (100%) |

Bins never hit over all runs: none.

