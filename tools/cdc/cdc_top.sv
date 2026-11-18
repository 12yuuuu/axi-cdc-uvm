// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Top level for the structural CDC check (tools/cdc_check.py): the DUT with
// the testbench's AXI widths (32-bit address, 64-bit data, 4-bit ID, 1-bit
// user) and plain ports, so the netlist has exactly two clock inputs.
`include "axi/typedef.svh"

package cdc_top_pkg;
  typedef logic [31:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [3:0]  id_t;
  typedef logic [7:0]  strb_t;
  typedef logic [0:0]  user_t;
  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
endpackage

module cdc_top
  import cdc_top_pkg::*;
#(
  parameter bit          UseRam     = 1'b1,   // 1: axi_cdc_ram, 0: axi_cdc
  parameter int unsigned LogDepth   = 2,
  parameter int unsigned SyncStages = 2
) (
  input  logic      src_clk_i,
  input  logic      src_rst_ni,
  input  axi_req_t  src_req_i,
  output axi_resp_t src_resp_o,
  input  logic      dst_clk_i,
  input  logic      dst_rst_ni,
  output axi_req_t  dst_req_o,
  input  axi_resp_t dst_resp_i
);
  if (UseRam) begin : g_dut
    axi_cdc_ram #(
      .aw_chan_t (axi_aw_chan_t), .w_chan_t (axi_w_chan_t), .b_chan_t (axi_b_chan_t),
      .ar_chan_t (axi_ar_chan_t), .r_chan_t (axi_r_chan_t),
      .axi_req_t (axi_req_t), .axi_resp_t (axi_resp_t),
      .LogDepth (LogDepth), .SyncStages (SyncStages)
    ) i_dut (.*);
  end else begin : g_dut
    axi_cdc #(
      .aw_chan_t (axi_aw_chan_t), .w_chan_t (axi_w_chan_t), .b_chan_t (axi_b_chan_t),
      .ar_chan_t (axi_ar_chan_t), .r_chan_t (axi_r_chan_t),
      .axi_req_t (axi_req_t), .axi_resp_t (axi_resp_t),
      .LogDepth (LogDepth), .SyncStages (SyncStages)
    ) i_dut (.*);
  end
endmodule
