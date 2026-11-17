// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Environment:
//   mst      master agent on the source side (sequencer, driver, monitor)
//   slv      memory slave on the destination side
//   slv_mon  monitor on the destination side
//   sb       scoreboard: compares what the two monitors saw
//   cov      functional coverage (transactions from mst.mon, DUT events
//            from both interfaces)
class axi_env extends uvm_env;
  `uvm_component_utils(axi_env)

  axi_master_agent mst;
  axi_slave_mem    slv;
  axi_monitor      slv_mon;
  axi_scoreboard   sb;
  axi_coverage     cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    mst     = axi_master_agent::type_id::create("mst", this);
    slv     = axi_slave_mem::type_id::create("slv", this);
    slv_mon = axi_monitor::type_id::create("slv_mon", this);
    sb      = axi_scoreboard::type_id::create("sb", this);
    cov     = axi_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    mst.mon.ap.connect(sb.src_imp);
    mst.mon.ap.connect(cov.analysis_export);
    slv_mon.ap.connect(sb.dst_imp);
  endfunction

  // The coverage collector and the monitors count FIFO-full cycles on
  // their own; the numbers must agree.
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (cov.n_full[CH_AW] != mst.mon.stall_aw || cov.n_full[CH_W] != mst.mon.stall_w ||
        cov.n_full[CH_AR] != mst.mon.stall_ar || cov.n_full[CH_B] != slv_mon.stall_b ||
        cov.n_full[CH_R]  != slv_mon.stall_r)
      `uvm_error("COVCHK", $sformatf("full cycles: coverage AW/W/AR/B/R %0d/%0d/%0d/%0d/%0d, monitors %0d/%0d/%0d/%0d/%0d",
                 cov.n_full[CH_AW], cov.n_full[CH_W], cov.n_full[CH_AR], cov.n_full[CH_B], cov.n_full[CH_R],
                 mst.mon.stall_aw, mst.mon.stall_w, mst.mon.stall_ar, slv_mon.stall_b, slv_mon.stall_r))
  endfunction
endclass
