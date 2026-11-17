// Copyright 2026 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Kuan-Yu Liu <ana.liu@mail.utoronto.ca>

`include "axi/assign.svh"
`include "axi/typedef.svh"

/// FPGA-oriented clock domain crossing for AXI4(+ATOPs): same ports and
/// parameters as `axi_cdc`, but each of the five channels is carried by one
/// memory-based `cc_cdc_fifo_gray_ram` instead of a split register-array
/// FIFO. The FIFO storage therefore infers block RAM instead of flip-flops
/// (verified on Intel Arria 10 with Quartus Prime Pro; see pulp-platform/axi
/// #294). Very narrow channels may still be kept in registers by the tool.
///
/// Unlike `axi_cdc`, this module has no `_src`/`_dst` halves: a dual-clock
/// memory must be a single physical block, so the FIFO cannot be cut at the
/// clock boundary. Both clock domains meet inside this module.
///
/// Buffering per channel is 2**LogDepth + 1 entries (`axi_cdc`:
/// 2**LogDepth + 2). Reset requirements are those of `cc_cdc_fifo_gray`:
/// power-on reset only, both resets asserted together, each de-asserted
/// synchronously to its own clock.
module axi_cdc_ram #(
  parameter type aw_chan_t  = logic, // AW Channel Type
  parameter type w_chan_t   = logic, //  W Channel Type
  parameter type b_chan_t   = logic, //  B Channel Type
  parameter type ar_chan_t  = logic, // AR Channel Type
  parameter type r_chan_t   = logic, //  R Channel Type
  parameter type axi_req_t  = logic, // encapsulates request channels
  parameter type axi_resp_t = logic, // encapsulates response channels
  /// Depth of the FIFO crossing the clock domain, given as 2**LogDepth.
  parameter int unsigned  LogDepth   = 1,
  /// Number of synchronization registers to insert on the async pointers
  parameter int unsigned  SyncStages = 2
) (
  // slave side - clocked by `src_clk_i`
  input  logic      src_clk_i,
  input  logic      src_rst_ni,
  input  axi_req_t  src_req_i,
  output axi_resp_t src_resp_o,
  // master side - clocked by `dst_clk_i`
  input  logic      dst_clk_i,
  input  logic      dst_rst_ni,
  output axi_req_t  dst_req_o,
  input  axi_resp_t dst_resp_i
);

  // AW: src -> dst
  cc_cdc_fifo_gray_ram #(
    .data_t     ( aw_chan_t  ),
    .LogDepth   ( LogDepth   ),
    .SyncStages ( SyncStages )
  ) i_cdc_fifo_aw (
    .src_rst_ni,
    .src_clk_i,
    .src_data_i  ( src_req_i.aw        ),
    .src_valid_i ( src_req_i.aw_valid  ),
    .src_ready_o ( src_resp_o.aw_ready ),
    .dst_rst_ni,
    .dst_clk_i,
    .dst_data_o  ( dst_req_o.aw        ),
    .dst_valid_o ( dst_req_o.aw_valid  ),
    .dst_ready_i ( dst_resp_i.aw_ready )
  );

  // W: src -> dst
  cc_cdc_fifo_gray_ram #(
    .data_t     ( w_chan_t   ),
    .LogDepth   ( LogDepth   ),
    .SyncStages ( SyncStages )
  ) i_cdc_fifo_w (
    .src_rst_ni,
    .src_clk_i,
    .src_data_i  ( src_req_i.w        ),
    .src_valid_i ( src_req_i.w_valid  ),
    .src_ready_o ( src_resp_o.w_ready ),
    .dst_rst_ni,
    .dst_clk_i,
    .dst_data_o  ( dst_req_o.w        ),
    .dst_valid_o ( dst_req_o.w_valid  ),
    .dst_ready_i ( dst_resp_i.w_ready )
  );

  // B: dst -> src
  cc_cdc_fifo_gray_ram #(
    .data_t     ( b_chan_t   ),
    .LogDepth   ( LogDepth   ),
    .SyncStages ( SyncStages )
  ) i_cdc_fifo_b (
    .src_rst_ni  ( dst_rst_ni         ),
    .src_clk_i   ( dst_clk_i          ),
    .src_data_i  ( dst_resp_i.b       ),
    .src_valid_i ( dst_resp_i.b_valid ),
    .src_ready_o ( dst_req_o.b_ready  ),
    .dst_rst_ni  ( src_rst_ni         ),
    .dst_clk_i   ( src_clk_i          ),
    .dst_data_o  ( src_resp_o.b       ),
    .dst_valid_o ( src_resp_o.b_valid ),
    .dst_ready_i ( src_req_i.b_ready  )
  );

  // AR: src -> dst
  cc_cdc_fifo_gray_ram #(
    .data_t     ( ar_chan_t  ),
    .LogDepth   ( LogDepth   ),
    .SyncStages ( SyncStages )
  ) i_cdc_fifo_ar (
    .src_rst_ni,
    .src_clk_i,
    .src_data_i  ( src_req_i.ar        ),
    .src_valid_i ( src_req_i.ar_valid  ),
    .src_ready_o ( src_resp_o.ar_ready ),
    .dst_rst_ni,
    .dst_clk_i,
    .dst_data_o  ( dst_req_o.ar        ),
    .dst_valid_o ( dst_req_o.ar_valid  ),
    .dst_ready_i ( dst_resp_i.ar_ready )
  );

  // R: dst -> src
  cc_cdc_fifo_gray_ram #(
    .data_t     ( r_chan_t   ),
    .LogDepth   ( LogDepth   ),
    .SyncStages ( SyncStages )
  ) i_cdc_fifo_r (
    .src_rst_ni  ( dst_rst_ni         ),
    .src_clk_i   ( dst_clk_i          ),
    .src_data_i  ( dst_resp_i.r       ),
    .src_valid_i ( dst_resp_i.r_valid ),
    .src_ready_o ( dst_req_o.r_ready  ),
    .dst_rst_ni  ( src_rst_ni         ),
    .dst_clk_i   ( src_clk_i          ),
    .dst_data_o  ( src_resp_o.r       ),
    .dst_valid_o ( src_resp_o.r_valid ),
    .dst_ready_i ( src_req_i.r_ready  )
  );

