#!/usr/bin/env bash
# phase5.sh — Q2's remedy and Q3's answer, with the same rails as phase4.
#
# Phase 4 measured: pin alone at 225,280 => worst_free 251/305/321 MiB, 0/3 SAFE (baseline unpinned
# is 517). The pin loads the 5070 Ti with the moved weights, and at full context the 5070 Ti is the
# binding card — its KV share is 22.83 KiB/token vs the 3080's 10.35 (+ 3.99 draft). So the fix is
# not "more pin", it is to give the 5070 Ti back its share of the KV, which is what -Split does:
# KV follows the weight split, so lowering CUDA0's fraction moves per-token cost to the 3080 —
# which has room precisely because the pin and the q8_0 draft KV both unloaded it.
#
# T4  candidate config at the existing ceiling: pin + q8_0 draft KV + split 15,10. 2 rounds.
#     Predicted: 5070 Ti recovers ~650 MiB, 3080 spends ~650 and saves ~450 (draft KV f16->q8_0
#     at this size is ~900 -> ~450 MiB). If it clears 400 MiB the pin is viable at full ctx;
#     if it does not, the pin stays a 64K-class speed win and nothing escalates.
# T5  Q3: 512/128 vs 1024/128 vs 1024/256 at 163,840, where no batching can fail. This measures
#     the pp gain and the margin each batching costs, instead of arguing about it.
#
# -lv 4 is in every EXTRA here on purpose: at the default verbosity=3 llama.cpp omits the
# per-device allocation lines, and those are the only evidence of WHERE the memory went.
set -uo pipefail
cd /home/naz/Projects/ModelServe || exit 1
OT='blk.64.*=CUDA0'; Q8='-ctkd q8_0 -ctvd q8_0'

rail() {
  local gpus lim caps w3080 w5070
  gpus=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
  lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' ')
  echo "  rail: gpus=$gpus power_limits=[ $lim ]"
  [ "$gpus" = "2" ] || { echo "ABORT: both GPUs must be present"; exit 2; }
  # exact per-card watts, resolved by NAME (a substring match on the combined list can be
  # satisfied by the wrong card). 220/275 = the pair safety-tested on the Linux boot.
  caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
  w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
  w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
  { [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; } || { echo "ABORT: caps are ${w3080:-?}/${w5070:-?} W, want 220/275"; exit 2; }
}

LASTMIN=0
run() {   # run <rounds> <outfile> <label> <extra...>
  local rounds="$1" out="$2" label="$3"; shift 3
  echo; echo "===== $label"; echo "      EXTRA: $*"
  rail
  local log="/tmp/p5-$(basename "$out" .tsv).out"
  OUT="$out" EXTRA="$*" ./win/stability-from-wsl.sh "$rounds" q3l > "$log" 2>&1
  grep -E 'round [0-9]+ ->|VERDICT' "$log" | sed 's/^/  /'
  awk -F'\t' 'NR>1 { printf "  row: ctx=%s split=%s batch=%s worst_free=%s MiB gen=%ss %s\n", $4, $5, $6, $8, $9, $10 }' "$out"
  LASTMIN=$(awk -F'\t' 'NR>1 && $8+0>0 { if(m==0||$8+0<m) m=$8+0 } END { print m+0 }' "$out")
  # per-device allocations, this time actually present because -lv 4 was passed
  cp -f /mnt/c/ModelServe/logs/server.err.log "/tmp/alloc-$(basename "$out" .tsv).raw" 2>/dev/null
  tr -d '\0\r' < "/tmp/alloc-$(basename "$out" .tsv).raw" > "/tmp/alloc-$(basename "$out" .tsv).log" 2>/dev/null
  grep -E 'model buffer size|KV buffer size|RS buffer size|CUDA0 compute|CUDA1 compute' \
    "/tmp/alloc-$(basename "$out" .tsv).log" 2>/dev/null | sed 's/^.*I *//;s/llama_/  llama_/' | cut -c1-88
  echo "  -> min worst_free = ${LASTMIN} MiB"
}

# Q2 remedy
run 2 stability-win-q3l-pin-q8-s1510.tsv "T4  225,280 + pin + q8 + split 15,10 (candidate)" \
    "-lv 4 -ot $OT $Q8 -Split 15,10"
if [ "${LASTMIN:-0}" -lt 400 ]; then
  echo "  candidate did NOT clear 400 MiB — pin stays a reduced-context speed win; not escalating."
else
  echo "  candidate cleared 400 MiB. Repeating at 3 boots for a SAFE claim."
  run 3 stability-win-q3l-pin-q8-s1510x3.tsv "T4b 225,280 + pin + q8 + split 15,10, 3 boots" \
      "-lv 4 -ot $OT $Q8 -Split 15,10"
fi

# Q3: batching at a context where failure is not on the table
for b in "512 128" "1024 128" "1024 256"; do
  set -- $b
  run 2 "stability-win-q3l-mid-b${1}x${2}.tsv" "T5  163,840 + pin + q8 + split 15,10, batch ${1}/${2}" \
      "-lv 4 -Ctx 163840 -ot $OT $Q8 -Split 15,10 -Batch $1 -Ubatch $2"
done
echo; echo "===== phase5 complete $(date +%H:%M:%S)"; rail
