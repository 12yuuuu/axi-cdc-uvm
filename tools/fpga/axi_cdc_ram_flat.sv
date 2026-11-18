// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// FPGA top level for the post-fit simulation (sim/postfit.sh): axi_cdc_ram
// with the testbench's AXI widths (32-bit address, 64-bit data, 4-bit ID,
// 1-bit user) and flat vector ports. The Quartus netlist writer accepts only
// single bits and vectors on the top-level ports, not structs; the bit
// layout is the packed layout of the axi_req_t / axi_resp_t structs, so the
// testbench connects its structs with a cast.
`include "axi/typedef.svh"

package axi_flat_pkg;
  typedef logic [31:0] addr_t;
  typedef logic [63:0] data_t;
  typedef logic [3:0]  id_t;
  typedef logic [7:0]  strb_t;
  typedef logic [0:0]  user_t;
  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
  localparam int unsigned ReqW  = $bits(axi_req_t);    // 217
  localparam int unsigned RespW = $bits(axi_resp_t);   // 84
endpackage

module axi_cdc_ram_flat
  import axi_flat_pkg::*;
#(
  parameter int unsigned LogDepth   = 2,
  parameter int unsigned SyncStages = 2
) (
  input  logic             src_clk_i,
  input  logic             src_rst_ni,
  input  logic [ReqW-1:0]  src_req_i,
  output logic [RespW-1:0] src_resp_o,
  input  logic             dst_clk_i,
  input  logic             dst_rst_ni,
  output logic [ReqW-1:0]  dst_req_o,
  input  logic [RespW-1:0] dst_resp_i
);
  axi_req_t  src_req, dst_req;
  axi_resp_t src_resp, dst_resp;
  assign src_req    = axi_req_t'(src_req_i);
  assign dst_resp   = axi_resp_t'(dst_resp_i);
  assign src_resp_o = src_resp;
  assign dst_req_o  = dst_req;

  axi_cdc_ram #(
    .aw_chan_t  ( axi_aw_chan_t ),
    .w_chan_t   ( axi_w_chan_t  ),
    .b_chan_t   ( axi_b_chan_t  ),
    .ar_chan_t  ( axi_ar_chan_t ),
    .r_chan_t   ( axi_r_chan_t  ),
    .axi_req_t  ( axi_req_t     ),
    .axi_resp_t ( axi_resp_t    ),
    .LogDepth   ( LogDepth      ),
    .SyncStages ( SyncStages    )
  ) i_dut (
    .src_clk_i, .src_rst_ni, .src_req_i ( src_req ), .src_resp_o ( src_resp ),
    .dst_clk_i, .dst_rst_ni, .dst_req_o ( dst_req ), .dst_resp_i ( dst_resp )
  );
endmodule
