# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# From the pulp-platform/axi#294 FPGA study (same author), used unchanged here
# except for paths.
# Timing constraints for the axi_cdc / cc_cdc_fifo_gray(_ram) characterization.
#
# Two independent clock domains. The target period is deliberately
# aggressive (300 MHz) so the Fitter works hard; read the achieved Fmax from
# the "Fmax Summary" in the Timing Analyzer report, not from whether this
# constraint is met.

set T_src 3.333
set T_dst 3.333
# Optional override for frequency-target experiments: AXI294_PERIOD_NS=2.0
if { [info exists ::env(AXI294_PERIOD_NS)] } {
  set T_src $::env(AXI294_PERIOD_NS)
  set T_dst $::env(AXI294_PERIOD_NS)
}
create_clock -name src_clk -period $T_src [get_ports src_clk_i]
create_clock -name dst_clk -period $T_dst [get_ports dst_clk_i]

# Resets are quasi-static for this experiment.
set_false_path -from [get_ports {src_rst_ni dst_rst_ni}]

# ---------------------------------------------------------------------------
# Clock domain crossing
# ---------------------------------------------------------------------------
# The two domains are asynchronous: cut all setup/hold analysis between them.
# set_clock_groups has false-path priority and overrides set_max_delay on
# the same paths; the crossings below are therefore constrained with
# set_net_delay / set_max_skew / set_data_delay, which are independent of
# clock-group cuts. Every path cut by the clock groups is listed by
# sta_extra.tcl (report_timing -false_path) and must be one of the
# constrained kinds below; check_cdc.py fails the build otherwise.
set_clock_groups -asynchronous -group {src_clk} -group {dst_clk}

set T_min [expr {min($T_src, $T_dst)}]

# ---------------------------------------------------------------------------
# Gray-pointer crossings, one bundle per FIFO and direction.
#
# Every FIFO (joined cc_cdc_fifo_gray_ram, or the two halves of the split
# cc_cdc_fifo_gray) has a write-pointer register bank `<P>|i_src_ptr|wptr_q*`
# whose bits land in `<Q>|i_dst_ptr|gen_sync[i].i_sync|reg_q[0]`, and a
# read-pointer bank `<Q>|i_dst_ptr|rptr_q*` landing in
# `<P>|i_src_ptr|gen_sync[i].i_sync|reg_q[0]`. For the joined FIFO P == Q;
# for the split original Q is P with src<->dst swapped in the path (the AW/W/
# AR src halves live under i_axi_cdc_src, their dst halves under
# i_axi_cdc_dst; B/R the other way round). Constraining per bundle keeps the
# skew check inside one pointer instead of across unrelated FIFOs, and lets
# the report show every bundle separately.
# ---------------------------------------------------------------------------
proc axi294_swap_src_dst { path } {
  # single-pass map: src->dst and dst->src simultaneously (string map does
  # not rescan replaced text)
  set out {}
  foreach seg [split $path "|"] { lappend out [string map {src dst dst src} $seg] }
  return [join $out "|"]
}

