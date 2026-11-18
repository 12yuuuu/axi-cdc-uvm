// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Top level of the UVM testbench: clocks, resets, the DUT and the two AXI
// interfaces. The test is chosen with +UVM_TESTNAME.
//
//   source side (src_clk)              destination side (dst_clk)
//   UVM master --- src_if ---> [ DUT: axi_cdc_ram or axi_cdc ] --- dst_if ---> UVM memory slave
//
// Plusargs: +SRC_PERIOD_PS=<n> +DST_PERIOD_PS=<n> +DST_PHASE_PS=<n> +VCD
//           +RAND_CLOCKS       pick both periods (2-30 ns) and the phase from the seed
//           +CLK_CORNERS       with +RAND_CLOCKS: 1 seed in 3 gets a corner case
//                              instead, a simple ratio (1:1, 1:2, 2:3, 1:5, ...)
//                              with rising edges of both clocks at the same time
//           +INJECT_RDATA_ERR  flip bit 0 of R data on the DUT's source-side
//                              output (negative test: the scoreboard must fail)
//           +INJECT_BRESP_ERR  turn every OKAY on the DUT's source-side B output
//                              into SLVERR (negative test: the response check)
//           +INJECT_PTR_GLITCH axi_cdc_ram only: flip two bits of the R FIFO's
//                              gray read pointer for one cycle (negative test:
//                              the CDC assertions must fail)
// Assertions: tb/sva/*.sv, instantiated and bound below (compile with
// +define+NO_SVA to leave them out).
// Parameters (use -defparam): USE_RAM, LOG_DEPTH, SYNC_STAGES

