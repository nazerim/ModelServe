#!/usr/bin/env bash
# Resume-capable fetch of candidate quants into ~/.models.
#   ./get-quant.sh Qwen3.8-27B-UD-IQ4_XS.gguf Qwen3.8-27B-UD-Q3_K_XL.gguf
set -uo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"   # repo-relative, moves with the checkout
[ -f "$ROOT/config.sh" ] && . "$ROOT/config.sh"   # PORT/HOST defaults
REPO="${REPO:-unsloth/Qwen3.8-27B-GGUF}"
DST="${DST:-$HOME/.models}"
mkdir -p "$DST"

for f in "$@"; do
  want=$(curl -sIL "https://huggingface.co/$REPO/resolve/main/$f" 2>/dev/null \
         | tr -d '\r' | awk 'tolower($1)=="x-linked-size:"{print $2}' | tail -1)
  [ -z "$want" ] && want=$(curl -sIL "https://huggingface.co/$REPO/resolve/main/$f" 2>/dev/null \
         | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2}END{print v}')
  echo "=== $f  (expected ${want:-?} bytes)"
  # -C - resumes; --continue-at with an existing full file just no-ops
  curl -fL -C - --retry 5 --retry-delay 5 --connect-timeout 20 \
       -o "$DST/$f" "https://huggingface.co/$REPO/resolve/main/$f" 2>>"$DST/getquant.log"
  got=$(stat -c%s "$DST/$f" 2>/dev/null || echo 0)
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    echo "  SIZE MISMATCH got=$got want=$want  (re-run to resume)"; exit 1
  fi
  # cheap integrity check: GGUF magic + architecture key
  head -c 4 "$DST/$f" | grep -q GGUF || { echo "  NOT A GGUF: $f"; exit 1; }
  echo "  ok $got bytes  $(awk -v b="$got" 'BEGIN{printf "%.2f GiB", b/1073741824}')"
done
echo "ALL_DONE"
