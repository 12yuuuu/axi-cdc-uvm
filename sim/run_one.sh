#!/bin/bash
# Copyright 2026 Kuan-Yu Liu
# SPDX-License-Identifier: Apache-2.0
# Run (or re-run) one test, for example to reproduce a failing seed.
#   bash sim/run_one.sh <test> <seed> [USE_RAM] [LOG_DEPTH] [plusargs...]
#   bash sim/run_one.sh rand_test 17 1 2 +RAND_CLOCKS +VCD
# Log (and waves.vcd with +VCD) go to logs/one/.
source "$(dirname "$0")/common.sh"
[ $# -lt 2 ] && { sed -n '4,7p' "$0"; exit 1; }
test=$1; seed=$2; ram=${3:-1}; depth=${4:-2}
shift $(( $# < 4 ? $# : 4 ))
extra=("$@")
[[ " ${extra[*]} " == *" +VCD "* ]] && extra=(-access +r "${extra[@]}")
name="${test}_seed${seed}_ram${ram}_d${depth}"
RUN=/tmp/$USER/axi_cdc_uvm/one/ram${ram}_d${depth}
LOG=$ROOT/logs/one
mkdir -p "$RUN" "$LOG" && cd "$RUN" || exit 1
rm -f waves.vcd
xrun_tb "$LOG/$name.log" "$ram" "$depth" "$test" "$seed" "${extra[@]}"
grep -E '\[TB\]|\[RAND\]|\[FILL\]|\[MON\]|\[SB\]' "$LOG/$name.log" | sed -e 's/^UVM_INFO [^@]*@ [0-9]*: //' -e 's/^/  /' | cut -c1-220
v=$(verdict "$LOG/$name.log" pass)
echo "=> $v   (log: logs/one/$name.log)"
[ "$v" = FAIL ] && grep -m6 -E '\*E,|\*F,|UVM_(ERROR|FATAL) [^:]' "$LOG/$name.log" | grep -v IMPDLL | cut -c1-220 | sed 's/^/   /'
[ -f waves.vcd ] && mv waves.vcd "$LOG/$name.vcd" && echo "   waves: logs/one/$name.vcd"
