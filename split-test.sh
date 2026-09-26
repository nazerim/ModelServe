#!/usr/bin/env bash
# Measure what a one-layer split move ACTUALLY costs on this pair, one boot per split, and
# leave the box running something bootable no matter what happens.
#
#   ./split-test.sh                              # SPLITS below, q3l at its ceiling
#   SPLITS="46,20" KEEP=46,20 ./split-test.sh    # one candidate only
#   DRY=1 ./split-test.sh                        # walk the plan, touch nothing
#
# Why measured and not computed: --tensor-split in -sm layer mode is a LAYER-COUNT fraction
# (src/llama-model.cpp: device(il) = upper_bound(normalized_ts, il/(n_layer+1))), with
# n_layer=65 so the denominator is 66. That predicts which block moves; it does NOT predict
# the compute-buffer delta each boot pays, and this box has always failed on the buffer, not
# on KV. So: boot it, then read worst-case free under a real cold prefill.
#
# margin-check.py is the instrument (it is what defined the 400/240 lines). WORDS is a size
# that has never been prefilled on this box on purpose: the disk prompt cache is keyed by
# content, and a cached prefix skips the prefill, and the prefill is where the peak is.
set -uo pipefail
cd "$(dirname "$0")"

PROFILE="${PROFILE:-q3}"
SPLITS="${SPLITS:-46,20 47,19}"
KEEP="${KEEP:-47,19}"                 # what to leave running if it passed
DEFAULT_SPLIT="${DEFAULT_SPLIT:-47,19}"    # the certified split since 2026-09-26; fallback target
CTX="${CTX:-}"                        # empty = the profile's own ceiling
WORDS="${WORDS:-23777}"
ROUNDS="${ROUNDS:-1}"
BASE="${BASE:-http://172.25.240.1:8000}"
PS=(powershell.exe -NoProfile -ExecutionPolicy Bypass)
OUT="${OUT:-split-test-$(date +%Y%m%d-%H%M).tsv}"
ERRLOG='/mnt/c/ModelServe/logs/server.err.log'

printf 'split\tstatus\tidle_3080\tidle_5070Ti\tpostboot_3080/5070Ti\tworst_free\tpp_tok_s\ttg_tok_s\tnote\n' > "$OUT"

HDR=()
[ -n "${OMLX_API_KEY:-}" ] && HDR=(-H "Authorization: Bearer $OMLX_API_KEY")

free_pair() {   # nvidia-smi index order: [0]=3080 [1]=5070 Ti
  nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | tr '\n' ' '
}
health() {  # 200 = ready and serving
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 ${HDR[@]+"${HDR[@]}"} "$BASE/health" 2>/dev/null
}
wait_dead() {   # the port must stop answering before we relaunch
  for _ in $(seq 1 20); do
    [ "$(health)" = "000" ] && return 0     # nothing listening
    sleep 2
  done
  return 1
}
boot() {  # boot <split> -> 0 healthy, 1 failed.
  # NOTE the server is a WINDOWS GRANDCHILD (start.ps1 -> hidden powershell -> llama-server.exe),
  # and powershell.exe under WSL interop does not return while that child lives. So the launch is
  # backgrounded and readiness is decided HERE, by polling /health - not by waiting on the exit.
  local s="$1" lg i code
  lg="/tmp/boot-${s//,/_}.log"
  read -r -a XTRA <<<"${EXTRA:-}"
  # -Ceil travels WITH -Ctx: without it serve.ps1 clamps a size above the profile ceiling and the
  # row would report the size that was asked for, not the size that actually booted.
  "${PS[@]}" -File 'C:\ModelServe\win\start.ps1' -P "$PROFILE" ${CTX:+-Ctx "$CTX"} ${CTX:+-Ceil "$CTX"} \
      ${XTRA[@]+"${XTRA[@]}"} -Split "$s" -TimeoutSec 240 > "$lg" 2>&1 &
  for i in $(seq 1 70); do
    sleep 3
    code="$(health)"
    [ "$code" = "200" ] && { sleep 2; return 0; }
    # a too-large config dies as an allocation abort, not as a slow load
    if grep -qiE 'out of memory|failed to allocate|SIGABRT|Segmentation|bad_alloc|NOT READY|process exited early' "$lg" 2>/dev/null; then
      return 1
    fi
  done
  return 1
}
alive() {  # if nvidia-smi itself stops answering, the driver went down - do not keep poking
  [ -n "$(free_pair)" ]
}

echo "### $PROFILE split ladder: $SPLITS   (fallback split $DEFAULT_SPLIT, WORDS=$WORDS ROUNDS=$ROUNDS)"
if [ -n "${DRY:-}" ]; then
  echo "would: stop -> idle free -> start -P $PROFILE -Split <s> -> margin-check -> next"
[ -n "${EXTRA:-}" ] && echo "with extra serve.ps1 args: $EXTRA"
  echo "would leave running: $KEEP (falling back to $DEFAULT_SPLIT if $KEEP did not pass)"
  exit 0
fi

