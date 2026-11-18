// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// AXI4 handshake rules, checked on one AXI interface (AXI spec A3.1.2,
// A3.2.1). tb_top has one instance on each axi_vif, so both sides of the
// DUT are checked: on the source side the DUT drives B and R, on the
// destination side it drives AW, W and AR; the testbench drives the rest.
//
// Per channel:
//   VALID   once VALID is high it stays high until READY
//   STABLE  while VALID=1 and READY=0 the payload does not change
//   X       no X/Z on VALID and READY after reset, none on the payload
//           while VALID is high
//   RESET   VALID is low in the first cycle after reset
//
// The scoreboard cannot see a STABLE violation: the DUT and both monitors
// all take the payload at the handshake, so they agree with each other.
// Only these assertions catch it (negative test: +INJECT_AW_UNSTABLE).
`include "uvm_macros.svh"

module axi_handshake_sva
  import uvm_pkg::*;
(
  axi_vif vif
);
  default clocking cb @(posedge vif.clk); endclocking
  default disable iff (!vif.rst_n);

  // ---- AW
  a_aw_valid : assert property (vif.aw_valid && !vif.aw_ready |=> vif.aw_valid)
    else `uvm_error("SVA_AW", $sformatf("%m: VALID dropped before READY"))
  a_aw_stable: assert property (vif.aw_valid && !vif.aw_ready |=> $stable({vif.aw_id, vif.aw_addr, vif.aw_len, vif.aw_size, vif.aw_burst, vif.aw_lock, vif.aw_cache,
                                      vif.aw_prot, vif.aw_qos, vif.aw_region, vif.aw_atop, vif.aw_user}))
    else `uvm_error("SVA_AW", $sformatf("%m: payload changed while VALID=1, READY=0 (addr now %h)", $sampled(vif.aw_addr)))
  a_aw_x     : assert property (!$isunknown({vif.aw_valid, vif.aw_ready}) &&
                                (!vif.aw_valid || !$isunknown({vif.aw_id, vif.aw_addr, vif.aw_len, vif.aw_size, vif.aw_burst, vif.aw_lock, vif.aw_cache,
                                      vif.aw_prot, vif.aw_qos, vif.aw_region, vif.aw_atop, vif.aw_user})))
    else `uvm_error("SVA_AW", $sformatf("%m: X on VALID/READY or on the payload"))
  a_aw_reset : assert property (disable iff (1'b0) $rose(vif.rst_n) |-> !vif.aw_valid)
    else `uvm_error("SVA_AW", $sformatf("%m: VALID high in the first cycle after reset"))

  // ---- W
  a_w_valid  : assert property (vif.w_valid && !vif.w_ready |=> vif.w_valid)
    else `uvm_error("SVA_W", $sformatf("%m: VALID dropped before READY"))
  a_w_stable : assert property (vif.w_valid && !vif.w_ready |=> $stable({vif.w_data, vif.w_strb, vif.w_last, vif.w_user}))
    else `uvm_error("SVA_W", $sformatf("%m: payload changed while VALID=1, READY=0"))
  a_w_x      : assert property (!$isunknown({vif.w_valid, vif.w_ready}) &&
                                (!vif.w_valid || !$isunknown({vif.w_data, vif.w_strb, vif.w_last, vif.w_user})))
    else `uvm_error("SVA_W", $sformatf("%m: X on VALID/READY or on the payload"))
  a_w_reset  : assert property (disable iff (1'b0) $rose(vif.rst_n) |-> !vif.w_valid)
    else `uvm_error("SVA_W", $sformatf("%m: VALID high in the first cycle after reset"))

  // ---- B
  a_b_valid  : assert property (vif.b_valid && !vif.b_ready |=> vif.b_valid)
    else `uvm_error("SVA_B", $sformatf("%m: VALID dropped before READY"))
  a_b_stable : assert property (vif.b_valid && !vif.b_ready |=> $stable({vif.b_id, vif.b_resp, vif.b_user}))
    else `uvm_error("SVA_B", $sformatf("%m: payload changed while VALID=1, READY=0"))
  a_b_x      : assert property (!$isunknown({vif.b_valid, vif.b_ready}) &&
                                (!vif.b_valid || !$isunknown({vif.b_id, vif.b_resp, vif.b_user})))
    else `uvm_error("SVA_B", $sformatf("%m: X on VALID/READY or on the payload"))
  a_b_reset  : assert property (disable iff (1'b0) $rose(vif.rst_n) |-> !vif.b_valid)
    else `uvm_error("SVA_B", $sformatf("%m: VALID high in the first cycle after reset"))

  // ---- AR
  a_ar_valid : assert property (vif.ar_valid && !vif.ar_ready |=> vif.ar_valid)
    else `uvm_error("SVA_AR", $sformatf("%m: VALID dropped before READY"))
  a_ar_stable: assert property (vif.ar_valid && !vif.ar_ready |=> $stable({vif.ar_id, vif.ar_addr, vif.ar_len, vif.ar_size, vif.ar_burst, vif.ar_lock, vif.ar_cache,
                                      vif.ar_prot, vif.ar_qos, vif.ar_region, vif.ar_user}))
    else `uvm_error("SVA_AR", $sformatf("%m: payload changed while VALID=1, READY=0"))
  a_ar_x     : assert property (!$isunknown({vif.ar_valid, vif.ar_ready}) &&
                                (!vif.ar_valid || !$isunknown({vif.ar_id, vif.ar_addr, vif.ar_len, vif.ar_size, vif.ar_burst, vif.ar_lock, vif.ar_cache,
                                      vif.ar_prot, vif.ar_qos, vif.ar_region, vif.ar_user})))
    else `uvm_error("SVA_AR", $sformatf("%m: X on VALID/READY or on the payload"))
  a_ar_reset : assert property (disable iff (1'b0) $rose(vif.rst_n) |-> !vif.ar_valid)
    else `uvm_error("SVA_AR", $sformatf("%m: VALID high in the first cycle after reset"))

  // ---- R
  a_r_valid  : assert property (vif.r_valid && !vif.r_ready |=> vif.r_valid)
    else `uvm_error("SVA_R", $sformatf("%m: VALID dropped before READY"))
  a_r_stable : assert property (vif.r_valid && !vif.r_ready |=> $stable({vif.r_id, vif.r_data, vif.r_resp, vif.r_last, vif.r_user}))
    else `uvm_error("SVA_R", $sformatf("%m: payload changed while VALID=1, READY=0"))
  a_r_x      : assert property (!$isunknown({vif.r_valid, vif.r_ready}) &&
                                (!vif.r_valid || !$isunknown({vif.r_id, vif.r_data, vif.r_resp, vif.r_last, vif.r_user})))
    else `uvm_error("SVA_R", $sformatf("%m: X on VALID/READY or on the payload"))
  a_r_reset  : assert property (disable iff (1'b0) $rose(vif.rst_n) |-> !vif.r_valid)
    else `uvm_error("SVA_R", $sformatf("%m: VALID high in the first cycle after reset"))
endmodule
