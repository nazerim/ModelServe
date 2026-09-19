#!/usr/bin/env bash
# ladder-from-wsl.sh — context-size ladder for the NATIVE-Windows server, driven from WSL.
# Twin of iq-ladder.sh; see win/wsl-harness.sh for why launches are async and polls are local.
#
# Stops climbing as soon as a size fails, for the same reason iq-ladder.sh does: a pass above a
# failure is allocation luck, not capacity.
#
#   ./ladder-from-wsl.sh                      # 163840 180224 196608 on q3
#   SIZES=196608 ./ladder-from-wsl.sh         # one size (test a single boot)
#   KEEP=1 SIZES=... ./ladder-from-wsl.sh     # leave the last server running
#   FORCE=1 SIZES=204800 ./ladder-from-wsl.sh # past the documented cliff - read the warning
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/win/wsl-harness.sh" || exit 1

CTX_MAX_KNOWN="${CTX_MAX_KNOWN:-}"
# Two measured ceilings, and which applies depends on the profile, because the extra context is
# paid for out of the prompt compute buffer:
#   q3  (1024/256) -> 196,608 SAFE, 212,992 MARGINAL (275 MiB on the 3080)
#   q3l (512/128)  -> 225,280 SAFE (517 MiB), 229,376 projects MARGINAL
# Rather than repeat those constants here, the guard defaults to whatever the profile itself
# resolves to (see the -DryRun below); set CTX_MAX_KNOWN to climb past a recorded ceiling only
# when the sizes really have been measured, e.g. q3 with EXTRA="-Batch 512 -Ubatch 128".
read -r -a EXTRA_ARGS <<<"${EXTRA:-}"
SIZES="${SIZES:-163840 180224 196608}"
# Positional args do the same thing, because "./ladder-from-wsl.sh 233472" is what everyone
# types first (and iq-ladder.sh takes its models positionally). Without this, a size passed as
# an argument is IGNORED and the default ladder silently runs instead - which is how a guard
# test here accidentally booted 196,608 and reported no SKIP.
if [ "$#" -gt 0 ]; then SIZES="$*"; fi
Q="${Q:-q3}"
SPLIT="${SPLIT:-}"
OUT="${OUT:-iq-ladder-win.tsv}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"

echo "target: $BASE  profile=$Q split=${SPLIT:-profile default}"
if [ -z "$CTX_MAX_KNOWN" ]; then
  # Ask the profile what it thinks its ceiling is - one source of truth (config.ps1).
  CTX_MAX_KNOWN=$(win_run "$WINSCRIPTS\\serve.ps1" 120 -P "$Q" -Tier max ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} -DryRun 2>/dev/null |
                  sed -nE 's/.*CTX=([0-9]+).*/\1/p' | head -1)
  [ -n "$CTX_MAX_KNOWN" ] || CTX_MAX_KNOWN=196608
fi
echo "ceiling guard: $CTX_MAX_KNOWN (from the profile; raise with CTX_MAX_KNOWN=... only when measured)"
printf 'quant\tctx\tstatus\tvram_5070Ti\tvram_3080\tfree_5070Ti\tfree_3080\tboot_s\ttok_s\n' > "$OUT"

for c in $SIZES; do
  if [ "$c" -gt "$CTX_MAX_KNOWN" ] && [ -z "${FORCE:-}" ]; then
    echo "  SKIP $c: above the known ceiling ($CTX_MAX_KNOWN). The ext4 runs hit" >&2
    echo "       'CUDA error: device not ready' at 204,800; natively that can take the Windows" >&2
    echo "       display driver with it. Re-run with FORCE=1 only if you accept that." >&2
    break
  fi
  stop_win
  log="/tmp/ladder-$c.log"; : > "$log"
  args=(-P "$Q" -Ctx "$c" -Ceil "$c" -TimeoutSec "$BOOT_TIMEOUT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})
  [ -n "$SPLIT" ] && args+=(-Split "$SPLIT")
  # -Ceil is ALWAYS passed, equal to the size being tested. Two failure modes it closes: the
  # profile clamp quietly booting 196,608 and reporting a PASS for a 225,280 test, and the same
  # lie in reverse if a raised CTX_MAX_KNOWN outran config.ps1's ceiling. The ladder asks for
  # exactly the size it is about to measure, so the TSV cannot describe a different boot.
  [ -n "$SPLIT" ] && args+=(-Split "$SPLIT")
  if [ "${FORCE:-}" = "1" ] && [ "$c" -gt "$CTX_MAX_KNOWN" ]; then
    echo "  FORCE=1: $c is past the recorded ceiling ($CTX_MAX_KNOWN) - UNMEASURED ground, watch for device-not-ready"
  fi
  win_launch "$log" "$WINSCRIPTS\\start.ps1" "${args[@]}"
  printf '  CTX=%s booting...' "$c"
  if boot=$(wait_ready "$BOOT_TIMEOUT"); then
    echo " ready in ${boot}s"
    read -r f3080 f5070 <<<"$(gpu_free)"; read -r u3080 u5070 <<<"$(gpu_used)"
    sp=$(timeout 200 python3 - "$Q" <<'PY' 2>/dev/null || echo ERR
import json, os, time, urllib.request
B = os.environ["BASE"]; K = os.environ.get("OMLX_API_KEY", "")
h = {"Content-Type": "application/json"}
if K: h["Authorization"] = "Bearer " + K
p = {"model": "qwen3.8-27b", "temperature": 0, "max_tokens": 400,
     "messages": [{"role": "user", "content": "Describe in detail how a paged KV cache works."}]}
t = time.time()
d = json.load(urllib.request.urlopen(urllib.request.Request(B + "/v1/chat/completions",
                              data=json.dumps(p).encode(), headers=h), timeout=180))
print(f"{d['usage']['completion_tokens']/(time.time()-t):.1f}")
PY
)
    echo "  OK   5070Ti used=$u5070 free=$f5070 | 3080 used=$u3080 free=$f3080 | ${sp} tok/s"
    printf '%s\t%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\n' "$Q" "$c" "$u5070" "$u3080" "$f5070" "$f3080" "$boot" "$sp" >> "$OUT"
  else
    echo " FAIL after ${boot}s"
    read -r f3080 f5070 <<<"$(gpu_free)"; read -r u3080 u5070 <<<"$(gpu_used)"
    echo "       5070Ti used=$u5070 free=$f5070 | 3080 used=$u3080 free=$f3080"
    tail -4 "$log" | tr -d '\0' | grep -iE 'out of memory|failed to allocate|device not ready|SIGABRT|NOT READY|no-answer' | head -2 | cut -c1-140 | sed 's/^/       /'
    printf '%s\t%s\tFAIL\t%s\t%s\t%s\t%s\t%s\t-\n' "$Q" "$c" "$u5070" "$u3080" "$f5070" "$f3080" "${boot}" >> "$OUT"
    break
  fi
done

[ -n "${KEEP:-}" ] || { echo "  stopping the server"; stop_win; }
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