PASSED=""
BOOTTED=""
for s in $SPLITS; do
  echo "--- $s : stopping current server"
  "${PS[@]}" -File 'C:\ModelServe\win\stop.ps1' >/tmp/stop.log 2>&1
  wait_dead || echo "  WARNING: port still answered after stop"
  alive || { echo "  !! nvidia-smi returned nothing - driver/GPU stack is down. ABORTING ladder."; exit 3; }
  idle="$(free_pair)"
  echo "  idle free (3080 5070Ti): $idle"
  echo "  booting -Split $s ..."
  if boot "$s"; then
    post="$(free_pair)"
    echo "  booted. post-boot free (3080 5070Ti): $post"
    echo "  sampling margin under a cold ${WORDS}-word prefill..."
    mc_out=$(BASE="$BASE" WORDS="$WORDS" ROUNDS="$ROUNDS" python3 margin-check.py 2>&1)
    worst=$(printf '%s\n' "$mc_out" | grep -oE 'WORST-CASE FREE = [0-9]+ MiB' | grep -oE '[0-9]+')
    verdict=$(printf '%s\n' "$mc_out" | grep -oE '(SAFE|MARGINAL|UNSAFE)[^)]*\)?' | tail -1)
    after=$(printf '%s\n' "$mc_out" | grep -E 'min free DURING load' | tail -1)
    # Authoritative pp comes from the server log (their README says the same). Two traps here, both
    # hit in this session: (1) "tail -1" alone grabs the LAST prompt eval line, which is a 4-token
    # warmup or a cache-hit stub and reads ~31 tok/s, so the big-prompt lines must be selected first;
    # (2) do NOT filter with awk /[0-9]{4,}/ - Ubuntu's default awk is mawk, which silently never
    # matches an interval regex and returns nothing. grep -E does honour intervals, so filter there.
    pp=$(grep -a "prompt eval time" "$ERRLOG" 2>/dev/null |
         grep -aE "[0-9]{4,} tokens" | tail -1 |
         grep -oE "[0-9.]+ tokens per second" | tail -1 | grep -oE "[0-9.]+")
    # Decode throughput is llama's own "eval time = ... / N tokens" line, NOT the wall time the
    # client saw: wall includes the synchronous disk-cache write charged to the request (~0.96 s/GiB),
    # which is worth ~15% on a 400-token generation. The first generation after a huge prefill is also
    # the one to drop - it decodes at full context right after 20 s of prompt-rate clocks.
    tg=$(grep -a "eval time = " "$ERRLOG" 2>/dev/null |
         grep -aE "/ +[0-9]{3,4} tokens" |
         grep -oE "[0-9.]+ tokens per second" | grep -oE "^[0-9.]+" | tail -3 |
         tr ' ' '\n' | grep -v '^$' | paste -sd+ - | awk -F+ '{s=0;n=0;for(i=1;i<=NF;i++){s+=$i;n++} if(n)printf "%.2f", s/n; else printf "?"}')
    echo "  $after"
    echo "  worst=$worst MiB  $verdict  pp=$pp"
    printf '%s\tOK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$s" \
      "$(echo "$idle" | cut -d' ' -f1)" "$(echo "$idle" | cut -d' ' -f2)" \
      "$post" "${worst:-?}" "${pp:-?}" "${tg:-?}" "${verdict:-?}" >> "$OUT"
    PASSED="$PASSED $s"
    BOOTTED="$s"
  else
    note=$(tail -3 /tmp/boot-$s.log | tr '\n' ' ' | tr -d '\r' | cut -c1-160)
    echo "  BOOT FAILED: $note"
    printf '%s\tFAIL\t%s\t%s\t-\t-\t-\t-\t%s\n' "$s" \
      "$(echo "$idle" | cut -d' ' -f1)" "$(echo "$idle" | cut -d' ' -f2)" "$note" >> "$OUT"
  fi
done
final="$KEEP"
case " $PASSED " in *" $KEEP "*) : ;; *) final="$DEFAULT_SPLIT" ;; esac
if [ "${LAND:-1}" = "0" ]; then
  # LAND=0: leave whatever the last successful boot was (or nothing, if every candidate failed) and
  # let the caller decide the end state. Used when the NEXT run in a chain continues from here, so a
  # chain does not waste a boot re-landing a config the next step is about to stop anyway.
  echo "--- LAND=0: not landing; last booted=${BOOTTED:-none}, passing=${PASSED:-none}"
  echo "### rows ($OUT):"; column -t -s "$(printf '\t')" "$OUT"
  exit 0
fi
echo "--- target end state: $final (last successfully booted: ${BOOTTED:-none})"

if [ "$BOOTTED" = "$final" ]; then
  echo "  already running $final - no extra boot (a second server would clash on :8000)"
else
  "${PS[@]}" -File 'C:\ModelServe\win\stop.ps1' >/dev/null 2>&1
  wait_dead || true
  if ! boot "$final"; then
    if [ "$final" = "$DEFAULT_SPLIT" ]; then
      echo "  !! $final did not boot and it IS the fallback - stopping here"
    else
      echo "  FINAL BOOT ($final) FAILED -> falling back to $DEFAULT_SPLIT"
      "${PS[@]}" -File 'C:\ModelServe\win\stop.ps1' >/dev/null 2>&1; wait_dead || true
      final="$DEFAULT_SPLIT"
      boot "$final" || echo "  !! NO CONFIG BOOTED - read /tmp/boot-*.log and $ERRLOG"
    fi
  fi
fi

m=$(curl -s --max-time 10 -H "Authorization: Bearer ${OMLX_API_KEY:-}" "$BASE/v1/models" |
    grep -oE '"id":"[^"]+"' | head -3 | tr '\n' ' ')
echo "  end state: split=$final  models=[$m]  free (3080 5070Ti) = $(free_pair)"
echo "### rows ($OUT):"; column -t -s "$(printf '\t')" "$OUT"
