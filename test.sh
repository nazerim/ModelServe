#!/usr/bin/env bash
# Smoke-test a running serve.sh (same directory).
#
# Checks, in order:
#   0. that the flags actually reached the process (a stray blank line after a
#      trailing backslash silently truncates an `exec` command - that cost us
#      MTP once, so verify rather than trust)
#   1. /health + /v1/models advertise multimodal
#   2. text throughput (expect ~50 tok/s with MTP, ~26 without)
#   3. MTP draft acceptance the server recorded for that generation
#   4. vision, on two solid-colour PNGs built here with valid CRCs
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
PORT="${PORT:-8000}"; B="${BASE:-http://127.0.0.1:$PORT}"   # BASE=... to test the native-Windows server

# SERVER_LOG is parsed for the MTP acceptance line. For the Windows-hosted server, point it at
# the NTFS log via the mount:  SERVER_LOG=/mnt/c/ModelServe/logs/server.err.log
export SERVER_LOG="${SERVER_LOG:-$ROOT/server.log}"

echo "== 0. live process args =="
case "$B" in
  *127.0.0.1*|*localhost*|*\[::1\]*)
    if pgrep -af 'llama[-]server' | grep -q -- '--spec-type draft-mtp'; then
  echo "  OK: --spec-type draft-mtp and friends are in effect"
else
  echo "  FAIL: flags missing from the running process - check serve.sh line continuations" >&2
fi ;;
  *)
    echo "  SKIP: the server runs on another OS ($B), so its argv is not visible from here."
    echo '        Verify it there: win\check.ps1, or (Get-CimInstance Win32_Process).CommandLine' ;;
esac

echo "== 1. health / capabilities =="
curl -sS --max-time 20 "$B/health"; echo
curl -sS --max-time 20 ${OMLX_API_KEY:+-H "Authorization: Bearer $OMLX_API_KEY"} "$B/v1/models" | grep -o '"capabilities":\[[^]]*\]' | head -1

python3 - "$B" <<'PY'
_PORT = __import__("os").environ.get("PORT", "8000")
import json, os, struct, sys, time, urllib.request, zlib

B = sys.argv[1]

# The server requires a bearer key as soon as it binds anywhere but loopback (serve.sh and
# win\serve.ps1 both refuse otherwise), so every call here must carry it or step 2 dies with
# 401 while step 1 - which uses curl - looks healthy.
KEY = os.environ.get("OMLX_API_KEY") or os.environ.get("LLAMA_API_KEY") or ""

def post(payload, t=300):
    h = {"Content-Type": "application/json"}
    if KEY:
        h["Authorization"] = "Bearer " + KEY
    req = urllib.request.Request(B + "/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers=h)
    return json.load(urllib.request.urlopen(req, timeout=t))

def png(rgb):
    """Solid-colour PNG with valid CRCs (a hand-typed blob will 400)."""
    W = H = 64
    def ch(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    row = b"\x00" + bytes(rgb) * W
    return (b"\x89PNG\r\n\x1a\n"
            + ch(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
            + ch(b"IDAT", zlib.compress(row * H, 9))
            + ch(b"IEND", b""))

import base64
def ask_img(rgb_hex, name):
    b64 = base64.b64encode(png(rgb_hex)).decode()
    d = post({"model": "qwen3.8-27b", "max_tokens": 300, "temperature": 0, "messages": [
        {"role": "user", "content": [
            {"type": "text", "text": "What colour is this image? Answer in ONE word."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}}]}]})
    m = d["choices"][0]["message"]
    got = (m.get("content") or "").strip()
    # this model "thinks" first: if content is empty the budget went to reasoning
    if not got:
        got = "(empty content - raise max_tokens, reasoning ate the budget: %r...)" % (m.get("reasoning_content") or "")[:60]
    ok = "OK " if name.lower() in got.lower() else "FAIL"
    print("  %s %s -> %r" % (ok, name, got[:40]))

print("== 2. text throughput ==")
t = time.time()
d = post({"model": "qwen3.8-27b", "max_tokens": 400, "temperature": 0, "messages": [
    {"role": "user", "content": "Write 250 words on hybrid linear attention for local LLMs."}]})
n = d["usage"]["completion_tokens"]; dt = time.time() - t
print("  %d tok in %.1fs = %.1f tok/s" % (n, dt, n / dt))

print("== 3. MTP draft acceptance (from server log) ==")
try:
    log = open(__import__("os").environ.get("SERVER_LOG", "server.log"), errors="replace").read().splitlines()
    hits = [l.split("draft acceptance")[1].strip() for l in log if "draft acceptance" in l]
    print("  " + ("last:" + hits[-1] if hits else "none yet - run a generation first"))
except FileNotFoundError:
    print("  (no server.log)")

print("== 4. vision ==")
ask_img((255, 0, 0), "red")
ask_img((0, 0, 255), "blue")
PY

echo
echo "built-in chat UI (image upload supported): $B/"
