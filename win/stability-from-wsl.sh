#!/usr/bin/env bash
# stability-from-wsl.sh — N identical boots of the NATIVE-Windows server, margin sampled UNDER
# LOAD. Twin of stability.sh; same question, same verdict columns, different host for the boot.
# Shared primitives (and the reason launches are async) live in win/wsl-harness.sh.
#
# One clean run proves nothing: the ext4 record has a single pass at 705 MiB "SAFE" followed by
# an identical repeat that reset the host. The native path adds a second interference source the
# WSL path never had — the antivirus can suspend llama-server.exe mid-load — so "does it boot
# the same way every time" is exactly the claim worth testing.
#
# The desktop baseline is captured BEFORE each boot on purpose: a margin number without one is
# uninterpretable (that baseline swung 961 -> 1,721 MiB and flipped a "471 MiB SAFE" into 183).
#
#   ./stability-from-wsl.sh 1 q3     # one round: verify the harness cheaply
#   ./stability-from-wsl.sh 3 q3     # the real thing
#   WORDS=30000 ROUNDS=2 ./stability-from-wsl.sh 3 q3
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/win/wsl-harness.sh" || exit 1

N="${1:-3}"; PROFILE="${2:-q3}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
export WORDS="${WORDS:-30000}" ROUNDS="${ROUNDS:-2}"

# Deliberately no hard-coded profile list: the ctx, split AND alias are read back from
# serve.ps1 -DryRun below, so adding a profile to config.ps1 is enough - this script cannot
# drift out of date with the table it is supposed to be testing.
if [ -n "${3:-}" ]; then echo "note: 3rd arg ignored; use EXTRA to pass serve.ps1 switches" >&2; fi

OUT="${OUT:-stability-win-$PROFILE.tsv}"
# EXTRA forwards raw serve.ps1 switches (-Split 19,6 -Batch 512 -Ubatch 128 ...). They must be
# ARGUMENTS, not environment: WSL env vars do not reach Windows processes unless listed in
# WSLENV, so "Q=q3 ./start.sh" style overrides that work on the Linux side are a no-op across
# the bridge. The same array is passed to the -DryRun below, so the TSV records the split that
# actually booted rather than the profile default.
read -r -a EXTRA_ARGS <<<"${EXTRA:-}"
if [ -n "${EXTRA_ARGS[*]-}" ]; then echo "extra args: ${EXTRA_ARGS[*]}"; fi
# Authoritative prompt-processing rate comes from the server's own log, not margin-check's wall
# time (which includes the generated tokens - its header warns about exactly this).
SERVER_ERRLOG="${SERVER_ERRLOG:-/mnt/c/ModelServe/logs/server.err.log}"
printf 'profile\tround\tdesktop_5070Ti_mib\tctx\tsplit\tbatch\tboot_s\tworst_free\tmin_gen_s\tstatus\tcommit_free_gb\thost_ram_free_gb\tbin\tcache\n' > "$OUT"

# ctx/split come from the script's own DRY output - one source of truth, the same trick
# stability.sh uses with "DRY=1 ./serve.sh". This call is synchronous because it leaves nothing
# behind; a launch would not be (see wsl-harness.sh).
dry=$(win_run "$WINSCRIPTS\\serve.ps1" 120 -P "$PROFILE" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} -DryRun)
ctx=$(prof_field "$dry" CTX)
sp=$(prof_field "$dry" SPLIT)
bat=$(prof_field "$dry" BATCH)
# Which binary and which cache identity produced this row. The default boot is now the patched
# fork build, not the pinned b11034 the ceilings were measured on, so a row without BIN is not
# comparable with one from before the flip - and CACHE identifies the on-disk entry set a run ran
# against, which changes what a boot has to re-prefill.
bin=$(prof_field "$dry" BIN)
cache=$(prof_field "$dry" CACHE)
alias_model=$(prof_field "$dry" ALIAS)
# Anchored to serve.ps1's summary line on purpose: the same output also contains a clamp note
# ("note: CTX=221184 exceeds the ceiling in force (196608)...") and win_run merges the streams, so
# an unanchored CTX= grep records the REQUESTED size - reproducing "221184 SAFE" for a boot that
# ran 196,608. The Linux twin dodges this only because serve.sh writes that note to stderr.
[ -n "$ctx" ] || { echo "could not resolve the profile from serve.ps1 -DryRun:" >&2; echo "$dry" | head -3 >&2; exit 1; }
echo "target: $BASE  profile=$PROFILE alias=$alias_model  CTX=$ctx SPLIT=$sp BATCH=$bat  WORDS=$WORDS ROUNDS=$ROUNDS"

