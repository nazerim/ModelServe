#!/usr/bin/env bash
# Boot the server once per "ENV=... ENV=..." spec, record VRAM + throughput.
#   ./sweep.sh "CTX=81920 KV=q8_0 NGL=99 SPLIT=15,10" "CTX=81920 KV=q8_0 SPLIT=17,8"
# Args order matters: llama.cpp --tensor-split is CUDA0,CUDA1 = 5070Ti,3080.
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"
OUT=sweep.tsv
printf 'ctx\tsplit\tngl\tkv\tstatus\tused_5070Ti\tused_3080\tfree_5070Ti\tfree_3080\ttoks\n' > "$OUT"

for spec in "$@"; do
  read -ra words <<< "$spec"   # specs are literal KEY=val words; no eval needed
  c=""; s=""; n="99"; k=""; kvlabel="f16"
  for w in "${words[@]}"; do
    case "$w" in
      CTX=*)   c="${w#*=}" ;;
      SPLIT=*) s="${w#*=}" ;;
      NGL=*)   n="${w#*=}" ;;
      KV=*)    k="${w#*=}"; kvlabel="$k" ;;
    esac
  done
  echo "=========== CTX=$c SPLIT=${s:-default} NGL='$n' KV='$k' ==========="
  pkill -f 'llama[-]server' 2>/dev/null; sleep 3
  tag="${c}_${s:-dflt}_${n:-auto}_${k:-f16}"
  CTX="$c" SPLIT="$s" NGL="$n" KV="$k" \
    setsid nohup ./serve.sh > "sweep-$tag.log" 2>&1 </dev/null &
  ok=""
  for _ in $(seq 1 40); do
    sleep 4
    curl -sS --max-time 5 http://127.0.0.1:${PORT:-8000}/health 2>/dev/null | grep -q '"ok"' && { ok=1; break; }
    grep -qiE 'out of memory|failed to allocate' "sweep-$tag.log" && break
  done
  # nvidia-smi order: index0 = 3080, index1 = 5070 Ti
  # free comes from nvidia-smi's OWN memory.free, not total-used: the latter
  # ignores driver-reserved memory and overstates headroom by ~300 MiB on the 5070 Ti
  read -r u3080 f3080 < <(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | sed -n 1p | tr ',' ' ')
  read -r u5070 f5070 < <(nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | sed -n 2p | tr ',' ' ')
  echo "  health=${ok:-FAIL}  5070Ti(16303) used=${u5070:-?} free=${f5070:-?}  3080(10240) used=${u3080:-?} free=${f3080:-?}"
  if [ -z "$ok" ]; then
    grep -iE 'out of memory|failed to allocate' "sweep-$tag.log" | head -2 | sed 's/^/    /'
    printf '%s\t%s\t%s\t%s\tFAIL\t%s\t%s\t%s\t%s\t-\n' "$c" "$s" "$n" "$kvlabel" "$u5070" "$u3080" "$f5070" "$f3080" >> "$OUT"
    continue
  fi
  toks=$(python3 - <<'PY'
_PORT = __import__("os").environ.get("PORT", "8000")
import json, time, urllib.request
p = {"model": "qwen3.8-27b", "max_tokens": 300, "temperature": 0,
     "messages": [{"role": "user", "content": "Write 200 words about memory bandwidth."}]}
r = urllib.request.Request("http://127.0.0.1:" + _PORT + "/v1/chat/completions", data=json.dumps(p).encode(),
                           headers={"Content-Type": "application/json"})
try:
    t = time.time(); d = json.load(urllib.request.urlopen(r, timeout=300))
    n = d["usage"]["completion_tokens"]; print("%.1f" % (n / (time.time() - t)))
except Exception as e:
    print("ERR")
PY
)
  echo "  gen: $toks tok/s"
  printf '%s\t%s\t%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\n' "$c" "$s" "$n" "$kvlabel" "$u5070" "$u3080" "$f5070" "$f3080" "$toks" >> "$OUT"
done
pkill -f 'llama[-]server' 2>/dev/null
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
