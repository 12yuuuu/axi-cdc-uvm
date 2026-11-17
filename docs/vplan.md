# Verification plan: axi_cdc_ram

This plan lists what the testbench must show for `axi_cdc_ram` (the AXI4
clock-domain-crossing bridge with RAM-based CDC FIFOs, see
pulp-platform/axi#294), how each item is checked, which tests drive it, and
which coverage bins prove that the tests really reached it.

The baseline `axi_cdc` (register-based FIFOs) runs on the same testbench
with the same seeds, so the two can be compared.

## 1. Scope

| | |
|---|---|
| DUT | `axi_cdc_ram`; baseline `axi_cdc` |
| Parameters | `LogDepth` 1, 2, 4, 6; `SyncStages` 2; AXI: 32-bit address, 64-bit data, 4-bit ID, 1-bit user |
| Interfaces | AXI4 slave port on `src_clk`, AXI4 master port on `dst_clk` |
| Clocks | independent, any ratio; tested 2-30 ns each, both directions, with and without coincident edges |
| Reset | power-on only: both resets asserted together, released synchronously to their own clock (DUT rule) |
| Level | RTL simulation, transaction-level UVM testbench, Cadence Xcelium |

### Not covered here

| Item | Why / where |
|---|---|
| Metastability, synchronizer MTBF | RTL simulation cannot show it. Needs structural CDC checks and timing constraints (`set_max_delay` on the async nets). Planned: metastability injection on the synchronizers (extra item). |
| Reset of one side during traffic | Not supported by the design (same rule as `axi_cdc`). |
| Exclusive access, atomics (ATOP) | The DUT only carries these fields. The tests keep them at 0, because the slave model does not implement them. |
| Gate-level / post-fit timing | Extra item (Quartus post-fit netlist simulation). |

## 2. Checkers

| Checker | What it checks | Where |
|---|---|---|
| Bridge check | the k-th write (read) finished at the destination equals the k-th one finished at the source, every field and every beat | `axi_scoreboard` (`SB_WRITE`, `SB_READ`) |
| End-to-end data check | every read returns what a reference memory holds, active byte lanes only (AXI A3.4.3), unwritten bytes read 0 | `axi_scoreboard` (`SB_DATA`) |
| Completeness | nothing lost, duplicated or left half-done | `SB_EXTRA`, `SB_MISSING`, monitor `UNFINISHED` |
| Monitor protocol checks | W beat count = AWLEN+1, RLAST on the right beat, B/R only for open IDs | `axi_monitor` (`WLEN`, `RLAST`, `BNOAW`, `RNOAR`) |
| Scenario checks | the FIFO-full test really filled all five FIFOs | `fifo_full_test` (`SCENARIO`) |
| Coverage self-check | the coverage collector and the monitors count the same FIFO-full cycles | `axi_env` (`COVCHK`) |
| Hang check | every test ends within 50 ms of simulated time | `tb_top` (`WATCHDOG`) |
| AXI handshake rules (SVA) | on both sides, every channel: VALID stays high until READY; payload stable while waiting; no X on VALID/READY, none on the payload while VALID; VALID low right after reset | `tb/sva/axi_handshake_sva.sv` (`SVA_AW` ... `SVA_R`) |
| CDC pointer rules (SVA, bound into the RTL) | crossing pointers change one bit per clock; a pointer moves exactly on a handshake; occupancy stays in 0..2^LogDepth (each side's view, and the real one for the RAM FIFO) | `tb/sva/cdc_fifo_sva.sv` (`SVA_GRAY`, `SVA_MOVE`, `SVA_OCC`) |
| Checker sanity | each injected fault must make the test fail, caught by the checker it is aimed at: wrong R data -> scoreboard; AW payload change while waiting -> handshake SVA only; pointer glitch -> CDC SVA only | negative tests `+INJECT_RDATA_ERR`, `+INJECT_AW_UNSTABLE`, `+INJECT_PTR_GLITCH` |

## 3. Features

| ID | Feature | Checked by | Tests | Coverage |
|---|---|---|---|---|
| F1 | Every AXI field and beat crosses unchanged (all 5 channels) | bridge check | all | `txn.*` |
| F2 | Nothing lost, duplicated or added | completeness | all | - |
| F3 | Order kept on every channel | bridge check (k-th = k-th) | all | - |
| F3b | AXI handshake rules kept on both sides (by the DUT and by the testbench) | handshake SVA | all | - |
| F3c | Gray pointers cross the clock boundary one bit at a time and move only on a handshake | CDC SVA | all | - |
| F4 | Memory view is right for all burst shapes: FIXED, INCR, WRAP; 1-256 beats; narrow beats; unaligned start; sparse and empty strobes | data check | `burst_test`, `rand_*` | `txn.burst`, `txn.len`, `txn.size`, `txn.align`, `txn.strb`, `txn.x_kbl`, `txn.x_ks` |
| F5 | Each of the five FIFOs gets full, back-pressures its input, and drains without loss; pointers never overflow or underflow | stall counters, `SCENARIO`, data check, `SVA_OCC` | `fifo_full_test`, `rand_*` | `flow.full.*` |
| F6 | Data streams across the CDC at one item per cycle when nothing stalls | - | all | `flow.b2b.*` |
| F7 | AW and W are independent: W before AW, same cycle, AW before W, on both sides of the DUT | bridge check | `order_test`, `rand_*` | `order.*` |
| F8 | Reads and writes at the same time | bridge + data check | `order_test`, `backpressure_test`, `rand_*` | `flow.rw.*` |
| F9 | Random back-pressure on every channel, both sides | all checkers | `backpressure_test`, `rand_*` | `flow.full.*` |
| F10 | Clock relation: source 2x faster or more, faster, same, slower, 2x slower or more; with and without coincident rising edges | all checkers | Stage 5 sweep, `rand_*` with `+RAND_CLOCKS`, `+CLK_CORNERS` | `clk.*` |
| F11 | Every FIFO gets full under every clock relation | as F5 | `rand_*` | `scen.*` |
| F12 | Works for `LogDepth` 1, 2, 4 and 6 | all checkers | regression configs | per-config merge |
| F13 | Same transactions and data as the baseline `axi_cdc` for the same seed | bridge + data check | Stage 6/7 regressions | - |

## 4. Coverage model

`tb/uvm/axi_coverage.svh`. Five covergroups; each bin is also counted by
the collector and printed as a `[COVBIN]` line, so `tools/merge_cov.py`
can merge any set of runs.

| Group | Sampled | Bins |
|---|---|---|
| `txn` | each transaction sent into the DUT | kind (2), burst (3), length (8 buckets: 1, 2, 3-4, 5-8, 9-15, 16, 17-255, 256), size (4), alignment (2), strobes (3, writes only), kind x burst x length (36 legal), kind x size (8) = 66 |
| `flow` | every clock cycle | FIFO full per channel (5), back-to-back output per channel (5), AW and AR in the same cycle (1) = 11 |
| `order` | first W beat of each write | side (src/dst) x order (W first, same cycle, AW first) = 6 |
| `clk` | end of run | ratio bucket (5), coincident edges yes/no (2), cross (10) = 17 |
| `scen` | end of run, per FIFO that was full | channel x ratio (25), channel x coincident (10) = 35 |

Illegal bins (ignored): FIXED bursts longer than 16 beats; WRAP bursts that
are not 2, 4, 8 or 16 beats (AXI A3.4.1).

## 5. Regression and sign-off

* Directed tests (Stage 4), clock sweep (Stage 5), random regression with
  random clocks (Stages 6 and 7).
* Every run is reproducible from its seed: `sim/run_one.sh <test> <seed> ...`.
* Sign-off: 0 failing runs; 0 assertion fires; every negative test caught
  by its checker; coverage:
  * merged regression: every bin hit, or listed below with a reason;
  * every configuration (LogDepth 1, 2, 4, 6; `axi_cdc` baseline): all
    `txn`, `flow` and `order` bins. The clock-relation groups (`clk`,
    `scen`) count over the merged regression: the CDC logic is the same for
    every depth, only the pointer width changes, and that is covered by
    filling and draining every FIFO at every depth.

## 6. Status

Final regression (`bash sim/regress.sh`, 2026-11-17, full page in
[results.md](results.md)): **signed off**.

* 198 runs, 0 failures; 38,714 writes, 67,233 reads and 1,024,510 data
  beats checked; 0 assertion fires.
* 3 negative tests, each caught by its checker. The AW payload change is
  caught by the handshake assertion alone (scoreboard: 0 errors).
* Coverage: 135/135 bins over all runs. Every configuration (LogDepth 1, 2,
  4, 6 and the `axi_cdc` baseline) hits all 83 `txn`, `flow` and `order`
  bins.

| ID | Status | Evidence |
|---|---|---|
| F1-F3 | done | bridge check, 0 errors in 198 runs |
| F3b, F3c | done | 0 assertion fires; `neg_aw_unstable`, `neg_ptr_glitch` caught |
| F4 | done | `txn` 66/66 in every configuration |
| F5 | done | `flow.full.*` in every configuration; `SVA_OCC` 0 fires |
| F6-F9 | done | `flow`, `order` 17/17 in every configuration |
| F10, F11 | done | `clk` 17/17 and `scen` 35/35 over all runs |
| F12 | done | per-configuration table in results.md |
| F13 | done | same seeds give the same transactions and data on both DUTs |

Clock-relation bins that a single configuration did not hit (they are hit
over all runs, as section 5 allows):

| Configuration | Not hit |
|---|---|
| LogDepth 1 | `clk` 4 bins (coincident edges with the source clock faster; same frequency without coincident edges; destination faster without coincident edges) |
| LogDepth 4 | `clk` 2 bins (same frequency without coincident edges; source 2x faster with coincident edges), `scen` B full with source faster |
| LogDepth 6 | `clk` 2 bins (same as LogDepth 4), `scen` AR full at the same frequency |
| `axi_cdc` | `clk` 1 bin (source 2x faster with coincident edges) |

### How the coverage got closed

| Step | What changed | Coverage (all runs) |
|---|---|---|
| Directed tests only | - | 93/135 |
| + `rand_test` (Stage 6) | random traffic and clocks | 131/135; LogDepth 4 and 6 never filled the AW, AR or B FIFO (at most 16 transactions in flight, those FIFOs hold 17-66) |
| + `rand_cov_test` (Stage 7) | more in flight than the biggest FIFO; bursts up to 256 beats; clock corners with coincident edges | 134/135; deep FIFOs still rarely full |
| + `rand_deep_test` and directed fills (Stage 8) | long holds, short bursts, enough transactions; `fifo_full_test` at every depth; same frequency with a fixed phase offset | 135/135 |
