# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
#
# Quartus Prime Pro project for the post-fit simulation: axi_cdc_ram_flat
# (axi_cdc_ram with flat ports) on an Arria 10, full compile.
#
#   quartus_sh -t <repo>/tools/fpga/postfit.tcl <repo> <LogDepth> <device>
#
# Run it in an empty build directory (sim/postfit.sh does). Every port except
# the two clocks is a virtual pin, so the I/O count never limits the fit and
# the netlist keeps the ports. Constraints: tools/fpga/constraints.sdc (both
# clocks at 300 MHz as a probe, asynchronous clock groups, net-delay and skew
# bounds on every gray-pointer bundle, data-delay bounds on fabric crossings).
load_package flow

if { $argc < 3 } {
  post_message -type error "usage: quartus_sh -t postfit.tcl <repo> <LogDepth> <device>"
  qexit -error
}
lassign $argv root log_depth device

project_new axi_cdc_postfit -overwrite
set_global_assignment -name FAMILY "Arria 10"
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY axi_cdc_ram_flat
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"
set_global_assignment -name VERILOG_MACRO "COMMON_CELLS_ASSERTS_OFF=1"
set_global_assignment -name VERILOG_MACRO "TARGET_SYNTHESIS=1"
set_global_assignment -name SEARCH_PATH "$root/rtl/axi/include"
set_global_assignment -name SEARCH_PATH "$root/rtl/common_cells/include"
foreach f {
  rtl/tech_cells_generic/src/rtl/tc_sync.sv
  rtl/common_cells/src/cc_binary_to_gray.sv
  rtl/common_cells/src/cc_gray_to_binary.sv
  rtl/common_cells/src/cc_spill_register_flushable.sv
  rtl/common_cells/src/cc_spill_register.sv
  rtl/common_cells/src/cc_cdc_fifo_gray.sv
  rtl/dut/cc_cdc_fifo_gray_ram.sv
  rtl/axi/src/axi_pkg.sv
  rtl/dut/axi_cdc_ram.sv
  tools/fpga/axi_cdc_ram_flat.sv
} {
  set_global_assignment -name SYSTEMVERILOG_FILE "$root/$f"
}
set_global_assignment -name SDC_FILE "$root/tools/fpga/constraints.sdc"
set_parameter -name LogDepth $log_depth

set_instance_assignment -name VIRTUAL_PIN ON  -to *
set_instance_assignment -name VIRTUAL_PIN OFF -to src_clk_i
set_instance_assignment -name VIRTUAL_PIN OFF -to dst_clk_i

execute_flow -compile
project_close
qexit -success
