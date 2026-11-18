#!/bin/bash
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Tests for the regression scripts themselves, without a simulator: a fake
# `xrun` writes logs in the format of the real testbench, and
# `sim/regress.sh quick` must give the expected verdict.
#
#   bash sim/test_regress.sh        # exit code 0 if every case behaves
#
# Cases:
#   1. every run passes, exit status 0                       -> SIGNED OFF
#   2. every run also prints the known *E,IMPDLL and exits 1, and the
#      assertion negative tests print *E,ASRTST (as Xcelium does)  -> SIGNED OFF
#   3. one run prints TEST PASSED but exits 7                -> that run FAIL,
#                                                               NOT SIGNED OFF
#   4. one run is never written (simulator crashed early)    -> NOT SIGNED OFF
# Used by the CI. Writes logs/regress (as a real regression would).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/xrun" <<'FAKE'
#!/bin/bash
# fake xrun: logs in the real format; FAKE_MODE selects a fault
[ "$1" = "-version" ] && { echo "TOOL: xrun(64) 00.00-fake"; exit 0; }
log= test= trace= inj= ram= seed=
while [ $# -gt 0 ]; do
  case "$1" in
    -l) log=$2; shift ;;
    -svseed) seed=$2; shift ;;
    +UVM_TESTNAME=*) test=${1#*=} ;;
    +TRACE_FILE=*) trace=${1#*=} ;;
    +INJECT_*) inj=${1#+} ;;
    tb_top.USE_RAM=*) ram=${1#*=} ;;
  esac
  shift
done
name=$(basename "$log" .log)
[ "$FAKE_MODE" = crash ] && [ "$name" = dir_ram_d2_burst ] && exit 139
{
  echo "TOOL: xrun(64) 00.00-fake: Started"
  [ "$FAKE_MODE" = impdll ] && echo "xmsim: *E,IMPDLL: Unable to load the implicit shared object."
  echo "UVM_INFO tb_top.sv(1) @ 0: reporter [TB] src period 10.000 ns, dst period 10.000 ns, dst phase 0.000 ns"
  echo "UVM_INFO x @ 0: uvm_test_top.env.mst.mon [MON] AW 3, W 2, B 1, AR 4, R 5"
  echo "UVM_INFO x @ 0: uvm_test_top.env.slv_mon [MON] AW 1, W 1, B 2, AR 1, R 3"
  f=0
  case "$inj" in
    INJECT_RDATA_ERR)    echo "UVM_ERROR x @ 5: sb [SB_READ] x"; echo "UVM_ERROR x @ 5: sb [SB_DATA] x"; f=1 ;;
    INJECT_BRESP_ERR)    echo "UVM_ERROR x @ 5: sb [SB_WRITE] x"; echo "UVM_ERROR x @ 5: sb [SB_RESP] x"; f=1 ;;
    INJECT_AW_UNSTABLE)  echo "UVM_ERROR x @ 5: sva [SVA_AW] x"; f=1
                         [ "$FAKE_MODE" = impdll ] && echo "xmsim: *E,ASRTST (sva.sv,32): Assertion a_aw_stable has failed" ;;
    INJECT_PTR_GLITCH)   echo "UVM_ERROR x @ 5: sva [SVA_OCC] x"; echo "UVM_ERROR x @ 5: sva [SVA_GRAY] x"; f=1
                         [ "$FAKE_MODE" = impdll ] && echo "xmsim: *E,ASRTST (sva.sv,98): Assertion a_gray_r has failed" ;;
    INJECT_SLV_WRAP_BUG) echo "UVM_ERROR x @ 5: sb [SB_DATA] x"; f=1 ;;
  esac
  echo "UVM_INFO x @ 9: sb [SB] bridge check: writes 10 ok / 0 bad, reads 12 ok / 0 bad; data check: 48 beats ok / 0 bad; write beats 40; error responses 3 ok / 0 bad"
  echo "UVM_INFO x @ 9: cov [COV] bins hit: total 146/146; coincident clock edges 7"
  grep -v '^#' "$FAKE_GOALS" | sed 's/^/[COVBIN] /; s/$/ 2/'
  if [ $f = 1 ]; then echo "UVM_ERROR :    2"; echo "UVM_FATAL :    0"; echo "UVM_INFO x @ 9000000: [TEST] *** TEST FAILED ***"
  else echo "UVM_ERROR :    0"; echo "UVM_FATAL :    0"; echo "UVM_INFO x @ 9000000: [TEST] *** TEST PASSED ***"; fi
  echo "Simulation complete via \$finish(1) at time 9000000 PS + 0"
  echo "TOOL: xrun(64) 00.00-fake: Exiting on today (total: 00:00:01)"
} > "$log"
if [ -n "$trace" ]; then
  printf 'W id=%s addr=0001000%s len=0 size=3 burst=1 cache=0 prot=0 qos=0 region=0 user=0 data=00000000%08x resp=1\n' \
    1 1 "$seed" 2 2 "$seed" > "$trace"
fi
[ "$FAKE_MODE" = impdll ] && exit 1
[ "$FAKE_MODE" = exit7 ] && [ "$name" = dir_ram_d2_smoke ] && exit 7
exit 0
FAKE
chmod +x "$TMP/bin/xrun"
export FAKE_GOALS="$ROOT/tb/uvm/coverage_goals.txt"

n_ok=0; n_all=0
check () {   # check <case> <FAKE_MODE> <expect: signed|not> [grep pattern that must appear]
  local name=$1 mode=$2 want=$3 pat=${4:-} out rc ok=1
  out=$(FAKE_MODE=$mode PATH="$TMP/bin:$PATH" bash "$ROOT/sim/regress.sh" quick 2>&1); rc=$?
  if [ "$want" = signed ]; then
    { [ $rc -eq 0 ] && grep -q '^== SIGNED OFF' <<< "$out"; } || ok=0
  else
    { [ $rc -ne 0 ] && grep -q '^== NOT SIGNED OFF' <<< "$out"; } || ok=0
  fi
  [ -n "$pat" ] && { grep -qE "$pat" <<< "$out" || ok=0; }
  n_all=$((n_all + 1)); [ $ok = 1 ] && n_ok=$((n_ok + 1))
  printf "  %s %s\n" "$([ $ok = 1 ] && echo 'ok  ' || echo FAIL)" "$name"
  [ $ok = 1 ] || { echo "$out" | grep -E '^== |FAIL' | head -8 | sed 's/^/       /'; }
}

check "every run passes"                             ok     signed
check "known IMPDLL message, exit status 1, ASRTST"  impdll signed
check "TEST PASSED in the log but exit status 7"     exit7  not   'FAIL +dir_ram_d2_smoke|xrun exit status 7'
check "simulator crashed before writing a log"       crash  not   'FAIL +dir_ram_d2_burst'
rm -rf "$ROOT/logs/regress" "$ROOT/regress_logs.tgz"
echo "$n_ok/$n_all regression-script cases behave as expected"
[ $n_ok -eq $n_all ]
