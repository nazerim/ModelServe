#!/usr/bin/env bash
# llama-server for unsloth/Qwen3.8-27B-GGUF  (arch `qwen35`: hybrid Gated
# DeltaNet + full attention, in-file MTP head, Qwen3-VL-style vision mmproj).
#
# Models live in ~/.models. Pick a quant with Q= and a size with TIER=:
#
#   Q=q3    Qwen3.8-27B-UD-Q3_K_XL.gguf  12.24 GiB  -> 212,992 ctx   (default)
#   Q=q4s   Qwen3.8-27B-UD-Q4_K_S.gguf   14.30 GiB  -> 163,840 ctx   (4-bit + long ctx)
#   Q=q4    Qwen3.8-27B-UD-Q4_K_XL.gguf  16.35 GiB  -> 122,880 ctx   (best quality)
#
#   TIER=small     32,768   low latency, most headroom
#   TIER=medium    98,304
#   TIER=large    163,840   the size every quant on hand can take safely
#   TIER=max    DEFAULT - that quant's measured safe ceiling (see Q= above)
#
# "Safe" = >=~400 MiB left on the display GPU. Below ~240 MiB this box aborts, and the
# free memory is read from nvidia-smi's memory.free (total-used overstates it ~300 MiB).
# Ceilings assume BATCH=1024 UBATCH=256: shrinking the pp batch from the 2048/512 default
# costs only ~8% of prompt throughput (1301 -> 1201 tok/s measured) and frees ~570 MiB,
# which is what turned 204,800 from a hard failure into an easy pass.
#
# Output budget defaults to 32K tokens (NPRED). All of these are env-overridable,
# and DRY=1 prints the resolved command instead of launching it.
#
# Why the defaults, measured on this box (see ~/nodes/005-long-context-200k.md):
#   CUDA0 = 5070 Ti 16303 MiB (display eats ~1.4 GiB), CUDA1 = 3080 10240 MiB
#   KV only exists in 17 of 65 blocks -> f16 80 / q8_0 37.8 / q4_0 ~23 KiB per token
#   15 GB system RAM -> never offload *weights* to CPU
#   MTP (--spec-type draft-mtp) is worth ~1.9x: 46-50 tok/s vs 25.7 without
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
BIN="${BIN:-$ROOT/llama/llama-server}"
M="${M:-$HOME/.models}"

# ---- quant + tier ----------------------------------------------------------
Q="${Q:-q3}"
TIER="${TIER:-max}"   # default = the quant's SAFE ceiling
case "$Q" in
  # Ceilings = the largest context still leaving >=~400 MiB on the display GPU,
  # measured with BATCH=1024/UBATCH=256 and SPLIT=18,7 (see README "Models on hand").
  q3)  MODEL="${MODEL:-$M/Qwen3.8-27B-UD-Q3_K_XL.gguf}"; CEIL="${CEIL:-212992}"; PROFILE_ID="qwen3.8-27b" ;;
  q4s) MODEL="${MODEL:-$M/Qwen3.8-27B-UD-Q4_K_S.gguf}";   CEIL="${CEIL:-163840}"; PROFILE_ID="qwen3.8-27b-4s" ;;
  q4)  MODEL="${MODEL:-$M/Qwen3.8-27B-UD-Q4_K_XL.gguf}";  CEIL="${CEIL:-122880}"; PROFILE_ID="qwen3.8-27b-4xl" ;;
  *)   MODEL="${MODEL:-}"; CEIL="${CEIL:-999999}"; PROFILE_ID="qwen3.8-27b" ;;  # MODEL= given -> trust it
esac
case "$TIER" in
  small)  CTX_D=32768  ;;
  medium) CTX_D=98304  ;;
  large)  CTX_D=163840 ;;
  max)    CTX_D="$CEIL" ;;
  *) echo "TIER must be small|medium|large|max" >&2; exit 2 ;;
esac
CTX="${CTX:-$CTX_D}"
if [ "$CTX" -gt "$CEIL" ]; then
  echo "note: CTX=$CTX exceeds the measured ceiling ($CEIL) for this quant; clamping." >&2
  CTX="$CEIL"
fi

