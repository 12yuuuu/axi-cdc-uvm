#!/bin/bash
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Post-fit simulation of axi_cdc_ram and the CDC timing check, on Arria 10.
#
#   bash sim/postfit.sh            # LogDepth 2, device 10AX016E3F27E1HG
#
#   1. Quartus Prime Pro compiles tools/fpga/axi_cdc_ram_flat.sv (axi_cdc_ram
#      with flat ports, every port but the clocks a virtual pin) with
#      tools/fpga/constraints.sdc.
#   2. CDC timing: tools/fpga/sta_extra.tcl writes the Timing Analyzer
#      reports of every corner; tools/fpga/check_cdc.py checks that every
#      gray-pointer bundle and fabric data crossing is constrained and met,
#      and its self-test plants defects that it must catch.
#   3. quartus_eda writes the post-fit functional netlist for Xcelium.
#   4. The same UVM tests run on the RTL and on the netlist (+define+POSTFIT)
#      with the same seeds; tools/compare_traces.py compares the transaction
#      traces of each pair.
# Output: logs/postfit/ (results.md, reports, logs) and postfit_logs.tgz.
# Exit code 0 only if both the post-fit simulation and the CDC timing pass.
#
# Needs Xcelium (tcsh: source /CMC/tools/CSHRCs/Cadence.XCELIUM23), Quartus
# Prime Pro 23.2 (QUARTUS_ROOTDIR_OVERRIDE, default /cad1/Altera/23.2/quartus),
# a Quartus license (QUARTUS_LICENSE=port@host, or LM_LICENSE_FILE) and
# python3. Builds in /tmp (home quotas are often small).

source "$(dirname "$0")/common.sh"
DEPTH=${LOG_DEPTH:-2}
DEVICE=${DEVICE:-10AX016E3F27E1HG}
QROOT=${QUARTUS_ROOTDIR_OVERRIDE:-/cad1/Altera/23.2/quartus}
export QUARTUS_ROOTDIR_OVERRIDE=$QROOT
export PATH=$PATH:$QROOT/bin
QLIC=${QUARTUS_LICENSE:-}
q () { env -u MGLS_LICENSE_FILE LM_LICENSE_FILE="$QLIC${QLIC:+${LM_LICENSE_FILE:+:}}${LM_LICENSE_FILE:-}" "$@"; }

W=/tmp/$USER/axi_cdc_uvm/postfit
LOG=$ROOT/logs/postfit
Q=$W/quartus
rm -rf "$W" "$LOG"; mkdir -p "$Q" "$W/sim" "$W/traces" "$LOG"
T0=$(date +%s)
pack () { cd "$ROOT" && tar czf postfit_logs.tgz logs/postfit && echo "== logs packed: $ROOT/postfit_logs.tgz"; }
fail () { echo "FAILED: $*"; echo "FAILED: $*" >> "$LOG/status.txt"; pack; exit 1; }
say () { echo "== $*"; echo "== $*" >> "$LOG/status.txt"; }

say "1/6 tools"
command -v quartus_sh >/dev/null || fail "quartus_sh not found in $QROOT/bin"
[ -n "$QLIC${LM_LICENSE_FILE:-}" ] || fail "no Quartus license: set QUARTUS_LICENSE=port@host (or LM_LICENSE_FILE)"
q quartus_sh --version 2>&1 | head -2 | tee "$LOG/quartus_version.txt"
SIMVER=$(xrun -version 2>&1 | head -1 | sed -E 's/^TOOL:[[:space:]]*//; s/[[:space:]]+/ /g')
echo "  $SIMVER"

