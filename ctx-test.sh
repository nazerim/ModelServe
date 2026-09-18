#!/usr/bin/env bash
# Boot llama-server at a series of context sizes, record per-GPU VRAM after
# load, then run a real generation (a load that succeeds can still OOM during
# prompt processing). Usage: ctx-test.sh [32768 40960 49152 ...]
# Extra llama-server args (e.g. -ctk q8_0 -ctv q8_0) via: EXTRA='-ctk q8_0'
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"
OUT=ctx-test.tsv
printf 'ctx\tkv\tnvidia\tstatus\tvram_5070Ti_mib\tvram_3080_mib\tgen_tps\tnote\n' > "$OUT"
if [ "$#" -eq 0 ]; then set -- 32768 40960 49152; fi

KVLABEL="${EXTRA:-f16-default}"   # was KV -> clobbered the real KV env
for c in "$@"; do
  echo "=========== CTX=$c EXTRA='${EXTRA:-}' ==========="
  pkill -f 'llama[-]server' 2>/dev/null; sleep 3
  CTX="$c" setsid nohup ./serve.sh ${EXTRA:-} > "log-$c.txt" 2>&1 </dev/null &
  ok=""
  for _ in $(seq 1 30); do
    sleep 4
    if curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"'; then ok=1; break; fi
    grep -qiE 'out of memory|CUDA error|failed to allocate|ggml_backend_cuda_buffer' "log-$c.txt" && break
  done
  # 5070 Ti is GPU index 1, 3080 is index 0 in nvidia-smi order
  read -r m3080 m5070 < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr '\n' ' ')
  echo "  health=${ok:-FAIL}  5070Ti=${m5070:-?} MiB  3080=${m3080:-?} MiB"
  note=""
  if [ -z "$ok" ]; then
    note=$(grep -iE 'out of memory|CUDA error|failed to allocate|exception' "log-$c.txt" | head -1 | cut -c1-120)
    printf '%s\t%s\tnvidia\tFAIL\t%s\t%s\t-\t%s\n' "$c" "$KVLABEL" "${m5070:-?}" "${m3080:-?}" "$note" >> "$OUT"
    continue
  fi
  gen=$(python3 - "$c" <<'PY'
_PORT = __import__("os").environ.get("PORT", "8000")
import json, sys, time, urllib.request
p = {"model": "qwen3.8-27b", "max_tokens": 300, "temperature": 0, "messages": [
     {"role": "user", "content": "Write 200 words about memory bandwidth."}]}
req = urllib.request.Request("http://127.0.0.1:" + _PORT + "/v1/chat/completions",
                             data=json.dumps(p).encode(), headers={"Content-Type": "application/json"})
try:
    t = time.time(); d = json.load(urllib.request.urlopen(req, timeout=300))
    n = d["usage"]["completion_tokens"]; dt = time.time() - t
    print("%.1f" % (n / dt))
except Exception as e:
    print("ERR %s" % str(e)[:60])
PY
)
  echo "  generation: $gen tok/s"
  note=$(grep -icE 'unused tensor blk.64' "log-$c.txt" | sed 's/^/mtp_unused=/')
  printf '%s\t%s\tnvidia\tOK\t%s\t%s\t%s\t%s\n' "$c" "$KVLABEL" "${m5070:-?}" "${m3080:-?}" "$gen" "$note" >> "$OUT"
done
pkill -f 'llama[-]server' 2>/dev/null
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
