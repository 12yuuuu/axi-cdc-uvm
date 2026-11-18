# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Shared settings for the simulation scripts. Source it from bash:
#   source "$(dirname "$0")/common.sh"
# Needs Xcelium on PATH (tcsh: source /CMC/tools/CSHRCs/Cadence.XCELIUM23).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v xrun >/dev/null || { echo "xrun not found. In tcsh run: source /CMC/tools/CSHRCs/Cadence.XCELIUM23"; exit 1; }
UVMDIR=$(dirname "$(dirname "$(command -v xrun)")")/methodology/UVM
if [ -d "$UVMDIR/CDNS-1.2" ]; then UVMOPT=(-uvm -uvmhome CDNS-1.2); else UVMOPT=(-uvm); fi

R=$ROOT/rtl
T=$ROOT/tb
SRC=(
  "$R/tech_cells_generic/src/rtl/tc_sync.sv"
  "$R/common_cells/src/cc_binary_to_gray.sv"
  "$R/common_cells/src/cc_gray_to_binary.sv"
  "$R/common_cells/src/cc_spill_register_flushable.sv"
  "$R/common_cells/src/cc_spill_register.sv"
  "$R/common_cells/src/cc_cdc_fifo_gray.sv"
  "$R/dut/cc_cdc_fifo_gray_ram.sv"
  "$R/axi/src/axi_pkg.sv"
  "$R/axi/src/axi_cdc_src.sv"
  "$R/axi/src/axi_cdc_dst.sv"
  "$R/axi/src/axi_cdc.sv"
  "$R/dut/axi_cdc_ram.sv"
  "$T/uvm/axi_tb_cfg_pkg.sv"
  "$T/uvm/axi_vif.sv"
  "$T/uvm/axi_uvm_pkg.sv"
  "$T/sva/axi_handshake_sva.sv"
  "$T/sva/cdc_fifo_sva.sv"
  "$T/top/tb_top.sv"
)
INC=(+incdir+"$R/axi/include" +incdir+"$R/common_cells/include" +incdir+"$T/uvm")

# xrun_tb <log> <USE_RAM> <LOG_DEPTH> <test> <seed> [extra xrun args / plusargs]
# Run from the build directory. Same USE_RAM/LOG_DEPTH in the same directory
# reuses the compiled snapshot; seed, test and plusargs are run-time only.
# TB_LANG: language option for all files (sim/postfit.sh empties it so the
# Verilog netlist and libraries are read as Verilog). TB_EXTRA: more sources
# and defines (the post-fit netlist).
TB_LANG=(-sv)
TB_EXTRA=()
xrun_tb () {
  local log=$1 ram=$2 depth=$3 test=$4 seed=$5; shift 5
  timeout 1800 xrun -64bit "${TB_LANG[@]}" "${UVMOPT[@]}" -timescale 1ns/1ps "${INC[@]}" "${SRC[@]}" "${TB_EXTRA[@]}" -top tb_top \
    -defparam tb_top.USE_RAM="$ram" -defparam tb_top.LOG_DEPTH="$depth" \
    -svseed "$seed" +UVM_TESTNAME="$test" +UVM_VERBOSITY=UVM_LOW +UVM_NO_RELNOTES \
    "$@" -l "$log" > /dev/null 2>&1
}

# exit_ok <status> <log> -> 1 if the xrun exit status is acceptable: 0, or
# non-zero only when the log has the known *E,IMPDLL (see README, Known
# issue; it makes every xrun exit with 1), its only other errors are
# assertion failures (*E,ASRTST: the verdict judges those, a passing run
# must have none, a negative test needs its own), and the simulation reached
# $finish and exited normally. Anything else (timeout 124, an elaboration
# error, a crash, a tool that printed PASS and then failed) -> 0, and the
# run fails.
exit_ok () {
  local rc=$1 L=$2
  if [ "$rc" = 0 ]; then echo 1; return; fi
  if grep -q '\*E,IMPDLL' "$L" && [ "$(grep -E '\*E,|\*F,' "$L" | grep -vcE 'IMPDLL|ASRTST')" -eq 0 ] \
     && grep -q 'Simulation complete via \$finish' "$L" && grep -q 'TOOL:.*Exiting on' "$L"; then
    echo 1
  else
    echo 0
  fi
}

