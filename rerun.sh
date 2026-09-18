#!/usr/bin/env bash
# Fresh, isolated re-measurement. One cell = one boot, its own uniquely named log,
# and a verified return to idle VRAM before AND after, so no result can be contaminated
# by a leftover process or a stale file (the bug that made the previous run unreliable:
# ctx-test.sh names logs log-<ctx>.txt, so re-testing a size overwrites the old evidence).
#
#   ./rerun.sh                          # default matrix
#   ./rerun.sh "IQ4_XS 18,7 196608"     # or explicit "QUANT SPLIT CTX" cells
set -uo pipefail
cd "$(dirname "$0")"
M="${M:-$HOME/.models}"
OUT=rerun.tsv
printf 'cell\tquant\tsplit\tctx\tstatus\tfree_5070Ti\tfree_3080\ttok_s\tmtp\tnote\n' > "$OUT"
BASE_5070=900; BASE_3080=120        # observed idle: ~512 and ~28 MiB used

freeof() {   # freeof <nvidia-smi index 1-based>  -> MiB or ERR
  local v
  v=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | sed -n "$1p" | tr -d ' ')
  case "$v" in
    ''|*[!0-9]*) echo "ERR" ;;
    *) if [ "$v" -gt 17000 ] || [ "$v" -lt 0 ]; then echo "ERR"; else echo "$v"; fi ;;
  esac
}


wait_idle() {   # block until both GPUs are back at baseline, or say so
  for _ in $(seq 1 20); do
    u3080=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 1p)
    u5070=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 2p)
    [ "$u3080" -le "$BASE_3080" ] && [ "$u5070" -le "$BASE_5070" ] && return 0
    sleep 3
  done
  echo "    !! not idle (3080=${u3080} 5070Ti=${u5070}) - results below are UNTRUSTWORTHY"
  return 1
}

cell() {  # cell <label> <quant> <split> <ctx>
  local label="$1" q="$2" s="$3" c="$4"
  local id="${q}_${s/,/_}_$c"
  local log="run-$id.log"
  pkill -f 'llama[-]server' 2>/dev/null
  wait_idle || return 1
  echo "=========== $label   [$q split=$s ctx=$c]"
  MODEL="$M/Qwen3.8-27B-UD-$q.gguf" CTX="$c" SPLIT="$s" KV=q8_0 MM=cpu NGL=99 CEIL=262144 \
    setsid nohup ./serve.sh > "$log" 2>&1 </dev/null &
  local ok="" i
  for i in $(seq 1 45); do
    sleep 4
    curl -sS --max-time 5 http://127.0.0.1:8000/health 2>/dev/null | grep -q '"ok"' && { ok=1; break; }
    grep -qiE 'out of memory|failed to allocate' "$log" && break
  done
  # SELF-CHECK: the boot must report the context we asked for, or the harness is lying
  local got_ctx; got_ctx=$(grep -oE 'n_ctx_slot = [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
  local mtp; mtp=$(grep -c 'unused tensor blk.64' "$log")
  if [ -n "$ok" ] && [ "${got_ctx:-}" != "$c" ]; then
    echo "  MISMATCH: asked CTX=$c but server reports n_ctx_slot=${got_ctx:-?} - harness bug, not a result"
    printf '%s\t%s\t%s\t%s\tMISMATCH\t-\t-\t-\t-\tgot=%s\n' "$label" "$q" "$s" "$c" "${got_ctx:-none}" >> "$OUT"
    pkill -f 'llama[-]server' 2>/dev/null; sleep 5; return 0
  fi
  f5070=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sed -n 2p)
  f3080=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | sed -n 1p)
  if [ -z "$ok" ]; then
    local note; note=$(grep -oiE 'allocating [0-9.]+ MiB on device [0-9]' "$log" | tail -1)
    echo "  FAIL  free(5070Ti/3080)=${f5070}/${f3080} MiB  ${note:-no OOM line}"
    printf '%s\t%s\t%s\t%s\tFAIL\t%s\t%s\t-\t%s\t%s\n' "$label" "$q" "$s" "$c" "$f5070" "$f3080" "$mtp" "$note" >> "$OUT"
    pkill -f 'llama[-]server' 2>/dev/null; sleep 5; return 0
  fi
  local sp
  sp=$(timeout 300 python3 - "$c" <<'PY' 2>/dev/null || echo ERR
import json, os, sys, time, urllib.request
B = "http://127.0.0.1:" + os.environ.get("PORT", "8000")
p = {"model": "qwen3.8-27b", "max_tokens": 300, "temperature": 0,
     "messages": [{"role": "user", "content": "Write 220 words about memory bandwidth."}]}
r = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(p).encode(),
                           headers={"Content-Type": "application/json"})
t = time.time(); d = json.load(urllib.request.urlopen(r, timeout=280))
n = d["usage"]["completion_tokens"]; print("%.1f" % (n / (time.time() - t)))
PY
)
  f5070=$(freeof 2); f3080=$(freeof 1)
  local acc; acc=$(grep -oE "draft acceptance = [0-9.]+" "$log" | tail -1 | grep -oE '[0-9.]+$')
  echo "  OK    free(5070Ti/3080)=${f5070}/${f3080} MiB   ${sp} tok/s   mtp_unused=$mtp accept=${acc:-n/a}"
  printf '%s\t%s\t%s\t%s\tOK\t%s\t%s\t%s\t%s\taccept=%s\n' "$label" "$q" "$s" "$c" "$f5070" "$f3080" "$sp" "$mtp" "$acc" >> "$OUT"
}

if [ "$#" -gt 0 ]; then
  for spec in "$@"; do read -r q s c <<< "$spec"; cell "$q@$s/$c" "$q" "$s" "$c"; done
else
  cell "IQ4_XS probe 192K"   IQ4_XS   18,7 188416
  cell "IQ4_XS probe 196K"   IQ4_XS   18,7 196608
  cell "Q3_K_XL current def" Q3_K_XL  18,7 196608
  cell "Q4_K_XL 122K"        Q4_K_XL  18,7 122880
  cell "Q4_K_XL 131K"        Q4_K_XL  18,7 131072
fi
pkill -f 'llama[-]server' 2>/dev/null; sleep 5
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
