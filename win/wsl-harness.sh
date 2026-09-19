#!/usr/bin/env bash
# wsl-harness.sh — shared primitives for driving the NATIVE-Windows server from WSL.
# Sourced by ladder-from-wsl.sh and stability-from-wsl.sh; not meant to be run directly.
#
# THE ONE THING THAT COST THE MOST HERE: WSL interop does not return until the Windows process
# tree it spawned has finished. `start.ps1` itself exits in ~12 s after it sees health:ok, but
# the server it detached is a descendant of the interop call — so a synchronous
# `powershell.exe -File start.ps1` blocks for as long as the SERVER lives, not as long as the
# launcher. Two runs were lost to that (one looked like a 300 s hang; the boot had finished in
# 11 s) before it was measured instead of assumed.
#
# So: launches are fire-and-forget (win_launch), and readiness is polled locally with curl
# (wait_ready) against $BASE — no interop in the wait loop at all, so the poll interval is
# honest milliseconds and a stuck boot is visible immediately rather than at a timeout.
# Synchronous calls (win_run) are only for commands that leave nothing behind: stop.ps1,
# serve.ps1 -DryRun. Those return in ~5 s because their process tree actually exits.

[ -n "${_MS_HARNESS_SH:-}" ] && return 0
_MS_HARNESS_SH=1

PS_EXE="${PS_EXE:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
[ -x "$PS_EXE" ] || PS_EXE="$(command -v powershell.exe 2>/dev/null || true)"
[ -n "$PS_EXE" ] || { echo "powershell.exe not found - run this inside WSL" >&2; return 1; }

WINSCRIPTS="${WINSCRIPTS:-C:\\ModelServe\\win}"
PORT="${PORT:-8000}"

GW="${GW:-$(ip route | awk '/^default/ {print $3; exit}')}"
[ -n "$GW" ] || { echo "no default gateway - WSL networking is down" >&2; return 1; }
export BASE="${BASE:-http://${GW}:${PORT}}"

# win_run <script> <budget-sec> [args...]  — synchronous, capture through a FILE.
# Never pipe a PowerShell call into tr: the detached server's conhost inherits the pipe's write
# end, so `| tr` never sees EOF and bash waits on a process that already exited.
win_run() {
  local script="$1" budget="$2"; shift 2
  local f rc; f=$(mktemp /tmp/winrun.XXXXXX)
  timeout "$budget" "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" "$@" > "$f" 2>&1
  rc=$?
  tr -d '\0\r' < "$f"; rm -f "$f"   # \r too: Windows writes CRLF and anchored matches fail on it
  return $rc
}

# win_launch <logfile> <script> [args...] — returns immediately; the output keeps appending to
# <logfile>, which is what a later failure report reads.
win_launch() {
  local log="$1" script="$2"; shift 2
  nohup "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$script" "$@" >> "$log" 2>&1 &
  disown 2>/dev/null || true
  WIN_LAUNCH_PID=$!
  return 0
}

# wait_ready <timeout-sec> — curl-poll $BASE/health. Echoes the elapsed seconds on success.
# A boot that fails on allocation is reported as soon as the server stops answering AND the
# pid is gone, so a dead boot does not burn the whole timeout.
wait_ready() {
  local budget="${1:-300}" t0 t h n=0
  t0=$(date +%s%N)
  while :; do
    sleep 3; n=$((n + 1))
    # nanoseconds -> SECONDS. Dividing by 1e6 gives ms, which made the very first 3 s poll
    # exceed a 300 s "budget" and report a boot that was still loading as FAIL.
    t=$(( ( $(date +%s%N) - t0 ) / 1000000000 ))
    h=$(curl -s -m 5 "$BASE/health" 2>/dev/null)
    case "$h" in
      *'"status":"ok"'*) echo "$t"; return 0 ;;
      *'Loading model'*|*'loading'*) : ;;
    esac
    # A dead process answers nothing at all; distinguish "still loading" (some HTTP answer) from
    # "never came up" (no HTTP answer) so a broken boot reports early instead of at the timeout.
    if [ -z "$h" ] && [ "$n" -gt 6 ] && ! curl -s -m 2 -o /dev/null "$BASE/health" 2>/dev/null; then
      echo "$t"; return 1
    fi
    if [ "$t" -ge "$budget" ]; then echo "$t"; return 1; fi
  done
}

# stop_win — synchronous stop; safe to call when nothing is running.
stop_win() { win_run "$WINSCRIPTS\\stop.ps1" 90 >/dev/null 2>&1; sleep 3; }

# gpu_free — "free3080 free5070" in MiB from the WSL side. Both nvidia-smi views read the same
# host driver, and the 400/240 thresholds were defined from this side, so the numbers stay
# comparable with the ext4 runs. Index order here: line 1 = 3080, line 2 = 5070 Ti.
gpu_free() {
  read -r f3080 f5070 < <(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' ')
  echo "${f3080:-?} ${f5070:-?}"
}
gpu_used() {
  read -r u3080 u5070 < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' ')
  echo "${u3080:-?} ${u5070:-?}"
}

# host_headroom — "ram_free_gb commit_free_gb" from the Windows side. Synchronous is safe here:
# Get-CimInstance leaves no descendant behind, so the interop call returns (unlike a launch).
# Commit is the one to watch: a native boot maps 12 GiB of weights and adds an MTP draft
# context on top, and a crawl rather than a failure is usually this ceiling, not VRAM.
host_headroom() {
  local f out
  f=$(mktemp /tmp/winhr.XXXXXX)
  timeout 60 "$PS_EXE" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command '
    $os = Get-CimInstance Win32_OperatingSystem
    "{0:N1} {1:N1}" -f ($os.FreePhysicalMemory/1MB), ($os.FreeVirtualMemory/1MB)' > "$f" 2>&1
  out=$(tr -d '\0\r' < "$f" | grep -E '^[0-9.,]+ [0-9.,]+$' | tail -1 | tr ',' '.')
  rm -f "$f"
  echo "${out:-? ?}"
}

# api_get <path> — authenticated GET against $BASE (the key is the same value both sides use).
api_get() { curl -s -m 20 ${OMLX_API_KEY:+-H "Authorization: Bearer $OMLX_API_KEY"} "$BASE$1"; }
