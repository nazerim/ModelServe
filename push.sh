#!/usr/bin/env bash
# Walk context up (or down) in fixed steps, one isolated boot per size, STOPPING at the
# first failure. Why stop: above the real ceiling a boot can still "succeed" by luck
# (122,880 passed at split 18,7 with 109 MiB free and failed at 15,10), so the trustworthy
# number is the last clean pass before the first failure, not the largest pass seen.
#
#   ./push.sh <QUANT> <SPLIT> <START_CTX> [STEP=4096] [END_CTX]
#     ./push.sh Q4_K_S 18,7 172032 4096 192512        # ascend in 4K steps
#     ./push.sh Q4_K_S 18,7 184320 -4096 163840       # descend
set -uo pipefail
cd "$(dirname "$0")"
q="${1:?usage: push.sh <QUANT> <SPLIT> <START> [STEP] [END]}"
s="${2:?split, e.g. 18,7}"
start="${3:?start ctx}"
step="${4:-4096}"
end="${5:-$start}"
OUT="push-$q-${s//,/_}.tsv"

up=1
if [ "$step" -lt 0 ]; then up=0; step=$(( -step )); fi

printf 'ctx\tstatus\tfree_5070Ti/3080\ttok_s\taccept\tmtp_unused\tnote\n' > "$OUT"
c="$start"; last_ok=""; dirn=ascending
[ "$up" = 1 ] || dirn=descending
echo "### $q  split=$s  $dirn from $start, step $step, limit $end"

while :; do
  if [ "$up" = 1 ]; then [ "$c" -le "$end" ] || break; else [ "$c" -ge "$end" ] || break; fi

  raw=$(timeout 900 ./rerun.sh "$q $s $c" 2>&1 | grep -E '^  (OK|FAIL|MISMATCH)' | tail -1)
  [ -n "$raw" ] || raw="  FAIL no-result-line (harness or boot problem)"

  st=$(awk '{print $1}' <<<"$raw")
  # the harness prints  free(5070Ti/3080)=<A>/<B> MiB  ...  <T> tok/s ... accept=<x> mtp_unused=<n>
  pair=$(sed -nE 's#.*free\(5070Ti/3080\)=([^ ]+) MiB.*#\1#p' <<<"$raw")
  toks=$(sed -nE 's#.*[   ]([0-9]+\.[0-9]+) tok/s.*#\1#p' <<<"$raw" | head -1)
  acc=$(sed  -nE 's#.*accept=([^ ]+).*#\1#p' <<<"$raw" | head -1)
  mtp=$(sed  -nE 's#.*mtp_unused=([^ ]+).*#\1#p' <<<"$raw" | head -1)
  note=$(sed  -E 's#.*MiB[[:space:]]+##; s#.*tok/s[[:space:]]+mtp_unused=[^ ]+[[:space:]]+##' <<<"$raw")
  [ "$st" = OK ] && note="-"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$st" "${pair:-?}" "${toks:--}" "${acc:--}" "${mtp:--}" "$note" >> "$OUT"
  printf '  ctx=%-8s %-9s free(5070Ti/3080)=%-12s %s\n' "$c" "$st" "${pair:-?}" "${toks:+$toks tok/s}"

  if [ "$st" != OK ]; then
    echo "  STOP: first non-OK at $c  ->  last clean pass = ${last_ok:-NONE}"
    break
  fi
  last_ok="$c"
  if [ "$up" = 1 ]; then c=$(( c + step )); else c=$(( c - step )); fi
done

echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
echo "RESULT: last usable CTX for $q @ split $s = ${last_ok:-none}"
pkill -f 'llama[-]server' 2>/dev/null; true
