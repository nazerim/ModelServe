#!/usr/bin/env bash
# One driver for three measurements:
#  1. KV bytes/token, by booting the SAME config at two context sizes
#  2. image latency with the vision tower on GPU
#  3. image latency with the vision tower on CPU (--no-mmproj-offload) + VRAM freed
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"

boot() {  # boot <logfile> <ctx> [extra args...]
  local log="$1" ctx="$2"; shift 2
  pkill -f 'llama[-]server' 2>/dev/null; sleep 3
  CTX="$ctx" SPLIT=19,6 NGL=99 KV=q8_0 setsid nohup ./serve.sh "$@" > "$log" 2>&1 </dev/null &
  for _ in $(seq 1 45); do
    sleep 4
    curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"' && return 0
    grep -qiE 'out of memory|failed to allocate|^usage:|allowed values' "$log" && return 1
  done
  return 1
}
vram() {  # prints "<5070Ti> <3080>" MiB used  (nvidia-smi index 1 then 0)
  local a b
  b=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 1p)   # 3080
  a=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 2p)   # 5070 Ti
  echo "${a:-?} ${b:-?}"
}

echo "### 1. KV calibration (q8_0, split 19,6, -ngl 99)"
boot mm-a.log 65536 && echo "  CTX=65536  5070Ti/3080 used: $(vram) MiB"
boot mm-b.log 81920 && echo "  CTX=81920  5070Ti/3080 used: $(vram) MiB"

echo "### 2. vision tower ON GPU (default) @ CTX=81920"
python3 img-bench.py "mmproj-on-GPU"

echo "### 3. vision tower ON CPU (--no-mmproj-offload) @ CTX=81920"
if boot mm-c.log 81920 --no-mmproj-offload; then
  echo "  VRAM now: $(vram) MiB   <- compare with step 2"
  python3 img-bench.py "mmproj-on-CPU"
else
  echo "  boot with --no-mmproj-offload FAILED:"; tail -3 mm-c.log | cut -c1-160
fi
pkill -f 'llama[-]server' 2>/dev/null; true
