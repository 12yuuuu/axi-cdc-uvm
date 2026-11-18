// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// UVM classes for the axi_cdc / axi_cdc_ram testbench.
`include "uvm_macros.svh"

package axi_uvm_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import axi_tb_cfg_pkg::*;

  `include "axi_tb_cfg.svh"
  `include "axi_seq_item.svh"
  `include "axi_master_driver.svh"
  `include "axi_monitor.svh"
  `include "axi_master_agent.svh"
  `include "axi_slave_mem.svh"
  `include "axi_ref_model.svh"
  `include "axi_scoreboard.svh"
  `include "axi_coverage.svh"
  `include "axi_env.svh"
  `include "axi_seqs.svh"
  `include "axi_tests.svh"
endpackage
