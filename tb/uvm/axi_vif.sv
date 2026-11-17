// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// AXI4 interface for the UVM components. The signal names are the same as
// pulp-platform's AXI_BUS, so the axi/assign.svh macros can connect it to
// the DUT's req/resp structs.
//
// One interface type is used for both sides. Each side drives its own half:
//   mst_cb - TB as AXI master (drives AW, W, AR, B ready, R ready)
//   slv_cb - TB as AXI slave  (drives AW/W/AR ready, B, R)
//   mon_cb - passive sampling only
// The DUT-driven half is written by `always @*` blocks in tb_top (procedural,
// so it does not clash with the clocking-block outputs of the unused side).
interface axi_vif (input logic clk, input logic rst_n);
  timeunit 1ns;
  timeprecision 1ps;
  import axi_tb_cfg_pkg::*;

  // AW
  id_t              aw_id;
  addr_t            aw_addr;
  axi_pkg::len_t    aw_len;
  axi_pkg::size_t   aw_size;
  axi_pkg::burst_t  aw_burst;
  logic             aw_lock;
  axi_pkg::cache_t  aw_cache;
  axi_pkg::prot_t   aw_prot;
  axi_pkg::qos_t    aw_qos;
  axi_pkg::region_t aw_region;
  axi_pkg::atop_t   aw_atop;
  user_t            aw_user;
  logic             aw_valid;
  logic             aw_ready;
  // W
  data_t            w_data;
  strb_t            w_strb;
  logic             w_last;
  user_t            w_user;
  logic             w_valid;
  logic             w_ready;
  // B
  id_t              b_id;
  axi_pkg::resp_t   b_resp;
  user_t            b_user;
  logic             b_valid;
  logic             b_ready;
  // AR
  id_t              ar_id;
  addr_t            ar_addr;
  axi_pkg::len_t    ar_len;
  axi_pkg::size_t   ar_size;
  axi_pkg::burst_t  ar_burst;
  logic             ar_lock;
  axi_pkg::cache_t  ar_cache;
  axi_pkg::prot_t   ar_prot;
  axi_pkg::qos_t    ar_qos;
  axi_pkg::region_t ar_region;
  user_t            ar_user;
  logic             ar_valid;
  logic             ar_ready;
  // R
  id_t              r_id;
  data_t            r_data;
  axi_pkg::resp_t   r_resp;
  logic             r_last;
  user_t            r_user;
  logic             r_valid;
  logic             r_ready;

  // Inputs are sampled just before the clock edge (#1step); outputs change
  // right after the edge, so the DUT sees them at the next edge (no races).
  clocking mst_cb @(posedge clk);
    default input #1step;
    output aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_lock, aw_cache,
           aw_prot, aw_qos, aw_region, aw_atop, aw_user, aw_valid;
    input  aw_ready;
    output w_data, w_strb, w_last, w_user, w_valid;
    input  w_ready;
    input  b_id, b_resp, b_user, b_valid;
    output b_ready;
    output ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_lock, ar_cache,
           ar_prot, ar_qos, ar_region, ar_user, ar_valid;
    input  ar_ready;
    input  r_id, r_data, r_resp, r_last, r_user, r_valid;
    output r_ready;
  endclocking

  clocking slv_cb @(posedge clk);
    default input #1step;
    input  aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_lock, aw_cache,
           aw_prot, aw_qos, aw_region, aw_atop, aw_user, aw_valid;
    output aw_ready;
    input  w_data, w_strb, w_last, w_user, w_valid;
    output w_ready;
    output b_id, b_resp, b_user, b_valid;
    input  b_ready;
    input  ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_lock, ar_cache,
           ar_prot, ar_qos, ar_region, ar_user, ar_valid;
    output ar_ready;
    output r_id, r_data, r_resp, r_last, r_user, r_valid;
    input  r_ready;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input aw_id, aw_addr, aw_len, aw_size, aw_burst, aw_lock, aw_cache,
          aw_prot, aw_qos, aw_region, aw_atop, aw_user, aw_valid, aw_ready;
    input w_data, w_strb, w_last, w_user, w_valid, w_ready;
    input b_id, b_resp, b_user, b_valid, b_ready;
    input ar_id, ar_addr, ar_len, ar_size, ar_burst, ar_lock, ar_cache,
          ar_prot, ar_qos, ar_region, ar_user, ar_valid, ar_ready;
    input r_id, r_data, r_resp, r_last, r_user, r_valid, r_ready;
  endclocking
endinterface
