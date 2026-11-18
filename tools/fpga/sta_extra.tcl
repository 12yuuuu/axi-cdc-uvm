# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# From the pulp-platform/axi#294 FPGA study (same author), used unchanged here
# except for paths.
# Extra Timing Analyzer reports proving the CDC constraints hit real nodes.
#
# Usage (from the build directory of a compiled project):
#   quartus_sta -t <repo>/tools/fpga/sta_extra.tcl <project_name>
# Writes output_files/sta_extra_*.rpt (kept by prune_build). Any failure
# makes quartus_sta exit non-zero (caught by sim/postfit.sh).
#
# Reports (every multi-corner report carries "axi294_corner: <name>" marker
# lines, so check_cdc.py never has to guess which block is which corner):
#   sta_extra_sdc.rpt           SDC as parsed, every constraint with its collections
#   sta_extra_groups.rpt        CDC groups discovered from the netlist (independent
#                               of the SDC): pointer bundles per FIFO, original
#                               data arrays, fabric-fallback arrays, with register counts
#   sta_extra_net_delay.rpt     set_net_delay: every constrained net, all corners
#   sta_extra_max_skew.rpt      set_max_skew per bundle, all corners
#   sta_extra_data_delay.rpt    set_data_delay paths (report_timing -data_delay), all
#                               corners: worst paths overall + per group, with
#                               "axi294_group: <kind> <P> pairs=<n> worst=<slack>" lines
#   sta_extra_cut_paths.rpt     every src<->dst path cut by the clock groups
#                               (report_timing -false_path): corner 0 full listing
#                               (-pairs_only), every corner the count. check_cdc.py
#                               classifies each one as pointer / data-array /
#                               fabric-fallback and fails on anything else.
#   sta_extra_metastability.rpt synchronizer chains identified
#   sta_extra_dst_out.rpt       worst setup paths into the dst-side output stage
#   sta_extra_hold.rpt          worst hold paths per clock
#   sta_extra_cross.rpt         src->dst / dst->src regular paths: must be empty
#   sta_extra_ucp.rpt           unconstrained paths summary

if { $argc < 1 } { post_message -type error "usage: quartus_sta -t sta_extra.tcl <project>"; qexit -error }
set proj [lindex $argv 0]
project_open $proj
create_timing_netlist -model slow
read_sdc
update_timing_netlist

set od output_files
foreach r {sta_extra_net_delay.rpt sta_extra_max_skew.rpt sta_extra_data_delay.rpt sta_extra_cut_paths.rpt sta_extra_groups.rpt} {
  file delete -force $od/$r
}
report_sdc -file $od/sta_extra_sdc.rpt

proc axi294_mark { file text } { set fh [open $file a]; puts $fh $text; close $fh }

# report_timing returns {npaths worst_slack}; this runs it with -npaths 0 (all
# paths) into a scratch file and returns just the pair, so counts never depend
# on a report-size limit.
proc axi294_count { args } {
  global od
  set tmp $od/axi294_scratch.rpt
  set res {}
  if { [catch { set res [eval report_timing $args -npaths 0 -pairs_only -detail summary -file $tmp] } msg] } {
    post_message -type warning "axi294_count: report_timing $args failed: $msg"
    set res {}
  }
  file delete -force $tmp
  set n [lindex $res 0]; set w [lindex $res 1]
  if { $n eq "" || ![string is integer -strict $n] } { set n 0 }
  if { $w eq "" } { set w none }
  return [list $n $w]
}

proc axi294_swap_src_dst { path } {
  set out {}
  foreach seg [split $path "|"] { lappend out [string map {src dst dst src} $seg] }
  return [join $out "|"]
}

# ---------------------------------------------------------------------------
# Discover the CDC groups from the netlist (same naming rules as the SDC, but
# computed here independently so a missing constraint shows up as a group
# without coverage rather than not at all).
# ---------------------------------------------------------------------------
set parents {}
foreach_in_collection r [get_registers -nowarn {*|i_src_ptr|wptr_q*}] {
  set n [get_register_info $r -name]
  set p [string range $n 0 [expr {[string first "|i_src_ptr|" $n] - 1}]]
  if { [lsearch -exact $parents $p] < 0 } { lappend parents $p }
}
set groups {}   ;# list of {kind P from_pattern to_pattern n_from n_to}
foreach P $parents {
  set Q [axi294_swap_src_dst $P]
  set w_from "${P}|i_src_ptr|wptr_q*";  set w_to "${Q}|i_dst_ptr|gen_sync\[*\].i_sync|reg_q\[0\]"
  set r_from "${Q}|i_dst_ptr|rptr_q*";  set r_to "${P}|i_src_ptr|gen_sync\[*\].i_sync|reg_q\[0\]"
  lappend groups [list wptr $P $w_from $w_to [get_collection_size [get_registers -nowarn $w_from]] [get_collection_size [get_registers -nowarn $w_to]]]
  lappend groups [list rptr $P $r_from $r_to [get_collection_size [get_registers -nowarn $r_from]] [get_collection_size [get_registers -nowarn $r_to]]]
  set d_from "${P}|i_src_data|data_q*"; set d_to "${Q}|i_dst_data|*a_data_q*"
  set nf [get_collection_size [get_registers -nowarn $d_from]]; set nt [get_collection_size [get_registers -nowarn $d_to]]
  if { $nf > 0 || $nt > 0 } { lappend groups [list data_orig $P $d_from $d_to $nf $nt] }
  set m_from "${P}|mem\[*\]\[*\]"; set m_to "${P}|rdata_q*"
  set nf [get_collection_size [get_registers -nowarn $m_from]]; set nt [get_collection_size [get_registers -nowarn $m_to]]
  if { $nf > 0 || $nt > 0 } { lappend groups [list data_fallback $P $m_from $m_to $nf $nt] }
}
set fh [open $od/sta_extra_groups.rpt w]
puts $fh "axi294_groups: fifos=[llength $parents]"
foreach g $groups {
  lassign $g kind P f t nf nt
  puts $fh "group kind=$kind parent=$P from=$f to=$t n_from=$nf n_to=$nt"
}
close $fh

