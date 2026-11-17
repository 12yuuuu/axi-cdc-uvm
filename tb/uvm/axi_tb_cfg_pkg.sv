// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// AXI widths used by the testbench. Same as the FPGA comparison in #294:
// 32-bit address, 64-bit data, 4-bit ID, 1-bit user.
package axi_tb_cfg_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  localparam int unsigned AW = 32;      // address bits
  localparam int unsigned DW = 64;      // data bits
  localparam int unsigned IW = 4;       // ID bits
  localparam int unsigned UW = 1;       // user bits
  localparam int unsigned SW = DW / 8;  // strobe bits = bytes per beat
  localparam int unsigned CW = (DW > AW) ? DW : AW;  // widest field, for compares

  typedef logic [AW-1:0] addr_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [SW-1:0] strb_t;
  typedef logic [UW-1:0] user_t;
endpackage
