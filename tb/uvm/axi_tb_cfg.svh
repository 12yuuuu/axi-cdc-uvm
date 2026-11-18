// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Address map of the slave memory. With cfg.err_en set, two 4 KiB pages of
// region E answer with error responses (bursts never cross 4 KiB, so a
// whole burst is either in an error page or not):
//   ERR_SLV_PAGE  SLVERR: writes are dropped, reads return data 0
//   ERR_DEC_PAGE  DECERR: same, with DECERR
localparam addr_t REGION_E     = 32'h0004_0000;
localparam addr_t ERR_SLV_PAGE = REGION_E + 32'h1000;
localparam addr_t ERR_DEC_PAGE = REGION_E + 32'h2000;

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
  // Response order (AXI A5.3: only same-ID responses must stay in order).
  // All 0 = in order, the behaviour of every test before rand_ooo_test.
  int unsigned slv_b_ooo_pct    = 0;   // chance (%) that the next B is a random eligible one
  int unsigned slv_b_gather     = 0;   // with one B ready, wait up to this many cycles for a
                                       // second one, so that there is a choice to reorder
  int unsigned slv_r_ilv_pct    = 0;   // chance (%) per R beat to switch to another read burst
  int unsigned slv_r_active     = 1;   // read bursts returned at the same time (1..4)
  bit          err_en           = 1'b0;// 1: error pages answer SLVERR / DECERR

  function new(string name = "axi_tb_cfg");
    super.new(name);
  endfunction

  static function bit chance(int unsigned pct);
    return ($urandom_range(99) < pct);
  endfunction

  static function int unsigned rand_upto(int unsigned max);
    return (max == 0) ? 0 : $urandom_range(max);
  endfunction

  // Response the slave owes for a burst that starts at `a` (the address map
  // above). The reference model asks the same map: it is the slave's spec.
  function axi_pkg::resp_t resp_for(addr_t a);
    if (!err_en) return axi_pkg::RESP_OKAY;
    if ((a & ~addr_t'('hfff)) == ERR_SLV_PAGE) return axi_pkg::RESP_SLVERR;
    if ((a & ~addr_t'('hfff)) == ERR_DEC_PAGE) return axi_pkg::RESP_DECERR;
    return axi_pkg::RESP_OKAY;
  endfunction
endclass