`include "uvm_macros.svh"
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_top;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import axi_tb_cfg_pkg::*;
  import axi_uvm_pkg::*;

  parameter bit          USE_RAM     = 1'b1;  // 1: axi_cdc_ram, 0: axi_cdc
  parameter int unsigned LOG_DEPTH   = 2;
  parameter int unsigned SYNC_STAGES = 2;

  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)

  // ------------------------------------------------------------ clocks/resets
  logic    src_clk   = 1'b0;
  logic    dst_clk   = 1'b0;
  logic    src_rst_n = 1'b0;   // both resets asserted together at time 0
  logic    dst_rst_n = 1'b0;
  realtime src_period = 10ns;
  realtime dst_period = 3ns;
  realtime dst_phase  = 0ns;

  // ---------------------------------------------------------------- interfaces
  axi_vif src_if (.clk(src_clk), .rst_n(src_rst_n));  // UVM master side
  axi_vif dst_if (.clk(dst_clk), .rst_n(dst_rst_n));  // UVM slave side

  axi_req_t  src_req,  dst_req;
  axi_resp_t src_resp, dst_resp;

  // TB-driven signals -> DUT inputs
  `AXI_ASSIGN_TO_REQ(src_req, src_if)
  `AXI_ASSIGN_TO_RESP(dst_resp, dst_if)
  // DUT outputs -> interface (procedural, see axi_vif.sv)
  bit inj_rdata_err = 1'b0, inj_bresp_err = 1'b0;
  initial begin
    if ($test$plusargs("INJECT_RDATA_ERR")) inj_rdata_err = 1'b1;
    if ($test$plusargs("INJECT_BRESP_ERR")) inj_bresp_err = 1'b1;
  end
  always @* begin
    `AXI_SET_FROM_RESP(src_if, src_resp)
    if (inj_rdata_err) src_if.r_data = src_resp.r.data ^ data_t'(1);  // fake DUT bug
    if (inj_bresp_err && src_resp.b.resp == axi_pkg::RESP_OKAY)
      src_if.b_resp = axi_pkg::RESP_SLVERR;                           // fake DUT bug
  end
  always @* begin
    `AXI_SET_FROM_REQ(dst_if, dst_req)
  end

  // ----------------------------------------------------------------------- DUT
  if (USE_RAM) begin : g_dut
    axi_cdc_ram #(
      .aw_chan_t  ( axi_aw_chan_t ),
      .w_chan_t   ( axi_w_chan_t  ),
      .b_chan_t   ( axi_b_chan_t  ),
      .ar_chan_t  ( axi_ar_chan_t ),
      .r_chan_t   ( axi_r_chan_t  ),
      .axi_req_t  ( axi_req_t     ),
      .axi_resp_t ( axi_resp_t    ),
      .LogDepth   ( LOG_DEPTH     ),
      .SyncStages ( SYNC_STAGES   )
    ) i_dut (
      .src_clk_i  ( src_clk   ),
      .src_rst_ni ( src_rst_n ),
      .src_req_i  ( src_req   ),
      .src_resp_o ( src_resp  ),
      .dst_clk_i  ( dst_clk   ),
      .dst_rst_ni ( dst_rst_n ),
      .dst_req_o  ( dst_req   ),
      .dst_resp_i ( dst_resp  )
    );

    // +INJECT_PTR_GLITCH: early in the test, before any read, corrupt the
    // pointer that crosses from src_clk back to dst_clk in the R FIFO. No
    // data is in that FIFO yet, so only the assertions can notice.
    initial if ($test$plusargs("INJECT_PTR_GLITCH")) begin
      logic [LOG_DEPTH:0] bad;
      wait (src_rst_n === 1'b1);
      repeat (5) @(posedge src_clk);
      bad = i_dut.i_cdc_fifo_r.async_rptr ^ 2'b11;
      `uvm_info("INJECT", $sformatf("R FIFO read pointer %b forced to %b for one src_clk cycle",
                                    i_dut.i_cdc_fifo_r.async_rptr, bad), UVM_NONE)
      force i_dut.i_cdc_fifo_r.async_rptr = bad;
      @(posedge src_clk);
      release i_dut.i_cdc_fifo_r.async_rptr;
    end
  end else begin : g_dut
    axi_cdc #(
      .aw_chan_t  ( axi_aw_chan_t ),
      .w_chan_t   ( axi_w_chan_t  ),
      .b_chan_t   ( axi_b_chan_t  ),
      .ar_chan_t  ( axi_ar_chan_t ),
      .r_chan_t   ( axi_r_chan_t  ),
      .axi_req_t  ( axi_req_t     ),
      .axi_resp_t ( axi_resp_t    ),
      .LogDepth   ( LOG_DEPTH     ),
      .SyncStages ( SYNC_STAGES   )
    ) i_dut (
      .src_clk_i  ( src_clk   ),
      .src_rst_ni ( src_rst_n ),
      .src_req_i  ( src_req   ),
      .src_resp_o ( src_resp  ),
      .dst_clk_i  ( dst_clk   ),
      .dst_rst_ni ( dst_rst_n ),
      .dst_req_o  ( dst_req   ),
      .dst_resp_i ( dst_resp  )
    );
  end

  // ---------------------------------------------------------------- assertions
