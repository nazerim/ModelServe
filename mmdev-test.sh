#!/usr/bin/env bash
# Does -mmdev CUDA1 (vision projector pinned to the 3080) beat --no-mmproj-offload?
# Compares at the same ctx the CPU-projector result already measured.
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"

run() {   # run <ctx> <extra args...>
  local ctx="$1"; shift
  echo "=========== CTX=$ctx  $* ==========="
  pkill -f 'llama[-]server' 2>/dev/null; sleep 3
  MM=gpu CTX="$ctx" SPLIT=19,6 NGL=99 KV=q8_0 \
    setsid nohup ./serve.sh "$@" > "md-$ctx.log" 2>&1 </dev/null &
  for _ in $(seq 1 45); do
    sleep 4
    curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"' && break
    grep -qiE 'out of memory|failed to allocate|allowed values|^usage:' "md-$ctx.log" && break
  done
  if ! curl -s --max-time 5 http://127.0.0.1:${PORT:-8000}/health | grep -q '"ok"'; then
    echo "  BOOT FAILED:"; grep -iE 'out of memory|failed to allocate|usage' "md-$ctx.log" | head -2 | cut -c1-150
    return 1
  fi
  echo "  flags: $(pgrep -af 'llama[-]server' | grep -oE '\-mmdev [A-Z0-9]+|no-mmproj-offload|-ctk [a-z0-9_]+|-c [0-9]+' | tr '\n' '|')"
  echo "  VRAM before images (5070Ti / 3080): $(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | tr '\n' ' ')"
  timeout 200 python3 img-bench.py "mmdev@$ctx" 2>&1 | sed -n '3,5p'
  if curl -s --max-time 5 http://127.0.0.1:${PORT:-8000}/health | grep -q '"ok"'; then
    echo "  survived images. gen speed:"
    timeout 200 python3 - <<'PY'
_PORT = __import__("os").environ.get("PORT", "8000")
import json, time, urllib.request
p = {"model": "qwen3.8-27b", "max_tokens": 400, "temperature": 0,
     "messages": [{"role": "user", "content": "Write 250 words on KV cache quantisation."}]}
r = urllib.request.Request("http://127.0.0.1:" + _PORT + "/v1/chat/completions", data=json.dumps(p).encode(),
                           headers={"Content-Type": "application/json"})
t = time.time(); d = json.load(urllib.request.urlopen(r, timeout=300))
n = d["usage"]["completion_tokens"]; print("    %d tok / %.1fs = %.1f tok/s" % (n, time.time()-t, n/(time.time()-t)))
PY
    grep -oE "draft acceptance = [0-9.]+" "md-$ctx.log" 2>/dev/null | tail -1
    return 0
  fi
  echo "  *** CRASHED ON IMAGE at CTX=$ctx ***"; tail -3 "md-$ctx.log" | cut -c1-150; return 1
}

for c in 98304 114688 122880; do
  run "$c" -mmdev CUDA1 && echo "  --> CTX=$c OK with projector on CUDA1" || echo "  --> CTX=$c not usable"
done
pkill -f 'llama[-]server' 2>/dev/null; true