# ---- everything else -------------------------------------------------------
# Proportions in CUDA order: CUDA0=5070 Ti, CUDA1=3080. 18,7 was found by sweeping
# at CTX=196608: 19,6 also fits but leaves the display GPU 98 MiB, while 18,7 keeps
# 541 MiB (3080 441) and is slightly faster; 17,8/16,9 overflow the 3080 instead.
# Use 19,6 for the q4 tier if you prefer more room on the 3080 there.
SPLIT="${SPLIT-18,7}"
NP="${NP:-1}"                  # 1 slot = the whole context for one conversation
PORT="${PORT:-8000}"
HOST="${HOST:-127.0.0.1}"      # WSL is NAT mode; 127.0.0.1 is invisible to Windows apps
NPRED="${NPRED:-32768}"        # default output budget (-1 = until context fills)
# NGL=99 pins all layers to GPU and *disables* llama.cpp's auto-fitter; NGL= re-enables it.
NGL="${NGL-99}"
KV="${KV:-q8_0}"               # f16 | q8_0 | q4_0   (q4_0 measured to under-deliver)
# Where the 0.86 GiB vision projector goes: cpu = +32K tokens of context at 17.5 s/image;
# 3080 = `-mmdev CUDA1`, GPU speed but caps ctx; cuda0 = SIGABRTs once CUDA0 runs dry.
MM="${MM:-cpu}"
# Prompt batch. Keep well below the 2048/512 default: it is what the pp compute buffer
# is sized from, and that buffer - not KV - is what fails first on this pair.
BATCH="${BATCH:-1024}"
UBATCH="${UBATCH:-256}"
# Auth: pi reads the key from $OMLX_API_KEY (see ~/.pi/agent/models.json), so the server
# must require the same value. Empty = no auth (fine while bound to loopback).
API_KEY="${API_KEY-${OMLX_API_KEY:-}}"
# pi's model id for this profile, so /v1/models reports which quant is actually live
# (llama-server ignores the incoming model name, so a mismatch would be silent).
ALIAS="${ALIAS:-$PROFILE_ID}"

# prebuilt tarballs are not self-contained: CUDA runtime libs + libgomp
export LD_LIBRARY_PATH="$ROOT/llama:$ROOT/cudart-libs:$ROOT/libs/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

[ -x "$BIN" ] || { echo "missing $BIN (see $ROOT/README.md)" >&2; exit 1; }
[ -n "$MODEL" ] || { echo "set Q=q3|q4 or MODEL=/path/to.gguf" >&2; exit 2; }
[ -f "$MODEL" ] || { echo "no such model: $MODEL" >&2; exit 1; }

ARGS=(
  -m "$MODEL"
  --mmproj "$M/mmproj-F16.gguf"
  --jinja
  --image-min-tokens 1024
  -sm layer
  -c "$CTX" -np "$NP"
  -n "$NPRED"
  -b "$BATCH" -ub "$UBATCH"
  --spec-type draft-mtp --spec-draft-n-max 2
  --host "$HOST" --port "$PORT"
  --alias "$ALIAS"
)
# These must stay OUT of the array: each is conditional, and a stray blank line
# after a trailing backslash once silently truncated an `exec` command.
[ -n "$SPLIT" ] && ARGS+=(--tensor-split "$SPLIT")
[ -n "$NGL" ]   && ARGS+=(-ngl "$NGL")
[ -n "$KV" ]    && ARGS+=(-ctk "$KV" -ctv "$KV")
[ -n "$API_KEY" ] && ARGS+=(--api-key "$API_KEY")
case "$MM" in
  cpu)   ARGS+=(--no-mmproj-offload) ;;
  3080)  ARGS+=(-mmdev CUDA1) ;;
  cuda0) ARGS+=(-mmdev CUDA0) ;;
  *) echo "MM must be cpu|3080|cuda0" >&2; exit 2 ;;
esac

# Live-testing guard: WSL here is in NAT mode, so reaching the server from Windows
# means HOST=0.0.0.0 - which also exposes an unauthenticated, CORS-open endpoint to the
# LAN (llama-server warns about exactly this at startup). Refuse unless a key is given.
case "$HOST" in
  127.0.0.1|localhost|::1) : ;;
  *)
    keygiven=0
    [ -n "$API_KEY" ] && keygiven=1
    for a in "$@"; do case "$a" in --api-key|*--api-key=*) keygiven=1 ;; esac; done
    if [ "$keygiven" = 0 ] && [ -z "${ALLOW_OPEN_NO_AUTH:-}" ]; then
      echo "refusing to bind HOST=$HOST with no --api-key (CORS is '*' by default)." >&2
      echo "  local-only: keep HOST=127.0.0.1 and use wslhost/ports proxying, or" >&2
      echo "  pass:  ./serve.sh --api-key <key>     ...or accept the risk: ALLOW_OPEN_NO_AUTH=1" >&2
      exit 2
    fi ;;
esac

# ASSERT the assembled command matches intent. A summary that infers state from a variable
# ("AUTH=yes") once hid the fact that --api-key was never appended. Check the ARGS itself.
if [ -n "$API_KEY" ] && ! printf '%s\n' "${ARGS[@]}" | grep -qx -- '--api-key'; then
  echo "internal error: API_KEY set but --api-key not in ARGS" >&2; exit 3
fi
printf '%s\n' "${ARGS[@]}" | grep -qxF -- "$ALIAS" || { echo "internal error: --alias value missing from ARGS" >&2; exit 3; }

if [ -n "${DRY:-}" ]; then
  echo "Q=$Q TIER=$TIER -> CTX=$CTX NPRED=$NPRED SPLIT=$SPLIT NGL='${NGL}' KV='$KV MM=$MM BATCH=$BATCH/$UBATCH ALIAS=$ALIAS AUTH=${API_KEY:+yes}${API_KEY:-no}" | sed 's/AUTH=yes.*/AUTH=yes/'
  printf ' %q' "${BIN}" "${ARGS[@]}" "$@"; echo
  exit 0
fi

exec "$BIN" "${ARGS[@]}" "$@"
