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
| EXOKAY responses | Only with exclusive access (above). OKAY, SLVERR and DECERR are covered. |
| Gate-level / post-fit timing | Extra item (Quartus post-fit netlist simulation). |

## 2. Checkers

| Checker | What it checks | Where |
|---|---|---|
| Bridge check | the k-th write (read) finished at the destination equals the k-th one finished at the source, every field and every beat | `axi_scoreboard` (`SB_WRITE`, `SB_READ`) |
| End-to-end data check | every read beat returns what the reference model holds, active byte lanes only, unwritten bytes read 0. The model (`axi_ref_model`) computes beat addresses and byte lanes with the AXI A3.4.2 pseudo-code (aligned address, wrap boundary, lower/upper byte lane, with divisions); the slave and the sequence item use their own closed-form code (masks), so the two do not share an address function | `axi_scoreboard` (`SB_DATA`) |
| Response check | every B response and every R beat's response equals the address map: OKAY, except the SLVERR page and the DECERR page of region E (whole 4 KiB pages, so one burst never mixes them). Error beats get no data check (AXI leaves the data undefined); a write that got an error does not change the reference memory | `axi_scoreboard` (`SB_RESP`) |
| Address-model check | 15 hand-computed bursts (INCR/FIXED/WRAP, unaligned, narrow, byte lanes, 256 beats, start on a wrap boundary) against both models; then 20,000 random legal bursts, model against model. A third model in Python checks the same vectors | `addr_model_test` (`ADDR`), `tools/axi_addr_model.py` |
| Stimulus range check | after `randomize()`, every burst lies inside its sequence's address window (and its ID's slice) | `axi_rand_seq` (`SEQ_RANGE`) |
| Completeness | nothing lost, duplicated or left half-done | `SB_EXTRA`, `SB_MISSING`, monitor `UNFINISHED` |
| Monitor protocol checks | W beat count = AWLEN+1, RLAST on the right beat, B/R only for open IDs | `axi_monitor` (`WLEN`, `RLAST`, `BNOAW`, `RNOAR`) |
| Scenario checks | the FIFO-full test really filled all five FIFOs | `fifo_full_test` (`SCENARIO`) |
| Coverage self-check | the coverage collector and the monitors count the same FIFO-full cycles | `axi_env` (`COVCHK`) |
| Hang check | every test ends within 50 ms of simulated time | `tb_top` (`WATCHDOG`) |
| AXI handshake rules (SVA) | on both sides, every channel: VALID stays high until READY; payload stable while waiting; no X on VALID/READY, none on the payload while VALID; VALID low right after reset | `tb/sva/axi_handshake_sva.sv` (`SVA_AW` ... `SVA_R`) |
| CDC pointer rules (SVA, bound into the RTL) | crossing pointers change one bit per clock; a pointer moves exactly on a handshake; occupancy stays in 0..2^LogDepth (each side's view, and the real one for the RAM FIFO) | `tb/sva/cdc_fifo_sva.sv` (`SVA_GRAY`, `SVA_MOVE`, `SVA_OCC`) |
| Checker sanity | each injected fault must make the test fail with errors of the checker it is aimed at, and the checkers it is not aimed at must report nothing: wrong R data -> `SB_DATA`, no SVA; B OKAY turned into SLVERR -> `SB_RESP`, no SVA; AW payload change while waiting -> `SVA_AW`, no scoreboard error; pointer glitch -> `SVA_GRAY`, no scoreboard error; slave forgets to wrap WRAP bursts -> `SB_DATA`, no bridge, response or SVA error | negative tests `+INJECT_RDATA_ERR`, `+INJECT_BRESP_ERR`, `+INJECT_AW_UNSTABLE`, `+INJECT_PTR_GLITCH`, `+INJECT_SLV_WRAP_BUG` |
| Same seed, both DUTs | runs with a twin on the other DUT write a trace (`+TRACE_FILE`): one line per transaction finished at the source with every request field, hashes of data, strobes and user bits, and a hash of the responses. The two traces must hold the same lines (as a multiset: completion order may differ, AXI only orders same-ID responses) | `tools/compare_traces.py` |
| Sign-off script | incomplete or bad results must not sign off; 26 cases | `tools/test_report.py`, also in CI |

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
| F13 | Same transactions and data as the baseline `axi_cdc` for the same seed | trace comparison | `rand_cov_test`, `rand_ooo_test`, clock sweep (48 pairs) | - |
| F14 | Responses that AXI allows out of order cross unchanged: B of different IDs out of order, R beats of different IDs interleaved; same-ID order kept | bridge check, monitors (R rebuilt per ID) | `rand_ooo_test` | `flow.reorder.*` |
| F15 | SLVERR and DECERR cross unchanged on B and on every R beat; failed writes do not change memory | response check, data check | `rand_ooo_test` (region E) | `txn.resp.*`, `txn.x_kr.*` |
| F16 | The data check does not depend on code it checks: a bug in the slave's address computation is caught | address-model check; negative test `neg_slave_wrap` | `addr_model_test` | - |

## 4. Coverage model

`tb/uvm/axi_coverage.svh`. Five covergroups; each bin is also counted by
the collector and printed as a `[COVBIN]` line, so `tools/merge_cov.py`
can merge any set of runs.

| Group | Sampled | Bins |
|---|---|---|
| `txn` | each transaction sent into the DUT (response: when it finishes) | kind (2), burst (3), length (8 buckets: 1, 2, 3-4, 5-8, 9-15, 16, 17-255, 256), size (4), alignment (2), strobes (3, writes only), response (3: OKAY, SLVERR, DECERR), kind x burst x length (36 legal), kind x size (8), kind x response (6) = 75 |
| `flow` | every clock cycle | FIFO full per channel (5), back-to-back output per channel (5), AW and AR in the same cycle (1), B out of order and R interleaved at the source port (2) = 13 |
| `order` | first W beat of each write | side (src/dst) x order (W first, same cycle, AW first) = 6 |
| `clk` | end of run | ratio bucket (5), coincident edges yes/no (2), cross (10) = 17 |
| `scen` | end of run, per FIFO that was full | channel x ratio (25), channel x coincident (10) = 35 |

Illegal bins (ignored): FIXED bursts longer than 16 beats; WRAP bursts that
are not 2, 4, 8 or 16 beats (AXI A3.4.1).

The 146 bin names are fixed in `tb/uvm/coverage_goals.txt`. This list, not
whatever a coverage file happens to contain, is the denominator for
sign-off.

## 5. Regression and sign-off

* `sim/regress.sh`: 5 negative tests, directed tests, clock sweep, FIFO
  full at every depth, random regression with random clocks, out-of-order
  and error traffic, targeted random for deep FIFOs (269 runs).
* Every run is reproducible from its seed: `sim/run_one.sh <test> <seed> ...`.
* Sign-off (`tools/report.py`; anything missing counts as a failure):
  * every negative test is present and caught, as section 2 defines;
  * every run passes, with 0 assertion fires;
  * every run's log reports exactly the 146 goal bins, and the merged
    coverage file has exactly those bins;
  * every configuration (LogDepth 1, 2, 4, 6; `axi_cdc` baseline) has runs
    and a coverage column;
  * merged regression: every bin hit;
  * every configuration: all 94 `txn`, `flow` and `order` bins. The
    clock-relation groups (`clk`, `scen`) count over the merged regression:
    the CDC logic is the same for every depth, only the pointer width
    changes, and that is covered by filling and draining every FIFO at
    every depth;
  * at least one pair of traces, and every pair the same (F13).

## 6. Status

Final regression (`bash sim/regress.sh`, 2026-11-17, full page in
[results.md](results.md)): **signed off**.

* 269 runs, 0 failures; 59,761 writes (814,861 beats) and 107,195 reads;
  1,565,019 read beats matched the reference model; 128,746 SLVERR/DECERR
  responses checked; 0 assertion fires.
* 5 negative tests, each caught by its checker with the other checkers
  silent. The AW payload change is caught by the handshake assertion alone
  (scoreboard: 0 errors); the slave's WRAP bug by the data check alone
  (bridge and response checks: 0 errors).
* Coverage: 146/146 defined bins, merged over all runs. Every configuration
  hits all 94 `txn`, `flow` and `order` bins.
* 48 trace pairs (`axi_cdc_ram` vs. `axi_cdc`, same test and seed): all hold
  the same transactions; 8 also finish in the same order.

| ID | Status | Evidence |
|---|---|---|
| F1-F3 | done | bridge check, 0 errors in 269 runs |
| F3b, F3c | done | 0 assertion fires; `neg_aw_unstable`, `neg_ptr_glitch` caught |
| F4 | done | `txn` 75/75 in every configuration |
| F5 | done | `flow.full.*` in every configuration; `SVA_OCC` 0 fires |
| F6-F9 | done | `flow` 13/13 and `order` 6/6 in every configuration |
| F10, F11 | done | `clk` 17/17 and `scen` 35/35 over all runs |
| F12 | done | per-configuration table in results.md |
| F13 | done | 48/48 trace pairs with the same transactions |
| F14 | done | `flow.reorder.*` in every configuration (B out of order 2,933 times, R interleaved 227,402 times); 0 bridge errors |
| F15 | done | `txn.resp.*`, `txn.x_kr.*` in every configuration; 128,746 error responses, 0 response errors; `neg_bresp` caught |
| F16 | done | `addr_model_test`: 15 + 20,000 bursts, 0 mismatches; Python model 15/15; `neg_slave_wrap` caught by the data check only |

Clock-relation bins that a single configuration did not hit (they are hit
over all runs, as section 5 allows):

| Configuration | Not hit |
|---|---|
| LogDepth 1 | `clk` 5 bins (no run with the destination clock faster: the ratio bin and its two crosses; same frequency without coincident edges; source 2x faster with coincident edges); `scen` 6 bins (each FIFO full with the destination clock faster; B full at the same frequency) |
| LogDepth 4 | `clk` 2 bins (destination faster with coincident edges; same frequency without coincident edges); `scen` 4 bins (AR full at the same frequency; AW and B full with the destination faster; B full at the same frequency) |
| LogDepth 6 | `clk` 2 bins (same as LogDepth 4); `scen` 3 bins (AR full with the destination faster; AR and AW full with the source faster) |
| `axi_cdc` | `clk` 1 bin (destination faster with coincident edges); `scen` 1 bin (B full with the destination faster) |

### How the coverage got closed

The first five rows are on the first coverage model (135 bins); Stage 11
added 11 bins and the out-of-order and error traffic.

| Step | What changed | Coverage (all runs) |
|---|---|---|
| Directed tests only | - | 93/135 |
| + `rand_test` (Stage 6) | random traffic and clocks | 131/135; LogDepth 4 and 6 never filled the AW, AR or B FIFO (at most 16 transactions in flight, those FIFOs hold 17-66) |
| + `rand_cov_test` (Stage 7) | more in flight than the biggest FIFO; bursts up to 256 beats; clock corners with coincident edges | 134/135; deep FIFOs still rarely full |
| + `rand_deep_test` and directed fills (Stage 8) | long holds, short bursts, enough transactions; `fifo_full_test` at every depth; same frequency with a fixed phase offset | 135/135 |
| + `rand_ooo_test` (Stage 11) | slave reorders B, interleaves R, answers SLVERR/DECERR on two pages; coverage model 146 bins | 146/146 merged, but LogDepth 1 never had a B out of order (29 over all runs, 0 at LogDepth 1) |
| + B gathering (Stage 11) | with one B ready, the slave waits up to 8-48 cycles for a second one; region E keeps at least 8 transactions in flight | 146/146; every configuration 94/94 (B out of order 2,933 times, 411 at LogDepth 1) |

Two bugs in the testbench itself turned up on the way and are fixed: a read
that raced a write to the same address (Stage 7), and a 32-bit overflow in
the address-window constraint that let bursts wrap around at 2^32 and break
the per-ID slices (Stage 11; now 64-bit sums plus `SEQ_RANGE`).
