#!/usr/bin/env bash
# Fetch the real-photo test images used by vision-check.py.
# They are NOT committed (copyright + 2.3 MB), so run this once after a clone.
# Sizes are deliberate: one small-ish and one very large photo, because projector
# cost scales steeply with image tokens (1122 tok ~22 s vs 4122 tok ~183 s on CPU).
set -euo pipefail
cd "$(dirname "$0")"
D="${D:-testimg}"; mkdir -p "$D"
UA='Mozilla/5.0 (compatible; local-vision-test)'

for a in Cat Dog; do
  # the REST summary carries originalimage.source (note: "source", not "url")
  u=$(curl -s -A "$UA" --max-time 30 "https://en.wikipedia.org/api/rest_v1/page/summary/$a" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["originalimage"]["source"])')
  [ -n "$u" ] || { echo "no image URL for $a" >&2; exit 1; }
  curl -sL -A "$UA" --max-time 120 -o "$D/$a.jpg" "$u"
  [ "$(head -c2 "$D/$a.jpg" | xxd -p)" = "ffd8" ] || { echo "$a.jpg is not JPEG" >&2; exit 1; }
  printf '%-4s %8s bytes  %s\n' "$a" "$(stat -c%s "$D/$a.jpg")" "${u%%\?*}"
done
echo "ok: $D/ ready for vision-check.py"
