# AXI4 CDC Verification: UVM Environment for a BRAM-Based Bridge

![SystemVerilog](https://img.shields.io/badge/SystemVerilog-UVM%201.2-6E64B0)
![SVA](https://img.shields.io/badge/SVA-85%20assertions-6E64B0)
![Coverage](https://img.shields.io/badge/functional%20coverage-146%2F146%20bins%20merged-3B2F8C)
![Regression](https://img.shields.io/badge/regression-269%2F269%20pass-3B2F8C)
[![CI](https://github.com/12yuuuu/axi-cdc-uvm/actions/workflows/ci.yml/badge.svg)](https://github.com/12yuuuu/axi-cdc-uvm/actions/workflows/ci.yml)
![Simulator](https://img.shields.io/badge/simulator-Cadence%20Xcelium-5a5a5a)
![License](https://img.shields.io/badge/license-Apache--2.0-5a5a5a)

A coverage-driven UVM testbench for `axi_cdc_ram`, an AXI4 clock-domain-crossing
bridge whose five asynchronous FIFOs keep their data in dual-clock memory so
FPGA tools can map them to block RAM. I designed that RTL for the PULP
platform ([pulp-platform/axi#294](https://github.com/pulp-platform/axi/issues/294),
[pulp-platform/common_cells#369](https://github.com/pulp-platform/common_cells/pull/369));
this repository verifies it against the original register-based `axi_cdc`
with the same seeds, from transaction level down to the gray-code pointers
that cross the clock boundary.

The environment has transaction-level scoreboarding, constrained-random
traffic, assertions and fault injection across all five AXI channels. The
data check uses a reference model written separately from the AXI spec, and
the sign-off script fails if anything it expects is missing.

**Keywords:** SystemVerilog · UVM 1.2 · SVA (concurrent assertions, `bind`) ·
constrained-random verification · coverage-driven verification (covergroups,
crosses, `ignore_bins`, per-configuration coverage closure) · scoreboard with
an independent spec-based reference model · fault injection · AXI4 (bursts,
narrow and unaligned transfers, write strobes, outstanding transactions,
out-of-order responses, read interleaving, SLVERR/DECERR) · clock-domain
crossing (async FIFO, gray code, 2-FF synchronizer) · regression automation
and sign-off (bash, Python) · CI (GitHub Actions, slang) · Cadence Xcelium

## At a glance

| | |
|---|---|
| **Regression** | 269 runs + 5 fault-injection runs, 0 failures; 4 min on one machine. Signed off by a script that fails on any missing run, log, bin, configuration or negative test |
| **Traffic checked** | 59,761 writes (814,861 write beats) and 107,195 reads; 1,565,019 read data beats compared with the reference model; 128,746 SLVERR/DECERR responses; every field of every beat compared between the two ports |
| **Functional coverage** | 146/146 defined bins, merged over all runs; every configuration hits all 94 transaction, flow and order bins (per-configuration totals 135-146; the clock-relation holes are listed in the [plan](docs/vplan.md#6-status)) |
| **Assertions** | 85 on `axi_cdc_ram`: 40 AXI handshake rules on both ports, 45 CDC pointer rules bound into the 5 FIFOs; 0 fires |
| **Fault injection** | 5/5 faults caught by the checker they are aimed at, while the other checkers stay silent; one is visible to the assertions only, one is a bug in the testbench's own slave |
| **Same seed, two DUTs** | 48 run pairs, `axi_cdc_ram` vs. `axi_cdc`: the same transactions in both traces (every field, data and response) |
| **Configurations** | `LogDepth` 1, 2, 4, 6; RAM FIFOs vs. register FIFOs; clocks 2-30 ns, ratios up to 10:1 in both directions, coincident-edge corners |
| **Reproducibility** | one seed sets clocks, knobs and traffic: same seed and same code, same run |

## Design under test

`axi_cdc_ram` has the same ports as `axi_cdc`: an AXI4 slave port on
`src_clk` and an AXI4 master port on `dst_clk`. Each of the five channels
crosses through its own asynchronous FIFO (AW, W, AR from source to
destination; B, R back). Read and write pointers are gray-coded and pass
through 2-FF synchronizers; the data stays in a dual-clock memory with
2<sup>LogDepth</sup>+1 entries (the register version holds +2). A CDC FIFO
fails in rare corners: full and empty boundaries, pointer wrap-around,
clock ratios, and edges that arrive at the same time. The plan is built
around those corners.

## Testbench

![Fig. 1](docs/fig1_testbench.svg)

*Fig. 1. Testbench. Two clock domains, the DUT between them; handshake
assertions sit on both AXI ports, CDC assertions are bound inside the DUT.
The slave can reorder and interleave responses and return errors.*

| Component | Implementation |
|---|---|
| Master agent | cycle-based pipelined driver on clocking blocks; up to 72 transactions in flight; W may lead AW; random READY on B and R; a hold knob that stops responses until FIFOs fill |
| Memory slave | reactive, sparse byte memory; random READY and latency on every channel; B responses out of order across IDs and R bursts of different IDs interleaved (same-ID order kept, AXI A5.3); SLVERR and DECERR pages; a hold knob for requests |
| Monitors (x2) | rebuild transactions from handshakes; protocol checks (`WLEN`, `RLAST`, `BNOAW`, `RNOAR`); stall counters per channel |
| Scoreboard | three checks. Bridge: the k-th transaction out equals the k-th in, every field and beat. Data: every read beat against a [reference model](tb/uvm/axi_ref_model.svh) that follows the AXI A3.4 pseudo-code step by step and shares no address code with the slave or the sequence item (active byte lanes; narrow, unaligned, FIXED/INCR/WRAP). Response: every B and R response against the address map; error beats carry no data check and failed writes leave memory unchanged. `+TRACE_FILE` writes one line per transaction |
| Coverage | 5 covergroups, 146 bins ([goal list](tb/uvm/coverage_goals.txt)): transaction shape and response type, per-cycle DUT events (FIFO full, back-to-back output, AW/W order on both sides, B reordered, R interleaved), clock relation, FIFO full x clock relation; illegal FIXED/WRAP lengths excluded with `ignore_bins`; bins also counted in the collector, so [tools/merge_cov.py](tools/merge_cov.py) merges runs without a coverage-tool licence |
| Assertions | [axi_handshake_sva.sv](tb/sva/axi_handshake_sva.sv): VALID held until READY, payload stable, no X, VALID low after reset. [cdc_fifo_sva.sv](tb/sva/cdc_fifo_sva.sv), bound into every FIFO: one bit per pointer change, pointer moves exactly on a handshake, occupancy in 0..2<sup>LogDepth</sup> (each side's view and the real one) |
| Stimulus | 10 tests: directed (bursts, ordering, back-pressure, FIFO full), address-model check (15 hand-computed bursts), clock sweep, constrained random (`dist`, implications, AXI legality constraints), out-of-order and error traffic (each ID in its own address slice), targeted random for deep FIFOs; every burst is range-checked after `randomize()` |
| Regression | [sim/regress.sh](sim/regress.sh) runs everything, merges coverage per configuration, compares the traces of both DUTs ([tools/compare_traces.py](tools/compare_traces.py)) and applies the sign-off rules of the [verification plan](docs/vplan.md#5-regression-and-sign-off) ([tools/report.py](tools/report.py)); exit code 0 only when signed off |
| Sign-off tests, CI | [tools/test_report.py](tools/test_report.py): 26 cases of incomplete or bad results (one bin, an empty file, a missing configuration, a missing negative test, ...) that must not sign off. [GitHub Actions](.github/workflows/ci.yml): the whole TB compiled with slang against Accellera UVM, the sign-off tests, and a [Python address model](tools/axi_addr_model.py) against the same hand-computed vectors |

![Fig. 2](docs/fig2_waveform.svg)

*Fig. 2. One 4-beat write crossing from a 10 ns to a 3 ns clock (simulation of
this testbench). Dots mark handshakes. The B response reaches the source port
on the third `src_clk` edge after the slave's B handshake: two synchronizer
stages, then the FIFO's output register.*

## Coverage closure

![Fig. 3](docs/fig3_coverage_closure.svg)

*Fig. 3. Closure of the first 135 bins, per step. Random traffic alone looked
like 95% when all runs were merged, but with `LogDepth` 4 and 6 the AW, AR
and B FIFOs were never full: at most 16 transactions were in flight and
those FIFOs hold 17 to 66. Coverage-driven random added long bursts, more
transactions in flight than the deepest FIFO, and clock corners; targeted
random and directed fills closed the rest. The bins left per deep
configuration are clock-relation crosses, required over all runs (all hit).*

The 11 bins added later (response types, B reordering, R interleaving) took
one more round: merged they were all hit at once, but `LogDepth` 1 never saw
a reordered B. The slave decided as soon as one B was ready, so there was
rarely a choice. With the slave waiting a few cycles for a second B, the
count went from 0 to 411 for `LogDepth` 1 (29 to 2,933 over all runs).

## Fault injection

Each fault is injected on purpose; the run must fail, the checker it is
aimed at must catch it, and the other checkers must stay silent.

| Fault | Scoreboard | Assertions |
|---|---|---|
| bit 0 of R data flipped at the DUT output | 7 errors | 0 |
| B response OKAY turned into SLVERR at the DUT output | 4 errors (response check) | 0 |
| AW address changed while VALID=1, READY=0 | **0 errors** | `SVA_AW` fires one cycle later |
| two bits of a crossing gray pointer flipped for one cycle | 0 errors | `SVA_OCC` at the next clock edge (real occupancy 6 in a 4-entry FIFO), again on the write side's view two synchronizer cycles later; `SVA_GRAY` at the next edge of the pointer's own clock |
| the slave model forgets to wrap WRAP bursts (DUT correct) | 158 data errors; **bridge and response checks 0** | 0 |

The third row is why the assertions exist: the DUT and both monitors take
the payload at the handshake, so they all agree, and only the handshake rule
sees the violation. The last row tests the reference model itself: both DUT
ports agree, so only an address model that does not share code with the
slave can see the bug.

## Findings

* **The upstream testbench never filled the FIFOs.** All its tests pass, yet
  no FIFO was ever full. A FIFO-full test with scenario checks closed the gap
  for both designs.
* **Merged coverage hid holes, twice** (Fig. 3, and the B reordering at
  `LogDepth` 1). Coverage has to be read per configuration, so the sign-off
  script checks every configuration, not only the merged total.
* **The directed burst test looked complete but missed 17-255 beats.**
* **A checker caught my own stimulus.** A read raced a write to the same
  address; AXI does not order the read and write channels, so the fix was in
  the test, not in the DUT.
* **A 32-bit overflow in a constraint.** `addr + bytes <= base + span` is
  computed in 32 bits, so a burst at `0xFFFFF800` "fits" because the sum wraps
  to 0. With 16 KiB windows nothing failed (such a burst is still checked
  correctly, it just lands outside the intended region). With 1 KiB slices
  per ID the slices overlapped and 7 of 8 out-of-order runs failed, each seed
  at the same places on both DUTs, which pointed at the testbench. Fixed with
  64-bit sums, plus a range check after every `randomize()`, so a wrong
  constraint now fails loudly.
* **Coincident clock edges** add one synchronizer cycle in simulation. Real
  hardware could resolve either way, so RTL simulation cannot prove CDC
  safety; that needs structural CDC checks and timing constraints.
* **Seeds are stable while the code that draws them stays the same.** After
  adding the coverage collector and 85 assertions, every earlier run gave the
  same clocks, transaction counts, stall cycles and end time: the checkers
  only observe. A small edit in `tb_top` did move its random clocks, though,
  so every change gets a full new regression; old numbers are not reused.

## Run it

Needs Cadence Xcelium with UVM 1.2 (tested: Xcelium 23.09, `CDNS-1.2`),
bash and python3.

```sh
bash sim/regress.sh            # full regression; writes logs/regress/results.md
bash sim/regress.sh quick      # about 1 minute
bash sim/run_one.sh rand_cov_test 7 1 2 +RAND_CLOCKS +CLK_CORNERS +VCD   # one seed, with waves
bash sim/run_one.sh rand_ooo_test 3 1 2 +RAND_CLOCKS +CLK_CORNERS +TRACE_FILE=ooo3.trace
```

Without a simulator (the CI does the same):

```sh
python3 tools/test_report.py                        # sign-off rules
python3 tools/axi_addr_model.py                     # address model vs. hand-computed vectors
python3 tools/lint_tb.py --uvm <uvm-core>/src       # compile everything with slang (pip install pyslang)
```

`run_one.sh <test> <seed> [USE_RAM] [LOG_DEPTH] [plusargs]`. `USE_RAM=1`
selects `axi_cdc_ram`, `0` the original `axi_cdc`. Tests: `smoke_test`,
`burst_test`, `order_test`, `backpressure_test`, `fifo_full_test`,
`addr_model_test`, `rand_test`, `rand_cov_test`, `rand_ooo_test`,
`rand_deep_test`. Full results:
[docs/results.md](docs/results.md); plan and sign-off rules:
[docs/vplan.md](docs/vplan.md).

## Layout

```
rtl/        vendored PULP RTL and the DUT (sources and versions: rtl/README.md)
tb/uvm/     UVM package: item, driver, slave, monitors, reference model, scoreboard,
            coverage (and its goal list), sequences, tests
tb/sva/     handshake and CDC assertions
tb/top/     tb_top: DUT, interfaces, clocks, resets, binds, fault injection
sim/        regress.sh, run_one.sh, common.sh
tools/      sign-off report and its tests, coverage merge, trace compare,
            Python address model, slang compile check, figures
docs/       verification plan, results, figures
.github/    CI workflow
```

## Known issue

On Debian 12, Xcelium 23.09 prints `*E,IMPDLL` at start-up: its bundled
linker (binutils 2.34) cannot read the system `libm.so.6` (DT_RELR), so the
UVM library's DPI export file is not built. This testbench uses no DPI
exports, every test runs normally, and the scripts ignore this one message.

## License and credits

Testbench, scripts and docs: Apache-2.0 ([LICENSE](LICENSE)). RTL in `rtl/`:
SHL-0.51, from the PULP platform (ETH Zurich and University of Bologna); see
[rtl/README.md](rtl/README.md).

Parts of the testbench were written with help from Claude (Anthropic).