say "2/6 Quartus compile: axi_cdc_ram_flat, LogDepth $DEPTH, $DEVICE (a few minutes)"
( cd "$Q" && q quartus_sh -t "$ROOT/tools/fpga/postfit.tcl" "$ROOT" "$DEPTH" "$DEVICE" ) > "$LOG/quartus_compile.log" 2>&1
rc=$?
cp "$Q"/output_files/*.rpt "$Q"/output_files/*.summary "$LOG/" 2>/dev/null
if [ $rc -ne 0 ]; then
  grep -E '^Error|Error \(' "$LOG/quartus_compile.log" | head -20 | sed 's/^/  /'
  fail "Quartus compile (exit $rc), see logs/postfit/quartus_compile.log"
fi
{
  echo "Device: $DEVICE (Arria 10 GX), LogDepth $DEPTH"
  grep -hE 'Fitter Status|Logic utilization|Total registers|Total pins|Total block memory bits|Total RAM Blocks|Total DSP' \
    "$Q"/output_files/*.fit.summary 2>/dev/null
  grep -hA8 'Fmax Summary' "$Q"/output_files/*.sta.rpt 2>/dev/null | grep -E '^;.*MHz' | head -8
} > "$LOG/quartus_summary.txt"
sed 's/^/  /' "$LOG/quartus_summary.txt"

say "3/6 CDC timing: reports of every corner, check_cdc.py and its self-test"
( cd "$Q" && q quartus_sta -t "$ROOT/tools/fpga/sta_extra.tcl" axi_cdc_postfit ) > "$LOG/sta_extra.log" 2>&1
rc=$?
cp "$Q"/output_files/sta_extra_*.rpt "$LOG/" 2>/dev/null
[ $rc -eq 0 ] || echo "  quartus_sta -t sta_extra.tcl exit $rc (see logs/postfit/sta_extra.log)"
python3 -I "$ROOT/tools/fpga/check_cdc.py" "$Q/output_files" --bundles 10 --bits $((DEPTH + 1)) > "$LOG/check_cdc.log" 2>&1
echo $? > "$LOG/check_cdc.rc"
sed 's/^/  /' "$LOG/check_cdc.log" | tail -8
python3 -I "$ROOT/tools/fpga/test_check_cdc.py" "$Q/output_files" --bundles 10 --bits $((DEPTH + 1)) > "$LOG/check_cdc_selftest.log" 2>&1
echo $? > "$LOG/check_cdc_selftest.rc"
tail -2 "$LOG/check_cdc_selftest.log" | sed 's/^/  /'

say "4/6 post-fit netlist for Xcelium"
( cd "$Q" && q quartus_eda axi_cdc_postfit --simulation --tool=xcelium --format=verilog ) > "$LOG/quartus_eda.log" 2>&1
rc=$?
VO=$(find "$Q" -name '*.vo' | head -1)
if [ $rc -ne 0 ] || [ -z "$VO" ]; then
  grep -E '^Error|Error \(' "$LOG/quartus_eda.log" | head -10 | sed 's/^/  /'
  fail "quartus_eda (exit $rc, netlist: ${VO:-none})"
fi
NET=$W/sim/axi_cdc_ram_flat_postfit.v
cp "$VO" "$NET"
gzip -c "$NET" > "$LOG/axi_cdc_ram_flat_postfit.v.gz"
# the module and its ports, as declared in the netlist
awk '/^module axi_cdc_ram_flat/{m=1} m && /^[[:space:]]*(input|output|inout)/{print} m && /^endmodule/{exit}' "$NET" \
  | sed -E 's/[[:space:]]+/ /g; s/^ //' | head -20 > "$LOG/netlist_ports.txt"
{ echo "cells:"; grep -oE '^[[:space:]]*[a-z][a-z0-9_]* +\\' "$NET" | sed -E 's/[[:space:]\\]//g' | grep -vxE 'assign|defparam|wire' | sort | uniq -c; } \
  >> "$LOG/netlist_ports.txt"
sed 's/^/  /' "$LOG/netlist_ports.txt"
grep -q '^module axi_cdc_ram_flat' "$NET" || fail "the netlist has no module axi_cdc_ram_flat"
for p in src_clk_i src_rst_ni src_req_i src_resp_o dst_clk_i dst_rst_ni dst_req_o dst_resp_i; do
  grep -qE "(input|output).*[^a-z_]$p[^a-z_]" "$LOG/netlist_ports.txt" || fail "netlist port $p missing (virtual pins dropped?)"
done

say "5/6 Arria 10 simulation libraries (elaborate the netlist alone until every cell resolves)"
SL=$QROOT/eda/sim_lib
ls "$SL" "$SL/cadence" > "$LOG/sim_lib.txt" 2>&1
# Start from the libraries the netlist names directly: dffeas (altera_primitives.v)
# and the twentynm_* atoms (plain + Cadence-encrypted part). Then elaborate the
# netlist on its own; for every design unit Xcelium reports unresolved
# (*E,CUVMUR), add the sim_lib file that defines it, and retry. Libraries are
# compiled as plain sources (a -v library scan cannot see module names inside
# an encrypted block, and packages cannot live in a -v library), except
# altera_primitives.v, a plain library of many generic cells of which the
# netlist needs one.
LIBS=()
for f in altera_primitives.v twentynm_atoms.v cadence/twentynm_atoms_ncrypt.v; do
  [ -f "$SL/$f" ] || fail "missing $SL/$f"
done
LIBS=(-v "$SL/altera_primitives.v" "$SL/twentynm_atoms.v" "$SL/cadence/twentynm_atoms_ncrypt.v")
elab_ok=0
mkdir -p "$W/sim/elab" && cd "$W/sim/elab" || fail "no build directory"
for try in 1 2 3 4 5; do
  xrun -64bit -elaborate -timescale 1ns/1ps "$NET" "${LIBS[@]}" -top axi_cdc_ram_flat -l "$LOG/elab_netlist_$try.log" > /dev/null 2>&1
  missing=$(grep -oE "design unit '[A-Za-z0-9_]+' is unresolved" "$LOG/elab_netlist_$try.log" | sed -E "s/design unit '([^']+)'.*/\1/" | sort -u)
  errs=$(grep -E '\*E,|\*F,' "$LOG/elab_netlist_$try.log" | grep -vc CUVMUR)
  if [ -z "$missing" ] && [ "$errs" -eq 0 ] && ! grep -q '\*E,ELBERR' "$LOG/elab_netlist_$try.log"; then
    echo "  netlist elaborates (try $try)"; elab_ok=1; break
  fi
  [ -z "$missing" ] && { grep -E '\*E,|\*F,' "$LOG/elab_netlist_$try.log" | head -5 | cut -c1-200 | sed 's/^/  /'; fail "netlist elaboration (see logs/postfit/elab_netlist_$try.log)"; }
  added=0
  for m in $missing; do
    f=$(grep -lE "^[[:space:]]*module[[:space:]]+$m([[:space:](#;]|$)" "$SL"/*.sv "$SL"/*.v "$SL"/cadence/*.v "$SL"/cadence/*.sv 2>/dev/null | head -1)
    if [ -n "$f" ] && [[ " ${LIBS[*]} " != *" $f "* ]]; then
      LIBS=("$f" "${LIBS[@]}"); added=1; echo "  $m -> ${f#$SL/}"
    else
      echo "  $m: no sim_lib file defines it"
    fi
  done
  [ $added = 1 ] || fail "unresolved cells: $(echo $missing) (see logs/postfit/sim_lib.txt)"
done
[ $elab_ok = 1 ] || fail "netlist still does not elaborate after 5 tries"
printf '%s\n' "${LIBS[@]}" | sed "s|$SL/||" > "$LOG/sim_libs_used.txt"
echo "  libraries: $(tr '\n' ' ' < "$LOG/sim_libs_used.txt")"

say "6/6 simulations: RTL and post-fit netlist, same tests and seeds"
CSV=$LOG/summary.csv
echo "$CSV_HEADER" > "$CSV"
COVOPT=()
TESTS="smoke_test:1 burst_test:1 order_test:1 backpressure_test:1 fifo_full_test:1
       rand_cov_test:1 rand_cov_test:2 rand_cov_test:3 rand_ooo_test:1 rand_ooo_test:2 rand_ooo_test:3"
NPLAN=$(echo $TESTS | wc -w)
TB_LANG=()                                          # extensions decide: .sv SystemVerilog, .v Verilog
for mode in rtl gate; do
  RUN=$W/sim/$mode
  if [ $mode = gate ]; then TB_EXTRA=(+define+POSTFIT "$NET" "${LIBS[@]}"); else TB_EXTRA=(); fi
  for tc in $TESTS; do
    t=${tc%%:*}; s=${tc#*:}
    name="pf_${mode}_d${DEPTH}_${t%_test}_s$s"
    args=(); case $t in rand_*) args=(+RAND_CLOCKS +CLK_CORNERS) ;; esac
    run_case "pf_$mode" "$name" "$t" 1 "$DEPTH" "$s" "${args[@]}" +TRACE_FILE="$W/traces/$name.trace"
  done
done
python3 "$ROOT/tools/compare_traces.py" "$W/traces" -o "$LOG/trace_compare.csv" --pair _rtl_:_gate_
T1=$(date +%s)
python3 "$ROOT/tools/postfit_report.py" "$LOG" --planned "$NPLAN" \
  --meta "Quartus=$(grep -m1 -i version "$LOG/quartus_version.txt" | sed -E 's/^[[:space:]]+//')" \
  --meta "Simulator=$SIMVER" --meta "Host=$(hostname)" --meta "Date=$(date '+%Y-%m-%d %H:%M %Z')" \
  --meta "Wall time=$(( (T1 - T0) / 60 )) min $(( (T1 - T0) % 60 )) s"
status=$?
echo "   results page: logs/postfit/results.md"
pack
exit $status
