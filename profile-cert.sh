#!/usr/bin/env bash
# Boot a profile EXACTLY as config.ps1 writes it - no -Split, no -OvTensor, no -KvDraft overrides -
# and sample worst-case free under a novel cold prefill. This is the check that a profile ROW works,
# as opposed to the experiment harness proving a command line works.
#   ./profile-cert.sh q4s
set -uo pipefail
cd /home/naz/Projects/ModelServe
P="${1:?usage: profile-cert.sh <profile>}"
CTXW="${2:-}"                      # optional -Ctx (still honours the profile ceiling if empty)
read -r -a XTRA <<<"${EXTRA:-}"    # extra serve.ps1 args, e.g. EXTRA="-Ubatch 128"
PS=(powershell.exe -NoProfile -ExecutionPolicy Bypass)
HDR=(-H "Authorization: Bearer ${OMLX_API_KEY:-none}")
B=http://172.25.240.1:8000
free_pair() { nvidia-smi --query-gpu=index,memory.free --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' '; }

"${PS[@]}" -File 'C:\ModelServe\win\stop.ps1' >/tmp/pc-stop.log 2>&1
for _ in $(seq 1 25); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${HDR[@]}" "$B/health" 2>/dev/null)" = "000" ] && break
  sleep 2
done
idle="$(free_pair)"; echo "idle free (3080 5070Ti): $idle"
log="/tmp/pc-$P.log"
"${PS[@]}" -File 'C:\ModelServe\win\start.ps1' -P "$P" ${CTXW:+-Ctx "$CTXW"} ${CTXW:+-Ceil "$CTXW"} \
    ${XTRA[@]+"${XTRA[@]}"} -TimeoutSec 240 > "$log" 2>&1 &
ok=0
for i in $(seq 1 70); do
  sleep 3
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "${HDR[@]}" "$B/health" 2>/dev/null)" = "200" ] && { ok=1; break; }
  grep -qiE 'out of memory|failed to allocate|SIGABRT|NOT READY|must be one of' "$log" 2>/dev/null && break
done
if [ "$ok" != 1 ]; then
  echo "BOOT FAILED for profile $P:"; tail -6 "$log" | tr -d '\r' | cut -c1-150; exit 1
fi
echo "booted (profile as written). post-boot free: $(free_pair)"
grep -a "^P=" /mnt/c/ModelServe/logs/server.out.log | tail -1 | tr -d '\r' | cut -c1-118
curl -s --max-time 8 "${HDR[@]}" "$B/props" | grep -oE '"n_ctx":[0-9]+'
curl -s --max-time 8 "${HDR[@]}" "$B/v1/models" | grep -oE '"id":"[^"]+"' | head -1
BASE=$B WORDS="${WORDS:-23777}" ROUNDS=1 MODEL="$P" timeout 300 python3 margin-check.py 2>&1 | tail -4
# The Windows log trails over drvfs, so retry rather than reporting a blank pp (that is exactly how
# a "31 tok/s" warmup line once got into a TSV: the real line had not landed yet and tail -1 picked
# whatever was there).
pp=""; tg=""
for _ in $(seq 1 8); do
  sleep 4
  pp=$(grep -a "prompt eval time" /mnt/c/ModelServe/logs/server.err.log | grep -aE "[0-9]{4,} tokens" | tail -1 | grep -oE "[0-9.]+ tokens per second" | tail -1)
  tg=$(grep -a "eval time = " /mnt/c/ModelServe/logs/server.err.log | grep -aE "/ +[0-9]{3,4} tokens" | grep -oE "[0-9.]+ tokens per second" | tail -3 | tr '\n' ' ')
  [ -n "$pp" ] && [ -n "$tg" ] && break
done
echo "pp=$pp   decode(tail3)=$tg"
