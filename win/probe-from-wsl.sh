#!/usr/bin/env bash
# probe-from-wsl.sh — prove the WSL -> native-Windows path works, and say WHICH layer is
# broken when it does not.
#
# The whole point of the win/ track is that pi (inside WSL) talks to a server running on
# Windows. That crosses three independent boundaries, and each one fails differently:
#
#   1. routing    — can WSL reach the host's vEthernet address at all?
#   2. firewall   — Windows treats the WSL adapter as an unclassified (=> Public) network, so
#                   inbound is dropped by default: it looks like a dead server but isn't.
#   3. auth       — llama-server needs the bearer key; a 401 means the key differs between
#                   the Windows-side LLAMA_API_KEY and pi's, which is invisible from `curl
#                   /health` because /health is unauthenticated.
#
# So: test TCP first (routes+firewall), then HTTP, then an authenticated completion.
#
#   ./probe-from-wsl.sh                  # auto-discover the host IP, port 8000
#   HOST=172.25.240.1 PORT=8000 ./probe-from-wsl.sh
#   KEY=... ./probe-from-wsl.sh          # default: $OMLX_API_KEY, never echoed
set -uo pipefail

HOST="${HOST:-$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')}"
PORT="${PORT:-8000}"
KEY="${KEY:-${OMLX_API_KEY:-}}"
B="http://${HOST}:${PORT}"
PATH_TIMEOUT="${PATH_TIMEOUT:-5}"
[ -n "$HOST" ] || { echo "could not find a default gateway - is WSL's network up?" >&2; exit 1; }

echo "host (WSL default gateway / Windows vEthernet address): $HOST:$PORT"
echo "key: $([ -n "$KEY" ] && echo "present (${#KEY} chars, from ${KEY:+env})" || echo 'ABSENT — authenticated calls will 401')"
echo "note: this IP is assigned per boot and CAN change; re-run this script after a reboot"
echo "      instead of trusting a value pasted into a config file."

fail=0
# --- 1. TCP: routing + firewall -------------------------------------------------------
if timeout "$PATH_TIMEOUT" bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>/dev/null; then
  exec 3>&- 2>/dev/null
  echo "tcp      OPEN"
else
  echo "tcp      CLOSED/unreachable  <-- routing or firewall" >&2
  echo "  server listening?  win\\check.ps1 (look at 'listener' and 'health')" >&2
  echo "  firewall rule?     run elevated on Windows:" >&2
  echo "    New-NetFirewallRule -DisplayName 'ModelServe llama-server (WSL only)' -Direction Inbound \\" >&2
  echo "      -Action Allow -Protocol TCP -LocalPort $PORT -Profile Any" >&2
  fail=1
fi

# --- 2. HTTP /health (unauthenticated by design) --------------------------------------
h=$(curl -s --max-time "$PATH_TIMEOUT" "$B/health" 2>/dev/null)
case "$h" in
  *'"ok"'*)               echo "health   $h  (model loaded)" ;;
  *'loading'*)           echo "health   $h  (still loading — wait and re-run)" ;;
  '')                     echo "http     no answer on $B/health" >&2; [ "$fail" = 0 ] && fail=1 ;;
  *)                      echo "http     $h" ;;
esac

# --- 3. auth + which profile is actually live -----------------------------------------
m=$(curl -s --max-time "$PATH_TIMEOUT" ${KEY:+-H "Authorization: Bearer $KEY"} "$B/v1/models" 2>/dev/null)
ids=$(printf '%s' "$m" | python3 -c 'import json,sys
try: print(", ".join(x["id"] for x in json.load(sys.stdin).get("data",[])))
except Exception: print("")' 2>/dev/null)
if [ -n "$ids" ]; then
  echo "models   $ids"
  ctx=$(printf '%s' "$m" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin).get("data",[{}])[0]
    print(d.get("llama",{}).get("n_ctx") or d.get("context") or "")
except Exception: print("")' 2>/dev/null)
  [ -n "$ctx" ] && echo "n_ctx    $ctx  (pi's entry must not declare more than this)"
else
  echo "models   nothing readable" >&2
  echo "  401 -> the key mismatch: Windows LLAMA_API_KEY vs pi's key are not the same value." >&2
  echo "         check scope: setx LLAMA_API_KEY <key> (a terminal-only export dies with the" >&2
  echo "         shell and never reaches a scheduled launch)." >&2
  [ "$fail" = 0 ] && fail=1
fi

# --- 4. one real completion, timed ---------------------------------------------------
if [ -n "$ids" ]; then
  body="{\"model\":\"${ids%%,*}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: windows-native-ok\"}],\"max_tokens\":8,\"temperature\":0}"
  t0=$(date +%s%N)
  r=$(curl -s --max-time 120 ${KEY:+-H "Authorization: Bearer $KEY"} -H 'Content-Type: application/json' \
        -d "$body" "$B/v1/chat/completions" 2>/dev/null)
  wall=$(( ($(date +%s%N) - t0) / 1000000 ))   # ns -> ms; %s%3N is not portable enough to trust
  echo "$r" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    o = json.loads(raw)
except Exception:
    print("complete  unparseable: " + raw[:140]); sys.exit(0)
if "error" in o:
    print("complete  server error: " + str(o["error"])[:140]); sys.exit(0)
try:
    content = o["choices"][0]["message"]["content"]
except Exception:
    print("complete  no choices in response: " + raw[:140]); sys.exit(0)
if not content:
    # A thinking model answers with empty `content` and puts the text in reasoning_content, so
    # an empty string here is normal, not a failure - say which one it was.
    rc = (o["choices"][0]["message"].get("reasoning_content") or "")
    content = "<empty content; reasoning_content=" + (repr(rc)[:60] + ">" if rc else "also empty, likely max_tokens too small for thinking>")
print("complete  " + str(content)[:120])
t, u = o.get("timings", {}), o.get("usage", {})
pt, ct = u.get("prompt_tokens", 0), u.get("completion_tokens", 0)
if t.get("prompt_ms"):    print("           server: prompt %d tok @ %.0f tok/s" % (pt, pt / (t["prompt_ms"] / 1000.0)))
if t.get("predicted_ms"): print("           server: %d tok generated @ %.1f tok/s" % (ct, ct / (t["predicted_ms"] / 1000.0)))
' 
  echo "           wall ${wall} ms (includes HTTP + queue, so it is >= the server's own number)"
fi

echo
[ "$fail" = 0 ] && echo "VERDICT: WSL can serve-verify against the Windows llama-server." || echo "VERDICT: not reachable/authenticated yet — see the !! lines above."
exit "$fail"
