#!/bin/bash
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Regression for the axi_cdc_ram UVM testbench. One command; every run is
# reproducible from its seed with sim/run_one.sh.
#
#   bash sim/regress.sh          full regression, ~200 runs, ~5 minutes
#   bash sim/regress.sh quick    negative + directed tests + 10 random seeds, ~1 minute
#
# Sets:
#   neg    3 negative tests: each injected fault must be caught by its checker
#   dir    directed tests (smoke, burst, order, backpressure, fifo_full)
#   clk    clock sweep: 11 clock settings x 2 tests (axi_cdc_ram), 4 x 2 (axi_cdc)
#   depth  fifo_full_test at LOG_DEPTH 1, 4 and 6
#   rand   rand_cov_test with random clocks and clock corners, all configurations
#   deep   rand_deep_test, LOG_DEPTH 4 and 6
#
# Output in logs/regress/: one log per run, summary.csv, coverage.md/.csv,
# results.md (the results page) and regress_logs.tgz. Exit code 0 only if
# the regression signs off (see docs/vplan.md, section 5).
#
# Needs Xcelium (tcsh: source /CMC/tools/CSHRCs/Cadence.XCELIUM23) and python3.

source "$(dirname "$0")/common.sh"
MODE=${1:-full}
case $MODE in full|quick) ;; *) echo "usage: bash sim/regress.sh [full|quick]"; exit 2 ;; esac
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }
RUN=/tmp/$USER/axi_cdc_uvm/regress
LOG=$ROOT/logs/regress
CSV=$LOG/summary.csv
COVOPT=()
rm -rf "$RUN" "$LOG"; mkdir -p "$RUN" "$LOG"
T0=$(date +%s)
SIMVER=$(xrun -version 2>&1 | head -1 | sed -E 's/^TOOL:[[:space:]]*//; s/[[:space:]]+/ /g')
echo "== regression ($MODE)   $SIMVER   host $(hostname)   $(date)"
echo "$CSV_HEADER" > "$CSV"

# neg <name> <test> <tag> [plusargs]: the run must fail, with errors of
# <tag>; except for neg_rdata the scoreboard must stay silent.
neg () {
  local name=$1 test=$2 tag=$3; shift 3
  local L=$LOG/$name.log
  mkdir -p "$RUN/ram1_d2" && cd "$RUN/ram1_d2" || return
  xrun_tb "$L" 1 2 "$test" 1 "$@"
  local hits sb sva r=MISSED
  hits=$(grep -c "UVM_ERROR .*\[$tag\]" "$L")
  sb=$(grep -c 'UVM_ERROR .*\[SB_' "$L")
  sva=$(grep -c 'UVM_ERROR .*\[SVA_' "$L")
  if grep -q '\*\*\* TEST FAILED \*\*\*' "$L" && [ "$hits" -gt 0 ]; then
    if [ "$tag" = SB_DATA ] || [ "$sb" -eq 0 ]; then r=CAUGHT; fi
  fi
  echo "$name,neg,$test,1,1,2,,,,$r,,,,$sb,,,,,,,,,,,$sva," >> "$CSV"
  printf "  %-6s %-16s [%s] errors %-3s scoreboard errors %-3s assertion errors %s\n" "$r" "$name" "$tag" "$hits" "$sb" "$sva"
}

echo "== neg: negative tests"
neg neg_rdata       smoke_test     SB_DATA  +INJECT_RDATA_ERR
neg neg_aw_unstable fifo_full_test SVA_AW   +INJECT_AW_UNSTABLE
neg neg_ptr_glitch  smoke_test     SVA_GRAY +INJECT_PTR_GLITCH

echo "== dir: directed tests, axi_cdc_ram LOG_DEPTH 2"
for t in smoke burst order backpressure fifo_full; do run_case dir "dir_ram_d2_$t" "${t}_test" 1 2 1; done

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
    run_case clk "clk_ram_d2_${cn}_bp"   backpressure_test 1 2 1 "${clk[@]}"
    run_case clk "clk_ram_d2_${cn}_full" fifo_full_test    1 2 1 "${clk[@]}"
    case "$cn" in
      s10_d10_ph0|s10_d10.1|s7_d3|s3_d30)
        run_case clk "clk_orig_d2_${cn}_bp"   backpressure_test 0 2 1 "${clk[@]}"
        run_case clk "clk_orig_d2_${cn}_full" fifo_full_test    0 2 1 "${clk[@]}" ;;
    esac
  done <<< "$CLOCKS"

  echo "== depth: fifo_full_test at every depth"
  for d in 1 4 6; do run_case depth "depth_ram_d${d}_fifo_full" fifo_full_test 1 "$d" 1; done
fi

echo "== rand: rand_cov_test, random clocks and clock corners"
RC=(+RAND_CLOCKS +CLK_CORNERS)
if [ "$MODE" = full ]; then
  for s in $(seq 1 50); do run_case rand "rand_ram_d2_s$s"  rand_cov_test 1 2 "$s" "${RC[@]}"; done
  for s in $(seq 1 20); do run_case rand "rand_ram_d4_s$s"  rand_cov_test 1 4 "$s" "${RC[@]}"; done
  for s in $(seq 1 20); do run_case rand "rand_ram_d6_s$s"  rand_cov_test 1 6 "$s" "${RC[@]}"; done
  for s in $(seq 1 10); do run_case rand "rand_ram_d1_s$s"  rand_cov_test 1 1 "$s" "${RC[@]}"; done
  for s in $(seq 1 20); do run_case rand "rand_orig_d2_s$s" rand_cov_test 0 2 "$s" "${RC[@]}"; done
  echo "== deep: rand_deep_test"
  for s in $(seq 1 20); do run_case deep "deep_ram_d4_s$s" rand_deep_test 1 4 "$s" "${RC[@]}"; done
  for s in $(seq 1 20); do run_case deep "deep_ram_d6_s$s" rand_deep_test 1 6 "$s" "${RC[@]}"; done
else
  for s in $(seq 1 10); do run_case rand "rand_ram_d2_s$s" rand_cov_test 1 2 "$s" "${RC[@]}"; done
fi

# ------------------------------------------------------------- reports
L=$LOG
sets=()
for c in ram_d1 ram_d2 ram_d4 ram_d6 orig_d2; do
  ls "$L"/*_"${c}"_*.log > /dev/null 2>&1 && sets+=("$c=$L/*_${c}_*.log")
done
python3 "$ROOT/tools/merge_cov.py" -o "$LOG/coverage" "${sets[@]}" > /dev/null
T1=$(date +%s)
echo
python3 "$ROOT/tools/report.py" "$CSV" "$LOG/coverage.csv" -o "$LOG/results.md" \
  --meta "Mode=$MODE" --meta "Simulator=$SIMVER" --meta "Host=$(hostname)" \
  --meta "Date=$(date '+%Y-%m-%d %H:%M %Z')" --meta "Wall time=$(( (T1 - T0) / 60 )) min $(( (T1 - T0) % 60 )) s"
status=$?
sed -n '/^## Functional coverage/,$p' "$LOG/results.md" | sed -n '5,20p'
echo "   results page: logs/regress/results.md"
cd "$ROOT" && tar czf regress_logs.tgz logs/regress && echo "== logs packed: $ROOT/regress_logs.tgz"
rm -rf "$RUN"
exit $status