# verdict <log> <expect pass|fail>  -> prints PASS or FAIL
verdict () {
  local L=$1 expect=$2 errs
  errs=$(grep -E '\*E,|\*F,' "$L" | grep -vc 'IMPDLL')
  if [ "$expect" = pass ]; then
    if grep -q '\*\*\* TEST PASSED \*\*\*' "$L" && grep -q 'UVM_ERROR :    0' "$L" \
       && grep -q 'UVM_FATAL :    0' "$L" && [ "$errs" -eq 0 ]; then echo PASS; else echo FAIL; fi
  else
    if grep -q '\*\*\* TEST FAILED \*\*\*' "$L" && grep -q '\[SB_READ\]' "$L" && grep -q '\[SB_DATA\]' "$L"; then echo PASS; else echo FAIL; fi
  fi
}

# ---------------------------------------------------------------------------
# Regression helpers (Stage 8 on). The calling script sets RUN (build dirs),
# LOG (log dir), CSV (summary file) and COVOPT (coverage options, may be
# empty), then calls run_case for every run.
CSV_HEADER="name,set,test,seed,use_ram,log_depth,src_ns,dst_ns,phase_ns,result,writes_ok,reads_ok,beats_ok,wbeats_ok,resp_err_ok,bad,src_stall_aw,src_stall_w,src_stall_ar,dst_stall_b,dst_stall_r,hold_pulses,outstanding,coincident_edges,cov_hit,cov_all,sva_errors,sim_end_us,exit_code,exit_ok"
MANIFEST_HEADER="name,set,test,seed,use_ram,log_depth,trace"
n_pass=0; n_fail=0; failed=""

# plan_row <name> <set> <test> <seed> <ram> <depth> [plusargs]: one line of
# the run manifest (PLAN=1). The report checks every planned run against it.
plan_row () {
  local name=$1 set=$2 test=$3 seed=$4 ram=$5 depth=$6 tr=0 a; shift 6
  for a in "$@"; do case $a in +TRACE_FILE=*) tr=1 ;; esac; done
  echo "$name,$set,$test,$seed,$ram,$depth,$tr" >> "$MANIFEST"
}