`ifndef NO_SVA
  axi_handshake_sva i_src_sva (.vif(src_if));   // AXI handshake rules, both sides
  axi_handshake_sva i_dst_sva (.vif(dst_if));
  bind cc_cdc_fifo_gray_src_ptr cdc_src_ptr_sva  #(.LogDepth(LogDepth))   u_ptr_sva  (.*);
  bind cc_cdc_fifo_gray_dst_ptr cdc_dst_ptr_sva  #(.LogDepth(LogDepth))   u_ptr_sva  (.*);
  bind cc_cdc_fifo_gray_ram     cdc_ram_fifo_sva #(.LogDepth(LogDepth))   u_fifo_sva (.*);
`endif

  // ------------------------------------------------- clocks, resets, UVM start
  // Clocks, resets and the UVM start are in ONE initial block, so the
  // plusargs are read before anything (including the UVM build phase) uses
  // the clock periods.
  initial begin
    int unsigned v;
    if ($value$plusargs("SRC_PERIOD_PS=%d", v)) src_period = real'(v) * 1ps;
    if ($value$plusargs("DST_PERIOD_PS=%d", v)) dst_period = real'(v) * 1ps;
    if ($value$plusargs("DST_PHASE_PS=%d", v))  dst_phase  = real'(v) * 1ps;
    if ($test$plusargs("RAND_CLOCKS")) begin   // reproducible: depends only on -svseed
      src_period = real'(2 * $urandom_range(15000, 1000)) * 1ps;
      dst_period = real'(2 * $urandom_range(15000, 1000)) * 1ps;
      dst_phase  = real'($urandom_range(int'(dst_period / 1ps) - 1, 0)) * 1ps;
      if ($test$plusargs("CLK_CORNERS") && $urandom_range(2) == 0) begin
        int unsigned rs[7], rd[7], c;
        longint      x, ts, td;
        rs = '{1, 1, 2, 2, 3, 1, 5};   // src : dst period ratio
        rd = '{1, 2, 1, 3, 2, 5, 1};
        c  = $urandom_range(6);
        x  = $urandom_range(3000, 1000);  // half of the base period, in ps
        ts = 2 * x * rs[c];
        td = 2 * x * rd[c];
        src_period = real'(ts) * 1ps;
        dst_period = real'(td) * 1ps;
        // First src rising edge is at ts/2, dst ones at phase + td/2 + k*td:
        // this phase makes the first dst rising edge meet a src rising edge.
        dst_phase  = real'(((ts / 2 - td / 2) % ts + ts) % ts) * 1ps;
      end
    end
    `uvm_info("TB", $sformatf("DUT %s, LOG_DEPTH %0d, src period %0.3f ns, dst period %0.3f ns, dst phase %0.3f ns",
                              USE_RAM ? "axi_cdc_ram" : "axi_cdc", LOG_DEPTH,
                              src_period, dst_period, dst_phase), UVM_NONE)
    uvm_config_db #(virtual axi_vif)::set(null, "uvm_test_top.env.mst*", "vif", src_if);
    uvm_config_db #(virtual axi_vif)::set(null, "uvm_test_top.env.slv*", "vif", dst_if);
    uvm_config_db #(virtual axi_vif)::set(null, "uvm_test_top.env.cov", "src_vif", src_if);
    uvm_config_db #(virtual axi_vif)::set(null, "uvm_test_top.env.cov", "dst_vif", dst_if);
    uvm_config_db #(realtime)::set(null, "uvm_test_top.env.cov", "SRC_PERIOD", src_period);
    uvm_config_db #(realtime)::set(null, "uvm_test_top.env.cov", "DST_PERIOD", dst_period);
    uvm_config_db #(int unsigned)::set(null, "uvm_test_top", "LOG_DEPTH", LOG_DEPTH);
    uvm_config_db #(realtime)::set(null, "uvm_test_top", "SLOW_PERIOD",
                                   (src_period > dst_period) ? src_period : dst_period);
    fork
      forever #(src_period / 2) src_clk = ~src_clk;
      begin
        #(dst_phase);
        forever #(dst_period / 2) dst_clk = ~dst_clk;
      end
      // DUT rule (power-on reset): assert both resets together, release
      // each one synchronously to its own clock.
      begin
        #(20 * ((src_period > dst_period) ? src_period : dst_period));
        fork
          @(posedge src_clk) src_rst_n <= 1'b1;
          @(posedge dst_clk) dst_rst_n <= 1'b1;
        join
      end
    join_none
    run_test();
  end

  // A hang (for example a lost handshake) must fail, not run forever.
  // The longest random runs (slow clocks, 256-beat bursts) take ~5 ms.
  initial begin
    #50ms;
    `uvm_fatal("WATCHDOG", "simulation did not finish within 50 ms")
  end

  // Optional waveform dump: +VCD
  initial begin
    if ($test$plusargs("VCD")) begin
      $dumpfile("waves.vcd");
      $dumpvars(0, tb_top);
    end
  end
endmodule
