#!/usr/bin/env bash
# Measure SAFE context per quant profile - DESCENDING ONLY.
#
# Why this rule exists: the first version of this script accepted an ascending list and
# booted q4s at 167,936 *after* 163,840 had already measured 120 MiB worst-case (UNSAFE).
# That took the Windows NVIDIA driver down again and cost another full reboot. When the
# failure mode is a host reset, a probe above a known-unsafe value is not a measurement,
# it is a dice roll.
#
# Protocol:
#   - start at or below the profile's serve.sh ceiling, and only ever go DOWN
#   - the ceiling is asked of serve.sh itself (DRY=1) so there is one source of truth and
#     this script cannot silently override it (the bug above passed CEIL=<ctx>, which
#     defeated the clamp entirely)
#   - first SAFE result wins; anything above it is left unexplored on purpose
#
#   ./safe-scan.sh "q4s:147456" "q4s:139264" "q4:106496"
set -uo pipefail
cd "$(dirname "$0")"
OUT=safe-scan.tsv
SAFE_MIN="${SAFE_MIN:-400}"          # MiB of free VRAM required on BOTH cards, under load
printf 'profile\tctx\tresult\tworst_free_mib\tnote\n' > "$OUT"

cur_q=""; cur_cap=""
for spec in "$@"; do
  q="${spec%%:*}"; ctx="${spec##*:}"

  # ask serve.sh what it would really run (respects the per-profile clamp)
  eff=$(Q="$q" CTX="$ctx" DRY=1 timeout 60 ./serve.sh 2>/dev/null | sed -nE 's/.*CTX=([0-9]+).*/\1/p' | head -1)
  if [ -z "$eff" ]; then echo "  REFUSED: serve.sh rejected profile $q"; continue; fi
  if [ "$eff" != "$ctx" ]; then
    echo "  REFUSED: asked $ctx for $q but serve.sh clamps to $eff (raise its CEIL deliberately, not here)"
    printf '%s\t%s\tREFUSED-CLAMP\t%s\t-\n' "$q" "$ctx" "$eff" >> "$OUT"; continue
  fi
  if [ "$q" = "$cur_q" ] && [ "$ctx" -gt "$cur_cap" ]; then
    echo "  REFUSED: $q ctx $ctx is ABOVE the previous probe $cur_cap (descending only - see header)"
    printf '%s\t%s\tREFUSED-ASCEND\t-\t-\n' "$q" "$ctx" >> "$OUT"; continue
  fi
  cur_q="$q"; cur_cap="$ctx"

  echo "=========== Q=$q  CTX=$ctx  (probe ceiling respected)"
  Q="$q" CTX="$ctx" NP=1 timeout 400 ./start.sh >/tmp/scan-boot.log 2>&1 || {
    echo "  boot FAILED"; tail -3 /tmp/scan-boot.log 2>/dev/null | sed 's/^/    /'
    printf '%s\t%s\tBOOTFAIL\t-\tsee /tmp/scan-boot.log\n' "$q" "$ctx" >> "$OUT"; cur_cap=999999999; continue; }

  res=$(timeout 900 python3 margin-check.py 2>&1 | tail -4)
  worst=$(grep -oE 'WORST-CASE FREE = [0-9]+' <<<"$res" | grep -oE '[0-9]+' || echo "?")
  st=$(grep -oE '(SAFE|MARGINAL|UNSAFE)' <<<"$res" | tail -1)
  printf '  worst free=%s MiB -> %s\n' "${worst:-?}" "${st:-?}"
  printf '%s\t%s\t%s\t%s\t-\n' "$q" "$ctx" "${st:-?}" "${worst:-?}" >> "$OUT"
  # once safe, stop probing this profile lower down unless asked; and never go back up
  [ "$st" = SAFE ] && { echo "  $q: $ctx is the safe value; leaving headroom unexplored by design."; break; }
done
pkill -9 -f 'llama[-]server' 2>/dev/null
echo; echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
