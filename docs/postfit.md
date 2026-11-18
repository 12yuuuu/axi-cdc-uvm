# Post-fit simulation and CDC timing

- **Quartus:** Intel Quartus Prime Pro 23.2.0 Build 94
- **Device:** Arria 10 GX 10AX016E3F27E1HG, axi_cdc_ram LogDepth 2
- **Simulator:** Cadence Xcelium 23.09-s006, UVM 1.2 (CDNS-1.2)
- **Host:** EECG ug136 (Debian 12), University of Toronto
- **Date:** 2026-11-17 23:36 EST
- **Wall time:** 5 min 25 s

**Post-fit simulation: PASS**  
**CDC timing constraints: PASS**

## Quartus

```
Device: 10AX016E3F27E1HG (Arria 10 GX), LogDepth 2
Fitter Status : Successful - Tue Nov 17 23:31:25 2026
Logic utilization (in ALMs) : 358 / 61,510 ( < 1 % )
Total registers : 130
Total pins : 2 / 296 ( < 1 % )
Total block memory bits : 1,136 / 9,011,200 ( < 1 % )
Total RAM Blocks : 8 / 440 ( 2 % )
Total DSP Blocks : 0 / 156 ( 0 % )
; 549.15 MHz ; 549.15 MHz      ; src_clk    ;      ; Slow 900mV 100C Model           ;
; 554.32 MHz ; 554.32 MHz      ; dst_clk    ;      ; Slow 900mV 100C Model           ;
```

Netlist top-level ports (`axi_cdc_ram_flat`):

```
input dst_clk_i;
input src_clk_i;
output [83:0] src_resp_o;
output [216:0] dst_req_o;
input [83:0] dst_resp_i;
input [216:0] src_req_i;
input src_rst_ni;
input dst_rst_ni;
cells:
    130 dffeas
      2 twentynm_clkena
    305 twentynm_io_ibuf
    301 twentynm_io_obuf
     81 twentynm_lcell_comb
    284 twentynm_ram_block
```

## Same tests on the RTL and on the post-fit netlist

Each test runs twice with the same seed: once on the RTL `axi_cdc_ram`, once on the Quartus post-fit functional netlist (Arria 10 atoms, zero delay; timing is covered by static timing analysis, not by this simulation). The scoreboard, the reference model and the handshake assertions check both runs; the CDC assertions are bound to RTL modules and do not apply to the netlist.

| Test | Seed | RTL | Netlist | Writes | Reads | Read beats | Same transactions | Same order | Same cycle counts |
|---|---|---|---|---|---|---|---|---|---|
| `backpressure_test` | 1 | PASS | PASS | 200 | 356 | 4983 | yes | yes | yes |
| `burst_test` | 1 | PASS | PASS | 94 | 370 | 5847 | yes | yes | yes |
| `fifo_full_test` | 1 | PASS | PASS | 24 | 152 | 2144 | yes | yes | yes |
| `order_test` | 1 | PASS | PASS | 104 | 264 | 3888 | yes | yes | yes |
| `rand_cov_test` | 1 | PASS | PASS | 221 | 377 | 6915 | yes | yes | yes |
| `rand_cov_test` | 2 | PASS | PASS | 242 | 389 | 5162 | yes | yes | yes |
| `rand_cov_test` | 3 | PASS | PASS | 162 | 351 | 6655 | yes | yes | yes |
| `rand_ooo_test` | 1 | PASS | PASS | 369 | 555 | 9883 | yes | yes | yes |
| `rand_ooo_test` | 2 | PASS | PASS | 317 | 582 | 6721 | yes | yes | yes |
| `rand_ooo_test` | 3 | PASS | PASS | 301 | 587 | 7977 | yes | yes | yes |
| `smoke_test` | 1 | PASS | PASS | 2 | 2 | 5 | yes | yes | yes |

11 of 11 pairs with the same transactions (multiset of trace lines: every request field, 64-bit hashes of data and responses); 11 also in the same order; 11 with identical transaction, beat and stall counts and end time.

## CDC timing constraints

`tools/fpga/constraints.sdc` cuts the two clocks into asynchronous groups and bounds every crossing instead: `set_net_delay` and `set_max_skew` on each gray-pointer bundle, `set_data_delay` on data crossings in fabric registers. `tools/fpga/check_cdc.py` reads the Timing Analyzer reports of every corner and fails unless every bundle and data group is constrained and met, and every path cut by the clock groups is one of them; its self-test plants defects in copies of the same reports and must catch each one.

```
check_cdc: corners ['Slow 900mV 100C Model', 'Slow 900mV 0C Model', 'Fast 900mV 100C Model', 'Fast 900mV 0C Model']; 10 bundles x 3 bits; worst net delay 0.500 ns, worst skew 0.456 ns
  data groups: 1 (data_fallback i_cdc_fifo_b: 28 pairs, worst 2.719 ns); main report data-delay: src_clk +2.719 ns 0 failing
  cut src<->dst paths (corner 0): pointer 30, data-array 0, fabric-fallback 28; counts per corner {('src_clk', 'dst_clk'): 15, ('dst_clk', 'src_clk'): 43}
  Setup Summary at SDC target (informational): src_clk +1.512 ns (0 failing), dst_clk +1.529 ns (0 failing)
  Hold Summary at SDC target (informational): dst_clk +0.024 ns (0 failing), src_clk +0.025 ns (0 failing)
  PASS: every pointer bit and every fabric data crossing is constrained in every corner; nothing cut is unaccounted for
```

Self-test:

```
  caught  data_group_line_missing      FAIL: data-delay corner 'Slow 900mV 100C Model': no coverage line for data_fallback i_dut|i_cdc_fifo_b
  caught  data_delay_failing_endpoint  FAIL: Setup Data Delay Summary src_clk: slack 2.719, 1 failing endpoints
test_check_cdc: 22/22 defects caught
```

