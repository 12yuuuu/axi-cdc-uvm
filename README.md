# AXI4 CDC Verification: UVM Environment for a BRAM-Based Bridge

![SystemVerilog](https://img.shields.io/badge/SystemVerilog-UVM%201.2-6E64B0)
![SVA](https://img.shields.io/badge/SVA-85%20assertions-6E64B0)
![Coverage](https://img.shields.io/badge/functional%20coverage-146%2F146%20bins%20merged-3B2F8C)
![Regression](https://img.shields.io/badge/regression-269%2F269%20pass-3B2F8C)
[![CI](https://github.com/12yuuuu/axi-cdc-uvm/actions/workflows/ci.yml/badge.svg)](https://github.com/12yuuuu/axi-cdc-uvm/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-Apache--2.0-5a5a5a)

This repository contains a SystemVerilog/UVM verification environment for
`axi_cdc_ram`, an AXI4 clock-domain-crossing (CDC) bridge whose five
asynchronous FIFOs keep their data in dual-clock memory, so that FPGA tools
can map them to block RAM. I contributed the RTL to the PULP platform
([axi#294](https://github.com/pulp-platform/axi/issues/294),
[common_cells#369](https://github.com/pulp-platform/common_cells/pull/369)).
The environment checks it against the register-based `axi_cdc` under the
same seeds, from complete transactions down to the gray-coded pointers that
cross the clock boundary.

## Results

| Metric | Result |
|---|---|
| Regression | 269 runs and 5 fault-injection runs, 0 failures (4 min on one machine) |
| Traffic checked | 59,761 writes (814,861 beats); 107,195 reads (1,565,019 data beats checked); 128,746 error responses |
| Functional coverage | 146/146 defined bins, merged; all 94 transaction, flow and order bins in every configuration |
| Assertions | 85 (40 handshake, 45 CDC pointer), 0 failures |
| Fault injection | 5/5 faults detected, each by its intended checker only |
| Equivalence with `axi_cdc` | same transactions in 48/48 same-seed run pairs |
| Configurations | `LogDepth` 1, 2, 4, 6; RAM or register FIFOs; clock periods 2-30 ns, ratios up to 10:1, coincident edges |

Per-configuration numbers are in [docs/results.md](docs/results.md); the
plan and the sign-off rules are in [docs/vplan.md](docs/vplan.md).

## Design under test

`axi_cdc_ram` has the ports of `axi_cdc`: an AXI4 slave port on `src_clk`
and an AXI4 master port on `dst_clk`. Each channel crosses through its own
asynchronous FIFO (AW, W and AR forward; B and R back). The pointers are
gray-coded and pass through 2-FF synchronizers; the data stays in a
dual-clock memory with 2<sup>LogDepth</sup>+1 entries. Such FIFOs fail in
rare corners (full and empty boundaries, pointer wrap-around, extreme clock
ratios, coincident edges), and the plan is built around them.

## Verification environment

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/fig1_testbench_dark.svg">
  <img src="docs/fig1_testbench.svg" width="830" alt="Fig. 1: testbench">
</picture>

*Fig. 1. Testbench. Handshake assertions sit on both ports; CDC assertions
are bound inside the DUT.*

| Component | Description |
|---|---|
| Master agent | Pipelined driver on clocking blocks; up to 72 outstanding transactions; W may precede AW; random back-pressure on B and R |
| Memory slave | Sparse byte memory with random latency; reorders B and interleaves R across IDs, keeping same-ID order (AXI A5.3); SLVERR and DECERR pages |
| Monitors | Rebuild transactions at both ports; check WLEN, RLAST and response IDs |
| Scoreboard | (i) every field and beat compared between the ports; (ii) read data against a reference model; (iii) responses against the address map |
| Assertions | Handshake rules on both ports; CDC rules bound into every FIFO: one-bit gray steps, pointer moves only on a handshake, occupancy bounds |
| Coverage | 5 covergroups, 146 bins: transaction shape and response, FIFO events, AW/W order, clock relation, FIFO full x clock relation |
| Stimulus | 10 tests: directed, clock sweep, constrained random, out-of-order and error traffic, targeted random for deep FIFOs |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/fig2_waveform_dark.svg">
  <img src="docs/fig2_waveform.svg" width="830" alt="Fig. 2: one write crossing the bridge">
</picture>

*Fig. 2. A 4-beat write crossing from a 10 ns to a 3 ns clock. Dots mark
handshakes. B reaches the source port on the third `src_clk` edge after the
slave's handshake: two synchronizer stages and one output register.*

## Independent checking

A checker that shares code with the stimulus can fail in the same way, so
the main checks are kept separate:

- **Reference model.** [`axi_ref_model`](tb/uvm/axi_ref_model.svh) follows the
  AXI A3.4 pseudo-code and shares no address code with the slave. It is
  checked against 15 hand-computed bursts, 20,000 random bursts and a
  [Python model](tools/axi_addr_model.py).
- **Sign-off.** [`report.py`](tools/report.py) compares every run with a fixed
  list of 146 bins and fails if any run, bin, configuration or negative test
  is missing. 26 cases in [`test_report.py`](tools/test_report.py) confirm that
  incomplete results are rejected.
- **Equivalence.** Same-seed runs on both DUTs write transaction traces, and
  [`compare_traces.py`](tools/compare_traces.py) requires identical sets.
- **CI.** [GitHub Actions](.github/workflows/ci.yml) compiles the testbench
  with slang against Accellera UVM and runs the Python checks.

## Coverage closure

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/fig3_coverage_closure_dark.svg">
  <img src="docs/fig3_coverage_closure.svg" width="830" alt="Fig. 3: coverage closure">
</picture>

*Fig. 3. Closure of the first 135 bins. Merged random runs reached 95%, but
with `LogDepth` 4 and 6 the AW, AR and B FIFOs were never full. More
outstanding transactions, long bursts, clock corners and targeted fills
closed the gaps.*

The 11 bins added later (response types, B reordering, R interleaving) were
all hit in the merged runs, yet `LogDepth` 1 never saw a reordered B. Letting
the slave wait for a second B raised the count from 0 to 411.

## Fault injection

Each fault must fail the run through its intended checker while the other
checkers stay silent.

| Injected fault | Scoreboard | Assertions |
|---|---|---|
| R data bit flipped at the DUT output | 7 data errors | 0 |
| B response OKAY changed to SLVERR | 4 response errors | 0 |
| AW address changed while VALID=1, READY=0 | 0 | `SVA_AW` |
| Two bits of a crossing gray pointer flipped | 0 | `SVA_OCC`, `SVA_GRAY` |
| Slave does not wrap WRAP bursts (DUT correct) | 158 data errors, 0 port errors | 0 |

The AW fault is invisible to the scoreboard, because the DUT and both
monitors sample the payload at the handshake. The slave fault is invisible
to the port comparison, so only the independent reference model detects it.

## Findings

1. The upstream testbench never filled a FIFO, although all its tests pass.
2. Merged coverage hid configuration-specific holes twice (deep FIFOs; B
   reordering at `LogDepth` 1). Sign-off is therefore per configuration.
3. The directed burst test missed lengths of 17-255 beats.
4. The checkers found two testbench bugs: a read racing a write to the same
   address, and a 32-bit overflow in an address constraint (`addr + bytes`
   wrapped at 2<sup>32</sup>). The constraint now uses 64-bit arithmetic,
   and every burst is range-checked after randomization.
5. Coincident clock edges add one synchronizer cycle in simulation. RTL
   simulation cannot prove CDC safety; that needs structural CDC checks and
   timing constraints.
6. A seed reproduces a run only while the code that draws random numbers
   is unchanged, so every change is followed by a full regression.

## Usage

Requires Cadence Xcelium with UVM 1.2 (tested with 23.09, `CDNS-1.2`), bash
and Python 3.

```sh
bash sim/regress.sh                                 # full regression -> logs/regress/results.md
bash sim/regress.sh quick                           # about 1 minute
bash sim/run_one.sh rand_ooo_test 3 1 2 +RAND_CLOCKS +VCD   # <test> <seed> [USE_RAM] [LOG_DEPTH] [plusargs]
```

Without a simulator (as in CI):

```sh
python3 tools/test_report.py                        # sign-off rules
python3 tools/axi_addr_model.py                     # address model vs. hand-computed bursts
python3 tools/lint_tb.py --uvm <uvm-core>/src       # slang compile (pip install pyslang)
```

## Repository layout

```
rtl/        vendored PULP RTL and the DUT (sources: rtl/README.md)
tb/uvm/     UVM package: agents, reference model, scoreboard, coverage, sequences, tests
tb/sva/     handshake and CDC assertions
tb/top/     top level: DUT, clocks, binds, fault injection
sim/        regression and single-run scripts
tools/      sign-off, coverage merge, trace comparison, address model, lint, figures
docs/       verification plan, results, figures
```

## Known issue

On Debian 12, Xcelium 23.09 reports `*E,IMPDLL` at start-up: its bundled
linker cannot read the system `libm.so.6` (DT_RELR), so the UVM DPI export
library is not built. The testbench uses no DPI exports and runs normally.

## License

Testbench, scripts and documents: Apache-2.0 ([LICENSE](LICENSE)). RTL in
`rtl/`: SHL-0.51, from the PULP platform; see [rtl/README.md](rtl/README.md).
Parts of the testbench were written with help from Claude (Anthropic).
