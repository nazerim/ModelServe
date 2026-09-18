#!/usr/bin/env bash
# Boot at a fixed config once per KV-cache type, probe each, then compare.
#   ./kv-sweep.sh q8_0 q4_0          (first listed = reference)
# Override with CTX / SPLIT env.
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"
CTX_="${CTX:-81920}"; SPLIT_="${SPLIT:-19,6}"

for kv in "$@"; do
  echo "=========== KV=$kv  CTX=$CTX_  SPLIT=$SPLIT_ ==========="
  pkill -f 'llama[-]server' 2>/dev/null; sleep 3
  CTX="$CTX_" SPLIT="$SPLIT_" NGL=99 KV="$kv" \
    setsid nohup ./serve.sh > "kv-$kv.log" 2>&1 </dev/null &
  ok=""
  for _ in $(seq 1 45); do
    sleep 4
    curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"' && { ok=1; break; }
    grep -qiE 'out of memory|failed to allocate' "kv-$kv.log" && break
  done
  [ -n "$ok" ] || { echo "  boot FAILED:"; grep -iE 'out of memory|failed to allocate' "kv-$kv.log" | head -2 | sed 's/^/    /'; continue; }
  echo "  VRAM: 5070Ti=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 2p) MiB  3080=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 1p) MiB"
  timeout 900 python3 kv-probe.py "kv-$kv.json" "$kv" || echo "  probe FAILED for $kv"
done
pkill -f 'llama[-]server' 2>/dev/null
if [ "$#" -ge 2 ]; then
  echo; python3 kv-compare.py "kv-$1.json" "kv-$2.json"
fi