for i in $(seq 1 "$N"); do
  # A stop that could not be confirmed means the OLD server is still answering; measuring now
  # would attach this profile's numbers to a boot that is not ours. Skip the round, do not lie.
  stop_win || { echo "  round $i SKIPPED: previous server did not stop cleanly" ; printf '%s\t%s\t-\t%s\t%s\t%s\t-\t-\t-\tSTOPFAIL\t-\t-\t%s\t%s\n' "$PROFILE" "$i" "$ctx" "$sp" "${bat:-?}" "${bin:-?}" "${cache:-?}" >> "$OUT"; continue; }
  pp=""   # do not carry a previous round's pp into this round's line
  desk=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sed -n 2p | tr -d ' ')
  caps=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' '/')
  echo "===== $PROFILE round $i/$N (desktop baseline ${desk} MiB, caps $caps)"
  log="/tmp/stabwin-$i.log"; : > "$log"
  win_launch "$log" "$WINSCRIPTS\\start.ps1" -P "$PROFILE" -TimeoutSec "$BOOT_TIMEOUT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  printf '  booting...'
  if boot=$(wait_ready "$BOOT_TIMEOUT"); then
    echo " ready in ${boot}s"
    # Prove the answering server is THIS boot before a single number is recorded. llama.cpp ignores
    # the model name in requests, so a stale server produces a plausible SAFE row for a
    # configuration that is not running - which has already happened once on this box.
    assert_identity "$alias_model" "$ctx" || { st="IDENTITY"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t%s\t-\t-\t%s\t%s\n' "$PROFILE" "$i" "${desk:-?}" "$ctx" "$sp" "${bat:-?}" "$boot" "$st" "${bin:-?}" "${cache:-?}" >> "$OUT"; continue; }
    echo "  then margin under load (${WORDS}-word prefill x$ROUNDS + 3 long gens)"
    res=$(MODEL="$alias_model" timeout 900 python3 "$ROOT/margin-check.py" 2>&1)
    echo "$res" | grep -E 'round [0-9]|gen [0-9]|WORST-CASE' | sed 's/^/    /'
    worst=$(grep -oE 'WORST-CASE FREE = [0-9]+' <<<"$res" | grep -oE '[0-9]+')
    slow=$(grep -oE 'gen [0-9]: [0-9]+ tok in [0-9.]+' <<<"$res" | awk '{print $NF}' | sort -rn | head -1)
    st=$(grep -oE '(SAFE|MARGINAL|UNSAFE)' <<<"$res" | tail -1)
    [ -n "$st" ] || st="NOVERDICT"
    # Authoritative pp, from the server's own print_timing. Two filters matter: require a
    # 4+ digit token count (MTP drafts log their own tiny "prompt eval time" lines, and those
    # were what this grabbed before - 30 tok/s for a 3-token speculative prompt), and pull the
    # number INSIDE the parentheses, not the first float on the line.
    pp=$(grep -a 'prompt eval time' "$SERVER_ERRLOG" 2>/dev/null | grep -E '/ *[0-9]{4,} tokens' | tail -2 |
         sed -E 's/.*, *([0-9.]+) tokens per second\).*/\1/' | tr '\n' ' ')
    # Preserve the log: each boot truncates it, so the evidence for THIS round would otherwise be
    # destroyed by the next one.
    cp -f "$SERVER_ERRLOG" "/tmp/errlog-$(basename "$OUT" .tsv).log" 2>/dev/null || true
  else
    echo " FAIL after ${boot}s (see $log)"; desk="${desk:-?}"
    worst=-; slow=-; st="BOOTFAIL"
    tail -3 "$log" | tr -d '\0\r' | cut -c1-140 | sed 's/^/    /'
  fi
  read -r rf cf <<<"$(host_headroom)"
  echo "  round $i -> ${st}  worst_free=${worst} MiB  slowest-gen=${slow}s  pp=${pp:-?} tok/s  (host RAM ${rf} GB / commit ${cf} GB free)"
  # status is column 10; named positionally on purpose, since a hard-coded $NF broke a whole run's
  # counting once when a column was appended. batch is a column because the repo's own conclusion is
  # that the prompt batch is part of the measurement, not a preference.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$PROFILE" "$i" "$desk" "$ctx" "$sp" "${bat:-?}" "${boot:-?}" "${worst}" "${slow}" "$st" "${cf:-?}" "${rf:-?}" "${bin:-?}" "${cache:-?}" >> "$OUT"
done

stop_win
echo; echo "  GPU after test: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ')"
echo "=== $OUT ==="; column -t -s $'\t' "$OUT" 2>/dev/null || cat "$OUT"
# status is column 9; named positionally on purpose, since a hard-coded $NF broke a whole run's
# counting once a column was appended.
read -r u t < <(awk -F'\t' 'NR>1{n++; if($10=="SAFE") s++} END{print s+0, n+0}' "$OUT")
echo "VERDICT: $u/$t rounds SAFE"
[ "$u" = "$t" ] || echo "  not all clean - lowest worst_free: $(awk -F'\t' 'NR>1&&$8 ~ /^[0-9]+$/{print $8}' "$OUT" | sort -n | head -1) MiB"
