#!/usr/bin/env bash
# What does a smaller prompt batch cost? -b/-ub shrink the pp compute buffer (which is
# what OOMs first), buying context and safety margin - but they also throttle prompt
# processing, which is the cost an agent pays on a long cold ingest.
# Measures pp tok/s for each config from the server's own timing line.
#   ./pp-check.sh "CTX=212992" "EXTRA=-b 1024 -ub 256" ...
set -uo pipefail
cd "$(dirname "$0")"
CTX_="${CTX:-212992}"; SPLIT_="${SPLIT:-18,7}"; Q_="${Q:-Q3_K_XL}"

measure() {   # measure <label> <extra args...>
  local label="$1"; shift
  pkill -f 'llama[-]server' 2>/dev/null; sleep 4
  local log="pp-$label.log"
  MODEL="$HOME/.models/Qwen3.8-27B-UD-$Q_.gguf" CTX="$CTX_" SPLIT="$SPLIT_" KV=q8_0 MM=cpu \
    NGL=99 CEIL=262144 setsid nohup ./serve.sh "$@" > "$log" 2>&1 </dev/null &
  for _ in $(seq 1 45); do
    sleep 3; curl -s --max-time 5 http://127.0.0.1:8000/health 2>/dev/null | grep -q '"ok"' && break
  done
  curl -s --max-time 5 http://127.0.0.1:8000/health | grep -q ok || { echo "  $label: boot failed"; return; }
  local pp
  pp=$(timeout 600 python3 - "$log" <<'PY'
import json, os, sys, time, urllib.request
log = sys.argv[1]
filler = ("The quick brown fox jumps over the lazy dog while considering KV cache "
          "quantisation, hybrid linear attention, and memory bandwidth. " * 1500)
p = {"model": "qwen3.8-27b", "max_tokens": 8, "temperature": 0,
     "messages": [{"role": "user", "content": filler + "\n\nReply with just: ok"}]}
r = urllib.request.Request("http://127.0.0.1:" + os.environ.get("PORT", "8000") + "/v1/chat/completions",
                           data=json.dumps(p).encode(), headers={"Content-Type": "application/json"})
t = time.time(); d = json.load(urllib.request.urlopen(r, timeout=580))
n = d["usage"]["prompt_tokens"]
time.sleep(2)
txt = open(log, errors="replace").read()
import re
m = re.findall(r"prompt eval time =.*?/\s*(\d+) tokens \(.*?[\s(]([\d.]+) tokens per second\)", txt)
print("%s|%s" % (n, m[-1][1] if m else "?"))
PY
)
  echo "  $label: prompt_tokens=${pp%%|*}  pp=${pp##*|} tok/s"
}

echo "### CTX=$CTX_ split=$SPLIT_ quant=$Q_"
measure "default-batch"
measure "b1024-ub256" -b 1024 -ub 256
measure "b512-ub128"   -b 512  -ub 128
pkill -f 'llama[-]server' 2>/dev/null; true