# ---------------------------------------------------------------------------
# All operating conditions (corners): append one marked section per corner.
# ---------------------------------------------------------------------------
set corner_idx 0
foreach_in_collection op [get_available_operating_conditions] {
  set_operating_conditions $op
  update_timing_netlist
  if { [catch { set cname [get_operating_conditions_info -display_name $op] }] } { set cname $op }
  set cname [string trim $cname]
  foreach r {sta_extra_net_delay.rpt sta_extra_max_skew.rpt sta_extra_data_delay.rpt sta_extra_cut_paths.rpt} {
    axi294_mark $od/$r "axi294_corner: $cname"
  }
  report_net_delay -nworst 2000 -append -file $od/sta_extra_net_delay.rpt
  report_max_skew  -append -file $od/sta_extra_max_skew.rpt

  # set_data_delay coverage: worst paths overall, then per group the exact
  # count of (from,to) pairs covered and the worst slack (npaths 0 = all).
  set dd $od/sta_extra_data_delay.rpt
  set res [axi294_count -setup -data_delay]
  axi294_mark $dd "axi294_data_delay_total: pairs=[lindex $res 0] worst=[lindex $res 1]"
  if { [lindex $res 0] > 0 } {
    report_timing -setup -data_delay -npaths 200 -pairs_only -detail summary -append -file $dd
  }
  foreach g $groups {
    lassign $g kind P f t nf nt
    if { $kind ne "data_orig" && $kind ne "data_fallback" } { continue }
    set fc [get_registers -nowarn $f]; set tc [get_registers -nowarn $t]
    if { [get_collection_size $fc] == 0 || [get_collection_size $tc] == 0 } {
      axi294_mark $dd "axi294_group: $kind $P pairs=0 worst=none (from/to collection empty: $nf/$nt registers)"
      continue
    }
    set res [axi294_count -setup -data_delay -from $fc -to $tc]
    axi294_mark $dd "axi294_group: $kind $P pairs=[lindex $res 0] worst=[lindex $res 1] n_from=$nf n_to=$nt"
    if { [lindex $res 0] > 0 } {
      report_timing -setup -data_delay -from $fc -to $tc -npaths 20 -pairs_only -detail summary -append -file $dd
    }
  }

  # Every path cut by the clock groups, both directions. Full listing in the
  # first corner (topology is corner-independent), counts in every corner.
  set cut $od/sta_extra_cut_paths.rpt
  foreach dir {{src_clk dst_clk} {dst_clk src_clk}} {
    lassign $dir fclk tclk
    set res [axi294_count -setup -false_path -from_clock $fclk -to_clock $tclk]
    axi294_mark $cut "axi294_cut_paths: $fclk->$tclk pairs=[lindex $res 0] worst=[lindex $res 1]"
    if { $corner_idx == 0 && [lindex $res 0] > 0 } {
      report_timing -setup -false_path -from_clock $fclk -to_clock $tclk -npaths 0 -pairs_only -detail summary -append -file $cut
    }
  }
  incr corner_idx
}
set_operating_conditions [lindex [get_available_operating_conditions] 0]
update_timing_netlist

report_metastability -file $od/sta_extra_metastability.rpt

set out_regs [get_registers -nowarn {*|i_dst_data|* *valid_q* *ram_block* *rdata_q*}]
report_timing -setup -to_clock dst_clk -to $out_regs -npaths 10 -detail full_path -file $od/sta_extra_dst_out.rpt

report_timing -hold -to_clock src_clk -npaths 5 -detail path_only -file $od/sta_extra_hold.rpt
report_timing -hold -to_clock dst_clk -npaths 5 -detail path_only -append -file $od/sta_extra_hold.rpt

report_timing -setup -from_clock src_clk -to_clock dst_clk -npaths 5 -detail summary -file $od/sta_extra_cross.rpt
report_timing -setup -from_clock dst_clk -to_clock src_clk -npaths 5 -detail summary -append -file $od/sta_extra_cross.rpt

report_ucp -file $od/sta_extra_ucp.rpt

delete_timing_netlist
project_close
qexit -success
