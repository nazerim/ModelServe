#!/usr/bin/env bash
# Stability test: identical boot + identical load, N times.
# This is the experiment the crash log was missing: a single pass at 705 MiB "SAFE" was
# followed by an identical repeat that reset the host. One clean run proves nothing.
#   ./stability.sh [ROUNDS=3] [MODEL_ALIAS=qwen3.8-27b]
set -uo pipefail
cd "$(dirname "$0")"
N="${1:-3}"; alias_model="${2:-qwen3.8-27b}"
OUT=stability.tsv
printf 'round\tdesktop_5070Ti_mib\tctx\tsplit\tworst_free\tmin_gen_s\tstatus\n' > "$OUT"

for i in $(seq 1 "$N"); do
  pkill -9 -f 'llama[-]server' 2>/dev/null; sleep 5
  # baseline FIRST: without this, a margin number is uninterpretable (the desktop swung
  # 961 -> 1,721 MiB on this box and flipped a "471 MiB SAFE" reading to 183)
  desk=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 2p)
  ctx=$(Q=q3 DRY=1 ./serve.sh 2>/dev/null | sed -nE 's/.*CTX=([0-9]+).*/\1/p' | head -1)
  sp=$(Q=q3 DRY=1 ./serve.sh 2>/dev/null | sed -nE 's/.*SPLIT=([0-9.,]+).*/\1/p' | head -1)
  echo "===== round $i  (desktop baseline ${desk} MiB, ctx=$ctx split=$sp, caps $(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' '/' ))"
  Q=q3 timeout 400 ./start.sh >"/tmp/stab-$i.log" 2>&1
  if ! grep -q ready "/tmp/stab-$i.log"; then
    echo "  BOOT FAILED"; tail -2 "/tmp/stab-$i.log" | sed 's/^/    /'
    printf '%s\t%s\t%s\t%s\t-\t-\tBOOTFAIL\n' "$i" "$desk" "$ctx" "$sp" >> "$OUT"; continue
  fi
  res=$(MODEL="$alias_model" timeout 900 python3 margin-check.py 2>&1)
  worst=$(grep -oE 'WORST-CASE FREE = [0-9]+' <<<"$res" | grep -oE '[0-9]+')
  slow=$(grep -oE 'gen [0-9]: [0-9]+ tok in [0-9.]+' <<<"$res" | awk '{print $NF}' | sort -rn | head -1)
  st=$(grep -oE '(SAFE|MARGINAL|UNSAFE)' <<<"$res" | tail -1)
  echo "  round $i: worst free=${worst:-?} MiB  slowest-gen=${slow:-?}s  -> ${st:-?}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$desk" "$ctx" "$sp" "${worst:-?}" "${slow:-?}" "${st:-?}" >> "$OUT"
done
echo; echo "  GPU state after test: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>&1 | tr '\n' ' ')"
echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
u=$(awk -F'\t' 'NR>1 && $7=="SAFE"{n++} END{print n+0}' "$OUT"); t=$(awk 'END{print NR-1}' "$OUT")
echo "VERDICT: $u/$t rounds SAFE"
