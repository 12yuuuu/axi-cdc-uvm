#!/bin/bash
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Regression for the axi_cdc_ram UVM testbench. One command; every run is
# reproducible from its seed with sim/run_one.sh.
#
#   bash sim/regress.sh          full regression, ~270 runs
#   bash sim/regress.sh quick    tool tests, negative + directed tests, a few random seeds
#
# Sets:
#   neg    5 negative tests: each injected fault must be caught by its own
#          checker, and the checkers it is not aimed at must stay silent
#   dir    directed tests (smoke, burst, order, backpressure, fifo_full, addr_model)
#   clk    clock sweep: 11 clock settings x 2 tests (axi_cdc_ram), 4 x 2 (axi_cdc)
#   depth  fifo_full_test at LOG_DEPTH 1, 4 and 6
#   rand   rand_cov_test with random clocks and clock corners, all configurations
#   ooo    rand_ooo_test: B out of order, R interleaved, SLVERR/DECERR pages
#   deep   rand_deep_test, LOG_DEPTH 4 and 6
#
# Runs that have a twin on the other DUT (same test, same seed) write a
# transaction trace; tools/compare_traces.py checks that both DUTs carried
# the same transactions (vplan F13).
#
# Output in logs/regress/: one log per run, summary.csv, coverage.md/.csv,
# trace_compare.csv, results.md (the results page) and regress_logs.tgz.
# Exit code 0 only if the regression signs off (docs/vplan.md, section 5;
# the rules are in tools/report.py and tested by tools/test_report.py).
#
# Needs Xcelium (tcsh: source /CMC/tools/CSHRCs/Cadence.XCELIUM23) and python3.

source "$(dirname "$0")/common.sh"
MODE=${1:-full}
case $MODE in full|quick) ;; *) echo "usage: bash sim/regress.sh [full|quick]"; exit 2 ;; esac
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }
RUN=/tmp/$USER/axi_cdc_uvm/regress
LOG=$ROOT/logs/regress
CSV=$LOG/summary.csv
TRC=$RUN/traces            # traces are large; only trace_compare.csv is kept
COVOPT=()
rm -rf "$RUN" "$LOG"; mkdir -p "$RUN" "$LOG" "$TRC"
T0=$(date +%s)
SIMVER=$(xrun -version 2>&1 | head -1 | sed -E 's/^TOOL:[[:space:]]*//; s/[[:space:]]+/ /g')
echo "== regression ($MODE)   $SIMVER   host $(hostname)   $(date)"
echo "$CSV_HEADER" > "$CSV"
trace () { echo "+TRACE_FILE=$TRC/$1.trace"; }   # plusarg for a run that has a twin

echo "== tools: sign-off rules and the Python address model"
python3 "$ROOT/tools/test_report.py" | tail -1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "tools/test_report.py failed: the sign-off script cannot be trusted"; exit 1; }
python3 "$ROOT/tools/axi_addr_model.py" | tail -1 | sed 's/^/  /'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "tools/axi_addr_model.py failed"; exit 1; }

# neg <name> <test> <tag> <forbid> [plusargs]: the run must fail with errors
# of <tag>, and no error may match <forbid> (other checkers stay silent).
NEGS=()
neg () {
  local name=$1 test=$2 tag=$3 forbid=$4; shift 4
  local L=$LOG/$name.log
  NEGS+=("$name")
  mkdir -p "$RUN/ram1_d2" && cd "$RUN/ram1_d2" || return
  xrun_tb "$L" 1 2 "$test" 1 "$@"
  local hits other sb sva r=MISSED
  hits=$(grep -c "UVM_ERROR .*\[$tag\]" "$L")
  other=$(grep -cE "UVM_ERROR .*\[($forbid)" "$L")
  sb=$(grep -c 'UVM_ERROR .*\[SB_' "$L")
  sva=$(grep -c 'UVM_ERROR .*\[SVA_' "$L")
  if grep -q '\*\*\* TEST FAILED \*\*\*' "$L" && [ "$hits" -gt 0 ] && [ "$other" -eq 0 ]; then r=CAUGHT; fi
  # same columns as CSV_HEADER: result in column 10, bad in 16, sva_errors in 27
  echo "$name,neg,$test,1,1,2,,,,$r,,,,,,$sb,,,,,,,,,,,$sva," >> "$CSV"
  printf "  %-6s %-16s [%s] %-3s  must stay silent: %-28s %s\n" "$r" "$name" "$tag" "$hits" "$forbid" "$other"
}

echo "== neg: negative tests"
#   name             test            expected  must stay silent
neg neg_rdata       smoke_test      SB_DATA   'SVA_'                     +INJECT_RDATA_ERR
neg neg_bresp       smoke_test      SB_RESP   'SVA_'                     +INJECT_BRESP_ERR
neg neg_aw_unstable fifo_full_test  SVA_AW    'SB_'                      +INJECT_AW_UNSTABLE
neg neg_ptr_glitch  smoke_test      SVA_GRAY  'SB_'                      +INJECT_PTR_GLITCH
neg neg_slave_wrap  burst_test      SB_DATA   'SB_READ|SB_WRITE|SB_RESP|SVA_' +INJECT_SLV_WRAP_BUG

echo "== dir: directed tests, axi_cdc_ram LOG_DEPTH 2"
for t in smoke burst order backpressure fifo_full addr_model; do run_case dir "dir_ram_d2_$t" "${t}_test" 1 2 1; done

