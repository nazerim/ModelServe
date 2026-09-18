#!/usr/bin/env bash
# Find each candidate quant's real context ceiling with the production config.
# Stops climbing a quant as soon as a size fails (a pass above a failure would be
# allocation luck, not capacity - we saw that non-monotonicity with -mmdev).
#   ./iq-ladder.sh Qwen3.8-27B-UD-IQ4_XS.gguf Qwen3.8-27B-UD-Q3_K_XL.gguf
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"
SIZES="${SIZES:-196608 229376 262144}"
MODELS="${MODELS:-$HOME/.models}"
OUT=iq-ladder.tsv
printf 'quant\tctx\tstatus\tvram_5070Ti\tvram_3080\tfree_5070Ti\tfree_3080\ttok_s\n' > "$OUT"

for model in "$@"; do
  [ -f "$MODELS/$model" ] || { echo "SKIP $model (not in $MODELS)"; continue; }
  echo "############ $model"
  for c in $SIZES; do
    pkill -f 'llama[-]server' 2>/dev/null; sleep 3
    MODEL="$MODELS/$model" CTX="$c" SPLIT=19,6 NGL=99 KV=q8_0 MM=cpu \
      setsid nohup ./serve.sh > "lad-$(basename "$model" .gguf)-$c.log" 2>&1 </dev/null &
    log="lad-$(basename "$model" .gguf)-$c.log"
    ok=""
    for _ in $(seq 1 60); do
      sleep 4
      curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"' && { ok=1; break; }
      grep -qiE 'out of memory|failed to allocate|allowed values|usage:' "$log" && break
    done
    # nvidia-smi order: index 0 = 3080, index 1 = 5070 Ti
    read -r u3080 f3080 < <(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | sed -n 1p | tr ',' ' ')
    read -r u5070 f5070 < <(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | sed -n 2p | tr ',' ' ')
    if [ -z "$ok" ]; then
      echo "  CTX=$c FAIL   5070Ti used=$u5070 free=$f5070 | 3080 used=$u3080 free=$f3080"
      grep -iE 'out of memory|failed to allocate' "$log" | head -1 | cut -c1-140 | sed 's/^/      /'
      printf '%s\t%s\tFAIL\t%s\t%s\t%s\t%s\t-\n' "$model" "$c" "$u5070" "$u3080" "$f5070" "$f3080" >> "$OUT"
      break
    fi
    sp=$(timeout 200 python3 - <<'PY' 2>/dev/null || echo ERR
_PORT = __import__("os").environ.get("PORT", "8000")
import json, time, urllib.request
p = {"model": "qwen3.8-27b", "max_tokens": 400, "temperature": 0,
     "messages": [{"role": "user", "content": "Write 250 words on KV cache quantisation."}]}
r = urllib.request.Request("http://127.0.0.1:" + _PORT + "/v1/chat/completions", data=json.dumps(p).encode(),
                           headers={"Content-Type": "application/json"})
t = time.time(); d = json.load(urllib.request.urlopen(r, timeout=300))
n = d["usage"]["completion_tokens"]; print("%.1f" % (n / (time.time() - t)))
PY
)
    echo "  CTX=$c OK     5070Ti free=$f5070 | 3080 free=$f3080 | $sp tok/s"
    printf '%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\n' "$model" "$c" "$u5070" "$u3080" "$f5070" "$f3080" "$sp" >> "$OUT"
  done
done
pkill -f 'llama[-]server' 2>/dev/null
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
