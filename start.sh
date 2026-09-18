#!/usr/bin/env bash
# Start the server detached; log -> server.log next to this script. Waits for the model to
# actually load (a 96K ctx takes ~35 s, not the 20 s a fixed sleep assumes).
# Env: PORT, and everything serve.sh reads (CTX SPLIT NGL KV MM HOST NP).
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
cd "$(dirname "$0")"
PORT="${PORT:-8000}"
pkill -f 'llama[-]server' 2>/dev/null || true
sleep 3
setsid nohup ./serve.sh >server.log 2>&1 </dev/null &
for i in $(seq 1 60); do
  sleep 3
  h=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/health" 2>/dev/null)
  case "$h" in
    *'"ok"'*)  echo "ready: $h  (UI http://127.0.0.1:$PORT/)"; exit 0 ;;
    *health_not_supported*) [ "$i" -gt 6 ] && { echo "ready (health_not_supported): $h"; exit 0; } ;;
  esac
  grep -qiE 'out of memory|failed to allocate|SIGABRT|Segmentation' server.log && break
done
echo "NOT READY after $((i * 3))s — last log lines:" >&2
tail -6 server.log | cut -c1-170 >&2
exit 1
