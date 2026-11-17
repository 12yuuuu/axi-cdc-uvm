// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Run-time knobs shared by the driver, the slave memory and the tests.
// A test may change them while the simulation runs (e.g. hold the slave's
// ready signals low to fill the DUT's FIFOs, then release them).
class axi_tb_cfg extends uvm_object;
  `uvm_object_utils(axi_tb_cfg)

  // ---- master (source side)
  int unsigned max_outstanding = 16;   // writes and reads, each
  int unsigned mst_b_ready_pct = 100;  // chance (%) per cycle that B ready is high
  int unsigned mst_r_ready_pct = 100;  // same for R ready
  bit          mst_rsp_hold    = 1'b0; // 1: B ready and R ready forced low

  // ---- slave memory (destination side)
  int unsigned slv_aw_ready_pct = 100;
  int unsigned slv_w_ready_pct  = 100;
  int unsigned slv_ar_ready_pct = 100;
  int unsigned slv_b_delay_max  = 0;   // idle cycles before each B, random 0..max
  int unsigned slv_r_gap_max    = 0;   // idle cycles before each R beat, random 0..max
  bit          slv_req_hold     = 1'b0;// 1: AW, W and AR ready forced low

  function new(string name = "axi_tb_cfg");
    super.new(name);
  endfunction

  static function bit chance(int unsigned pct);
    return ($urandom_range(99) < pct);
  endfunction

  static function int unsigned rand_upto(int unsigned max);
    return (max == 0) ? 0 : $urandom_range(max);
  endfunction
endclass
