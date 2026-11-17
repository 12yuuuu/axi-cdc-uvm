// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// White-box assertions for the gray-pointer CDC FIFOs. tb_top binds them
// into the RTL (no RTL change):
//
//   cdc_src_ptr_sva  -> every cc_cdc_fifo_gray_src_ptr (both DUTs, 5 per DUT)
//   cdc_dst_ptr_sva  -> every cc_cdc_fifo_gray_dst_ptr (both DUTs, 5 per DUT)
//   cdc_ram_fifo_sva -> every cc_cdc_fifo_gray_ram     (axi_cdc_ram only)
//
// Rules:
//   GRAY  a pointer that crosses to the other clock changes at most one bit
//         per clock: the synchronizer can then only see the old or the new
//         value, never a mix
//   MOVE  a pointer moves exactly when its side has a handshake
//   OCC   occupancy (write pointer - read pointer) stays within 0..2**LogDepth:
//         no overflow, no underflow. Checked on each side with that side's
//         (delayed) copy of the other pointer, and, for the RAM FIFO, on
//         the real pointers at every edge of either clock.
//
// Negative test: +INJECT_PTR_GLITCH in tb_top flips two bits of one
// crossing pointer for one cycle; GRAY and OCC must fire.
`include "uvm_macros.svh"

module cdc_src_ptr_sva
  import uvm_pkg::*;
#(
  parameter int unsigned LogDepth = 3
)(
  input logic                src_clk_i,
  input logic                src_rst_ni,
  input logic                src_valid_i,
  input logic                src_ready_o,
  input logic [LogDepth:0]   async_wptr_o,
  input logic [LogDepth:0]   wptr_bin,
  input logic [LogDepth:0]   rptr_bin
);
  default clocking cb @(posedge src_clk_i); endclocking
  default disable iff (!src_rst_ni);

  a_gray: assert property ($countones(async_wptr_o ^ $past(async_wptr_o)) <= 1)
    else `uvm_error("SVA_GRAY", $sformatf("%m: write pointer changed more than one bit (now %b)", async_wptr_o))
  a_move: assert property ((async_wptr_o != $past(async_wptr_o)) == $past(src_valid_i && src_ready_o))
    else `uvm_error("SVA_MOVE", $sformatf("%m: write pointer moved without a write, or a write did not move it"))
  a_occ : assert property ((LogDepth + 1)'(wptr_bin - rptr_bin) <= (1 << LogDepth))
    else `uvm_error("SVA_OCC", $sformatf("%m: write side sees %0d entries (max %0d)",
                                         (LogDepth + 1)'(wptr_bin - rptr_bin), 1 << LogDepth))
endmodule

module cdc_dst_ptr_sva
  import uvm_pkg::*;
#(
  parameter int unsigned LogDepth = 3
)(
  input logic                dst_clk_i,
  input logic                dst_rst_ni,
  input logic                dst_valid_o,
  input logic                dst_ready_i,
  input logic [LogDepth:0]   async_rptr_o,
  input logic [LogDepth:0]   wptr_bin,
  input logic [LogDepth:0]   rptr_bin
);
  default clocking cb @(posedge dst_clk_i); endclocking
  default disable iff (!dst_rst_ni);

  a_gray: assert property ($countones(async_rptr_o ^ $past(async_rptr_o)) <= 1)
    else `uvm_error("SVA_GRAY", $sformatf("%m: read pointer changed more than one bit (now %b)", async_rptr_o))
  a_move: assert property ((async_rptr_o != $past(async_rptr_o)) == $past(dst_valid_o && dst_ready_i))
    else `uvm_error("SVA_MOVE", $sformatf("%m: read pointer moved without a read, or a read did not move it"))
  a_occ : assert property ((LogDepth + 1)'(wptr_bin - rptr_bin) <= (1 << LogDepth))
    else `uvm_error("SVA_OCC", $sformatf("%m: read side sees %0d entries (max %0d)",
                                         (LogDepth + 1)'(wptr_bin - rptr_bin), 1 << LogDepth))
endmodule

module cdc_ram_fifo_sva
  import uvm_pkg::*;
#(
  parameter int unsigned LogDepth = 3
)(
  input logic                src_clk_i,
  input logic                src_rst_ni,
  input logic                dst_clk_i,
  input logic                dst_rst_ni,
  input logic [LogDepth:0]   async_wptr,
  input logic [LogDepth:0]   async_rptr
);
  function automatic logic [LogDepth:0] g2b(logic [LogDepth:0] g);
    logic [LogDepth:0] b;
    b[LogDepth] = g[LogDepth];
    for (int i = LogDepth - 1; i >= 0; i--) b[i] = b[i + 1] ^ g[i];
    return b;
  endfunction

  // The pointers on the nets that cross the clock boundary.
  a_gray_w: assert property (@(posedge src_clk_i) disable iff (!src_rst_ni)
                             $countones(async_wptr ^ $past(async_wptr)) <= 1)
    else `uvm_error("SVA_GRAY", $sformatf("%m: crossing write pointer changed more than one bit (now %b)", async_wptr))
  a_gray_r: assert property (@(posedge dst_clk_i) disable iff (!dst_rst_ni)
                             $countones(async_rptr ^ $past(async_rptr)) <= 1)
    else `uvm_error("SVA_GRAY", $sformatf("%m: crossing read pointer changed more than one bit (now %b)", async_rptr))
  // Real occupancy, at every edge of either clock.
  a_occ   : assert property (@(posedge src_clk_i or posedge dst_clk_i) disable iff (!src_rst_ni || !dst_rst_ni)
                             (LogDepth + 1)'(g2b(async_wptr) - g2b(async_rptr)) <= (1 << LogDepth))
    else `uvm_error("SVA_OCC", $sformatf("%m: FIFO holds %0d entries (max %0d)",
                                         (LogDepth + 1)'(g2b(async_wptr) - g2b(async_rptr)), 1 << LogDepth))
endmodule