if [ "$MODE" = full ]; then
  echo "== clk: clock sweep (periods in ps)"
  #        name          src    dst    dst phase
  CLOCKS="s10_d10_ph0   10000  10000  0
          s10_d10_ph25  10000  10000  2500
          s10_d10_ph50  10000  10000  5000
          s10_d10_ph75  10000  10000  7500
          s10_d10.1     10000  10100  0
          s5_d10        5000   10000  0
          s10_d5        10000  5000   0
          s7_d3         7000   3000   0
          s3_d7         3000   7000   0
          s30_d3        30000  3000   0
          s3_d30        3000   30000  0"
  while read -r cn sp dp ph; do
    [ -z "$cn" ] && continue
    clk=(+SRC_PERIOD_PS="$sp" +DST_PERIOD_PS="$dp" +DST_PHASE_PS="$ph")
    case "$cn" in
      s10_d10_ph0|s10_d10.1|s7_d3|s3_d30)     # these four also run on axi_cdc, with traces
        for k in bp:backpressure_test full:fifo_full_test; do
          run_case clk "clk_ram_d2_${cn}_${k%%:*}"  "${k#*:}" 1 2 1 "${clk[@]}" $(trace "clk_ram_d2_${cn}_${k%%:*}")
          run_case clk "clk_orig_d2_${cn}_${k%%:*}" "${k#*:}" 0 2 1 "${clk[@]}" $(trace "clk_orig_d2_${cn}_${k%%:*}")
        done ;;
      *)
        run_case clk "clk_ram_d2_${cn}_bp"   backpressure_test 1 2 1 "${clk[@]}"
        run_case clk "clk_ram_d2_${cn}_full" fifo_full_test    1 2 1 "${clk[@]}" ;;
    esac
  done <<< "$CLOCKS"

  echo "== depth: fifo_full_test at every depth"
  for d in 1 4 6; do run_case depth "depth_ram_d${d}_fifo_full" fifo_full_test 1 "$d" 1; done
fi

RC=(+RAND_CLOCKS +CLK_CORNERS)
# rnd <set> <prefix> <test> <ram> <depth> <first seed> <last seed> [trace]
rnd () {
  local set=$1 pre=$2 test=$3 ram=$4 depth=$5 s0=$6 s1=$7 tr=${8:-} c
  c=$([ "$ram" = 1 ] && echo ram || echo orig)_d$depth
  for s in $(seq "$s0" "$s1"); do
    run_case "$set" "${pre}_${c}_s$s" "$test" "$ram" "$depth" "$s" "${RC[@]}" ${tr:+$(trace "${pre}_${c}_s$s")}
  done
}
if [ "$MODE" = full ]; then
  echo "== rand: rand_cov_test, random clocks and clock corners"
  rnd rand rand rand_cov_test 1 2  1 20 trace
  rnd rand rand rand_cov_test 0 2  1 20 trace
  rnd rand rand rand_cov_test 1 2 21 50
  rnd rand rand rand_cov_test 1 4  1 20
  rnd rand rand rand_cov_test 1 6  1 20
  rnd rand rand rand_cov_test 1 1  1 10
  echo "== ooo: rand_ooo_test, out-of-order B, interleaved R, error responses"
  rnd ooo  ooo  rand_ooo_test 1 2  1 20 trace
  rnd ooo  ooo  rand_ooo_test 0 2  1 20 trace
  rnd ooo  ooo  rand_ooo_test 1 4  1 10
  rnd ooo  ooo  rand_ooo_test 1 6  1 10
  rnd ooo  ooo  rand_ooo_test 1 1  1 10
  echo "== deep: rand_deep_test"
  rnd deep deep rand_deep_test 1 4 1 20
  rnd deep deep rand_deep_test 1 6 1 20
  CONFIGS=ram_d1,ram_d2,ram_d4,ram_d6,orig_d2
else
  echo "== rand / ooo: a few seeds"
  rnd rand rand rand_cov_test 1 2 1 6
  rnd rand rand rand_cov_test 1 2 7 8 trace
  rnd rand rand rand_cov_test 0 2 7 8 trace
  rnd ooo  ooo  rand_ooo_test 1 2 1 4
  rnd ooo  ooo  rand_ooo_test 1 2 5 6 trace
  rnd ooo  ooo  rand_ooo_test 0 2 5 6 trace
  CONFIGS=ram_d2,orig_d2
fi

# ------------------------------------------------------------- reports
L=$LOG
sets=()
for c in ram_d1 ram_d2 ram_d4 ram_d6 orig_d2; do
  ls "$L"/*_"${c}"_*.log > /dev/null 2>&1 && sets+=("$c=$L/*_${c}_*.log")
done
python3 "$ROOT/tools/merge_cov.py" -o "$LOG/coverage" "${sets[@]}" > /dev/null
echo
python3 "$ROOT/tools/compare_traces.py" "$TRC" -o "$LOG/trace_compare.csv"
T1=$(date +%s)
python3 "$ROOT/tools/report.py" "$CSV" "$LOG/coverage.csv" -o "$LOG/results.md" \
  --goals "$ROOT/tb/uvm/coverage_goals.txt" --logs "$LOG" --configs "$CONFIGS" \
  --neg "$(IFS=,; echo "${NEGS[*]}")" --traces "$LOG/trace_compare.csv" --mode "$MODE" \
  --meta "Mode=$MODE" --meta "Simulator=$SIMVER" --meta "Host=$(hostname)" \
  --meta "Date=$(date '+%Y-%m-%d %H:%M %Z')" --meta "Wall time=$(( (T1 - T0) / 60 )) min $(( (T1 - T0) % 60 )) s"
status=$?
sed -n '/^## Functional coverage/,$p' "$LOG/results.md" | sed -n '5,20p'
echo "   results page: logs/regress/results.md"
cd "$ROOT" && tar czf regress_logs.tgz logs/regress && echo "== logs packed: $ROOT/regress_logs.tgz"
rm -rf "$RUN"
exit $status