# run_case <set> <name> <test> <USE_RAM> <LOG_DEPTH> <seed> [plusargs]
run_case () {
  local set=$1 name=$2 test=$3 ram=$4 depth=$5 seed=$6; shift 6
  if [ "${PLAN:-0}" = 1 ]; then plan_row "$name" "$set" "$test" "$seed" "$ram" "$depth" "$@"; return; fi
  local extra=("$@") L="$LOG/$name.log"
  mkdir -p "$RUN/ram${ram}_d${depth}" && cd "$RUN/ram${ram}_d${depth}" || return
  local cov=(); [ ${#COVOPT[@]} -gt 0 ] && cov=("${COVOPT[@]}" -covtest "$name")
  xrun_tb "$L" "$ram" "$depth" "$test" "$seed" "${cov[@]}" "${extra[@]}"
  local rc=$? xo
  xo=$(exit_ok "$rc" "$L")
  local v; v=$(verdict "$L" pass)
  [ "$xo" = 1 ] || v=FAIL
  local clk sb src dst hp endt out cv sva
  clk=$(grep -m1 '\[TB\]' "$L" | sed -nE 's/.*src period ([0-9.]+) ns, dst period ([0-9.]+) ns, dst phase ([0-9.]+) ns.*/\1 \2 \3/p')
  sb=$(grep -m1 '\[SB\] bridge check' "$L" | sed -nE 's/.*writes ([0-9]+) ok \/ ([0-9]+) bad, reads ([0-9]+) ok \/ ([0-9]+) bad; data check: ([0-9]+) beats ok \/ ([0-9]+) bad; write beats ([0-9]+); error responses ([0-9]+) ok \/ ([0-9]+) bad.*/\1 \2 \3 \4 \5 \6 \7 \8 \9/p')
  src=$(grep -m1 'env.mst.mon \[MON\]' "$L" | sed -nE 's/.*AW ([0-9]+), W ([0-9]+), B ([0-9]+), AR ([0-9]+), R ([0-9]+).*/\1 \2 \3 \4 \5/p')
  dst=$(grep -m1 'env.slv_mon \[MON\]' "$L" | sed -nE 's/.*AW ([0-9]+), W ([0-9]+), B ([0-9]+), AR ([0-9]+), R ([0-9]+).*/\1 \2 \3 \4 \5/p')
  hp=$(grep -m1 'hold pulses' "$L" | sed -nE 's/.*\] ([0-9]+) hold pulses.*/\1/p')
  out=$(grep -m1 'deep knobs' "$L" | sed -nE 's/.*outstanding ([0-9]+) .*/\1/p')
  [ -z "$out" ] && out=$(grep -m1 'closure knobs' "$L" | sed -nE 's/.*-> outstanding ([0-9]+).*/\1/p')
  [ -z "$out" ] && out=$(grep -m1 '\[RAND\] knobs' "$L" | sed -nE 's/.*knobs: outstanding ([0-9]+),.*/\1/p')
  cv=$(grep -m1 '\[COV\] bins hit' "$L" | sed -nE 's/.*total ([0-9]+)\/([0-9]+); coincident clock edges ([0-9]+).*/\1 \2 \3/p')
  sva=$(grep -c 'UVM_ERROR .*\[SVA_' "$L")
  endt=$(grep -m1 'TEST \(PASSED\|FAILED\)' "$L" | sed -nE 's/.*@ ([0-9]+):.*/\1/p')
  set -- $clk;  local sn=${1:-?} dn=${2:-?} pn=${3:-?}
  set -- $sb;   local wok=${1:-?} wbad=${2:-?} rok=${3:-?} rbad=${4:-?} bok=${5:-?} bbad=${6:-?} wbk=${7:-?} eok=${8:-?} ebad=${9:-?}
  set -- $src;  local saw=${1:-?} sw=${2:-?} sar=${4:-?}
  set -- $dst;  local db=${3:-?} dr=${5:-?}
  set -- $cv;   local ch=${1:-?} ca=${2:-?} co=${3:-?}
  local bad="?"
  if [[ "$wbad" =~ ^[0-9]+$ && "$rbad" =~ ^[0-9]+$ && "$bbad" =~ ^[0-9]+$ && "$ebad" =~ ^[0-9]+$ ]]; then
    bad=$(( wbad + rbad + bbad + ebad ))
  fi
  echo "$name,$set,$test,$seed,$ram,$depth,$sn,$dn,$pn,$v,$wok,$rok,$bok,$wbk,$eok,$bad,$saw,$sw,$sar,$db,$dr,${hp:--},${out:--},$co,$ch,$ca,$sva,$(( ${endt:-0} / 1000000 )),$rc,$xo" >> "$CSV"
  printf "  %-4s %-24s src %6s dst %6s ns  wr %4s rd %4s bad %-2s sva %-2s cov %3s/%-3s full %s/%s/%s/%s/%s\n" \
    "$v" "$name" "$sn" "$dn" "$wok" "$rok" "$bad" "$sva" "$ch" "$ca" "$saw" "$sw" "$sar" "$db" "$dr"
  if [ "$v" = PASS ]; then n_pass=$((n_pass + 1))
  else
    n_fail=$((n_fail + 1)); failed="$failed $name"
    [ "$xo" = 1 ] || echo "        xrun exit status $rc"
    grep -m4 -E '\*E,|\*F,|UVM_(ERROR|FATAL) [^:]' "$L" | grep -v IMPDLL | cut -c1-200 | sed 's/^/        /'
    echo "        reproduce: bash ~/axi_cdc_uvm/sim/run_one.sh $test $seed $ram $depth ${extra[*]} +VCD"
  fi
}