endmodule


/// Interface variant of `axi_cdc_ram` (wiring only).
module axi_cdc_ram_intf #(
  parameter int unsigned AXI_ID_WIDTH = 0,
  parameter int unsigned AXI_ADDR_WIDTH = 0,
  parameter int unsigned AXI_DATA_WIDTH = 0,
  parameter int unsigned AXI_USER_WIDTH = 0,
  parameter int unsigned LOG_DEPTH = 1,
  parameter int unsigned SYNC_STAGES = 2
) (
  input  logic      src_clk_i,
  input  logic      src_rst_ni,
  AXI_BUS.Slave     src,
  input  logic      dst_clk_i,
  input  logic      dst_rst_ni,
  AXI_BUS.Master    dst
);

  typedef logic [AXI_ID_WIDTH-1:0]     id_t;
  typedef logic [AXI_ADDR_WIDTH-1:0]   addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   data_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   user_t;
  `AXI_TYPEDEF_AW_CHAN_T(aw_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(w_chan_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(b_chan_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(ar_chan_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(r_chan_t, data_t, id_t, user_t)
  `AXI_TYPEDEF_REQ_T(req_t, aw_chan_t, w_chan_t, ar_chan_t)
  `AXI_TYPEDEF_RESP_T(resp_t, b_chan_t, r_chan_t)

  req_t  src_req,  dst_req;
  resp_t src_resp, dst_resp;

  `AXI_ASSIGN_TO_REQ(src_req, src)
  `AXI_ASSIGN_FROM_RESP(src, src_resp)

  `AXI_ASSIGN_FROM_REQ(dst, dst_req)
  `AXI_ASSIGN_TO_RESP(dst_resp, dst)

  axi_cdc_ram #(
    .aw_chan_t  ( aw_chan_t   ),
    .w_chan_t   ( w_chan_t    ),
    .b_chan_t   ( b_chan_t    ),
    .ar_chan_t  ( ar_chan_t   ),
    .r_chan_t   ( r_chan_t    ),
    .axi_req_t  ( req_t       ),
    .axi_resp_t ( resp_t      ),
    .LogDepth   ( LOG_DEPTH   ),
    .SyncStages ( SYNC_STAGES )
  ) i_axi_cdc_ram (
    .src_clk_i,
    .src_rst_ni,
    .src_req_i  ( src_req  ),
    .src_resp_o ( src_resp ),
    .dst_clk_i,
    .dst_rst_ni,
    .dst_req_o  ( dst_req  ),
    .dst_resp_i ( dst_resp )
  );

endmodule
