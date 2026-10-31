#!/usr/bin/env bash
# phase4.sh — the three open questions, at the profile's REAL ceiling, with hard rails.
#
#   Q1 is large context safe to test with the pin at all?
#   Q2 does the pin shift the binding constraint, and is a split rebalance needed to fit more?
#   Q3 is 512/128 still the right batch, or does 1024/256 come back within reach?
#
# Why this is the risk to think about: the pin moves 334.74 MiB of weights off the 3080 and ONTO
# the 5070 Ti (+478 MiB free on the 3080 at 64K, -364 MiB on the 5070 Ti). But the 5070 Ti is the
# display GPU and the card the house margin rule protects. So the pin can plausibly make the
# *other* card the constrained one — a different card failing, on a box that has already lost a
# GPU to a driver/PCIe event once. Nothing here escalates unless the previous stage clears a bar.
#
# Rails:
#   1. both GPUs present AND power limits still 220/275 before every boot. The caps are the
#      mitigation for the recorded fall-off-the-bus event; without them this is a more dangerous
#      machine than the one these ceilings were measured on.
#   2. stop on any round that is not SAFE, or any boot failure. No retries, no probing.
#   3. never exceed 225,280 — already validated 3/3 SAFE without the pin, so every stage here is
#      at or below a known-good footprint. Above that is a decision, not an automatic escalation.
#   4. the batch test also runs at 163,840, where neither batching can fail, so Q3 gets a
#      measured pp answer that does not depend on living at the edge.
#
# Drives win/stability-from-wsl.sh (N identical boots, margin sampled UNDER load, desktop
# baseline captured per boot, verdict per round) rather than a bespoke loop.
set -uo pipefail
cd /home/naz/Projects/ModelServe || exit 1
OT='blk.64.*=CUDA0'
Q8='-ctkd q8_0 -ctvd q8_0'

rail() {
  local gpus lim caps w3080 w5070
  gpus=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
  lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' ')
  echo "  rail: gpus=$gpus power_limits=[ $lim ]"
  [ "$gpus" = "2" ] || { echo "ABORT: both GPUs must be present — stop, do not probe further"; exit 2; }
  # exact per-card watts, resolved by NAME: a substring match on the combined list could be
  # satisfied by the wrong card (3080 at 275 with the 5070 Ti at 250 read as "250 present").
  # 220/275 is the pair safety-tested on the Linux boot; raise it only with evidence behind it.
  caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
  w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
  w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
  { [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; } || { echo "ABORT: caps are ${w3080:-?}/${w5070:-?} W, want 220/275"; exit 2; }
}

LASTMIN=0
run() {   # run <outfile> <label> <extra args...>
  local out="$1" label="$2"; shift 2
  echo; echo "===== $label"
  echo "      EXTRA: $*"
  rail
  local log="/tmp/p4-$(basename "$out" .tsv).out"
  OUT="$out" EXTRA="$*" ./win/stability-from-wsl.sh "${ROUNDS_N:-3}" q3l > "$log" 2>&1
  grep -E 'round [0-9]+ ->|VERDICT' "$log" | sed 's/^/  /'
  # worst-case free and status come from the TSV; pp comes from the server's own log line on stdout
  awk -F'\t' 'NR>1 { printf "  row: round %s ctx=%s batch=%s worst_free=%s MiB gen=%ss %s\n", $2, $4, $6, $8, $9, $10 }' "$out"
  grep -oE 'pp=[0-9]+' "$log" | tail -1 | sed 's/^/  pp ceiling: /' | sed 's/pp=/pp = /'
  LASTMIN=$(awk -F'\t' 'NR>1 && $8+0>0 { if(m==0||$8+0<m) m=$8+0 } END { print m+0 }' "$out")
  local bad; bad=$(awk -F'\t' 'NR>1 && $10!="SAFE" { n++ } END { print n+0 }' "$out")
  echo "  -> nonSAFE=$bad  min worst_free=${LASTMIN} MiB"
  if [ "$bad" != "0" ]; then echo "STOP: $label did not return 3/3 SAFE. Not escalating."; exit 1; fi
}

# Q1 + Q2: the pin at the current ceiling, then with the draft KV quantised as well.
run stability-win-q3l-pin.tsv "T1  225,280 + pin  — does the 5070 Ti survive the moved weights?" "-ot $OT"
[ "${LASTMIN:-0}" -ge 500 ] || { echo "STOP: T1 min worst_free ${LASTMIN} MiB under the 500 MiB floor."; exit 1; }
run stability-win-q3l-pin-q8.tsv "T2  225,280 + pin + q8_0 draft KV — memory payoff at full ctx" "-ot $OT $Q8"

# Q3 at the edge, only if T2 left room.
if [ "${LASTMIN:-0}" -ge 700 ]; then
  run stability-win-q3l-pin-q8-b1024.tsv "T3a 225,280 + pin + q8 + 1024/256 — is faster prefill back?" "-ot $OT $Q8 -Batch 1024 -Ubatch 256"
else
  echo; echo "T3a skipped at full ctx: worst_free ${LASTMIN} MiB < 700 MiB. Q3 answered at 163,840 only."
fi

# Q3 without living at the edge: three batchings at a mid ctx. 2 rounds each is enough because
# nothing here can fail; what is wanted is pp and the batch->VRAM slope.
for b in "512 128" "1024 128" "1024 256"; do
  set -- $b; bb=$1; ub=$2; out="stability-win-q3l-mid-b${bb}x${ub}.tsv"
  echo; echo "===== T3b  163,840 + pin + q8, batch ${bb}/${ub}"
  rail
  local_log="/tmp/p4-mid-${bb}x${ub}.out"
  OUT="$out" EXTRA="-Ctx 163840 -ot $OT $Q8 -Batch $bb -Ubatch $ub" \
    ./win/stability-from-wsl.sh 2 q3l > "$local_log" 2>&1
  grep -E 'round [0-9]+ ->|slowest-gen' "$local_log" | sed 's/^/  /' | head -4
  grep -oE 'pp=[0-9]+' "$local_log" | tail -1 | sed 's/^/  /'
  awk -F'\t' 'NR>1 { printf "  row: batch=%s worst_free=%s MiB\n", $6, $8 }' "$out"
done

echo; echo "===== phase4 complete at $(date +%H:%M:%S)"; rail