set parents {}
if { [catch {
  set src_ptr_regs [get_registers -nowarn {*|i_src_ptr|wptr_q*}]
  foreach_in_collection r $src_ptr_regs {
    set n [get_register_info $r -name]
    set p [string range $n 0 [expr {[string first "|i_src_ptr|" $n] - 1}]]
    if { [lsearch -exact $parents $p] < 0 } { lappend parents $p }
  }
} msg] } {
  post_message -type warning "axi294: per-FIFO discovery failed ($msg); falling back to global patterns"
  set parents {}
}
if { [llength $parents] == 0 } {
  # Fallback: one bundle per direction over all FIFOs (over-constrains skew
  # across FIFOs; still bounds every bit). Reported as such by check_cdc.py.
  set_net_delay -from [get_registers {*|i_src_ptr|wptr_q*}] -to [get_registers {*|i_dst_ptr|gen_sync[*].i_sync|reg_q[0]}] -max $T_min
  set_max_skew  -from [get_registers {*|i_src_ptr|wptr_q*}] -to [get_registers {*|i_dst_ptr|gen_sync[*].i_sync|reg_q[0]}] $T_min
  set_net_delay -from [get_registers {*|i_dst_ptr|rptr_q*}] -to [get_registers {*|i_src_ptr|gen_sync[*].i_sync|reg_q[0]}] -max $T_min
  set_max_skew  -from [get_registers {*|i_dst_ptr|rptr_q*}] -to [get_registers {*|i_src_ptr|gen_sync[*].i_sync|reg_q[0]}] $T_min
}
set axi294_bundles 0
set axi294_dd_orig 0
set axi294_dd_fallback 0
foreach P $parents {
  set Q [axi294_swap_src_dst $P]
  # escape [ ] for the pattern (double quotes would otherwise run command substitution)
  set w_from [get_registers -nowarn "${P}|i_src_ptr|wptr_q*"]
  set w_to   [get_registers -nowarn "${Q}|i_dst_ptr|gen_sync\[*\].i_sync|reg_q\[0\]"]
  set r_from [get_registers -nowarn "${Q}|i_dst_ptr|rptr_q*"]
  set r_to   [get_registers -nowarn "${P}|i_src_ptr|gen_sync\[*\].i_sync|reg_q\[0\]"]
  if { [get_collection_size $w_from] > 0 && [get_collection_size $w_to] > 0 } {
    set_net_delay -from $w_from -to $w_to -max $T_min
    set_max_skew  -from $w_from -to $w_to $T_min
    incr axi294_bundles
  }
  if { [get_collection_size $r_from] > 0 && [get_collection_size $r_to] > 0 } {
    set_net_delay -from $r_from -to $r_to -max $T_min
    set_max_skew  -from $r_from -to $r_to $T_min
    incr axi294_bundles
  }
  # ---- fabric data crossings: bounded with set_data_delay (independent of the
  #      clock-group cut). Two kinds exist:
  # (a) Original implementation: the data array crosses the boundary through
  #     the read multiplexer (data_q -> mux -> spill register a_data_q).
  set d_from [get_registers -nowarn "${P}|i_src_data|data_q*"]
  set d_to   [get_registers -nowarn "${Q}|i_dst_data|*a_data_q*"]
  if { [get_collection_size $d_from] > 0 && [get_collection_size $d_to] > 0 } {
    # Quartus Pro syntax: the delay is positional (no -max)
    if { [catch { set_data_delay -from $d_from -to $d_to $T_min } msg] } {
      post_message -type error "set_data_delay failed: $msg"
    } else { incr axi294_dd_orig }
  }
  # (b) Memory-based implementation whose array the Fitter kept in fabric
  #     registers instead of a RAM block (it declines RAM inference for very
  #     small arrays, e.g. the 4 x 7-bit B channel at LogDepth 2). Then
  #     mem[*][*] (write clock) -> read mux -> rdata_q (read clock) is a
  #     fabric data crossing exactly like (a) and gets the same bound. When
  #     the array is in a RAM block there are no such registers and no
  #     fabric crossing (the read is a synchronous RAM port); sta_extra.tcl
  #     lists every cut src<->dst path so that nothing is silently exempt.
  set m_from [get_registers -nowarn "${P}|mem\[*\]\[*\]"]
  set m_to   [get_registers -nowarn "${P}|rdata_q*"]
  if { [get_collection_size $m_from] > 0 && [get_collection_size $m_to] > 0 } {
    if { [catch { set_data_delay -from $m_from -to $m_to $T_min } msg] } {
      post_message -type error "set_data_delay (fabric fallback) failed: $msg"
    } else { incr axi294_dd_fallback }
  }
}
post_message -type info "axi294: constrained $axi294_bundles gray-pointer bundle(s) across [llength $parents] FIFO(s); set_data_delay on $axi294_dd_orig data-array group(s) and $axi294_dd_fallback fabric-fallback group(s)"
