#!/usr/bin/env bash
# decode225.sh — the missing number for the proposed default: decode throughput at q3l's real
# ceiling (225,280), with the pin + q8_0 draft KV, on the profile's own settings.
#
# Why this is needed: the +4.1% decode gain from the pin was measured at CTX 64K, where margins
# are fat. At 225,280 the compute buffers are ~10x larger (948-1016 MiB on the 3080 vs 191 at
# 64K), so the throughput delta cannot simply be carried over — it has to be measured where the
# profile will actually run. No -Ctx here on purpose: 225,280 is what `-P q3l` boots by default.
#
# Uses win/wsl-harness.sh primitives (win_launch / wait_ready / stop_win) rather than re-implement
# ing them — the interop-wait trap is already documented and solved there.
set -uo pipefail
ROOT=/home/naz/Projects/ModelServe
. "$ROOT/win/wsl-harness.sh" || exit 1
cd "$ROOT" || exit 1
export MODEL=qwen3.8-27b-l
JSONQ='Return a JSON array of 40 objects, each with the keys id, name, role, level, tags and active, following this exact repeating shape. Emit only the JSON, no prose. Sequence '

lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' ' ')
[ "$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)" = "2" ] || { echo "ABORT: need both GPUs"; exit 2; }
# Rail: exact per-card wattage, resolved by NAME. A substring match on the combined limit list
# could be satisfied by the wrong card (3080 at 275 with the 5070 Ti at 250 read as "250 present").
# 220/275 is the safety-tested pair; raise it only with a Linux-boot verdict behind it.
caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
{ [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; } || { echo "ABORT: caps ${w3080:-?}/${w5070:-?} W, want 220/275 ($lim)"; exit 2; }
echo "rails ok: caps [ $lim ]   BASE=$BASE"

stop_win || { echo "ABORT: previous server did not stop cleanly"; exit 1; }
win_launch /tmp/d225-launch.log "$WINSCRIPTS\\start.ps1" -P q3l -lv 4 \
  -ot "blk.64.*=CUDA0" -ctkd q8_0 -ctvd q8_0
if ! el=$(wait_ready 420); then echo "ABORT: not ready in 420 s"; tail -8 /tmp/d225-launch.log | tr -d '\0\r'; exit 1; fi
echo "ready in ${el}s (225,280 profile default)"

L=/mnt/c/ModelServe/logs/server.err.log
sleep 3; tr -d '\0\r' < "$L" > /tmp/d225.log; sleep 2; tr -d '\0\r' < "$L" > /tmp/d225.log
echo "--- verify this is the config we think it is (argv proved nothing tonight; -devd was in it) ---"
grep -o 'n_max=[0-9]*, n_min=[0-9]*' /tmp/d225.log | tail -1 | sed 's/^/    spec: /'
grep -o 'cache_k=[a-z0-9_]*, cache_v=[a-z0-9_]*' /tmp/d225.log | tail -1 | sed 's/^/    draft kv: /'
grep 'model buffer size' /tmp/d225.log | sed 's/^.*load_tensors: */    weights: /' | cut -c1-58
awk 'f && /KV buffer size/{print "    draft KV: " $4" "$9" MiB"; exit} /creating MTP draft/{f=1}' /tmp/d225.log
echo "    unused blk.64: $(grep -c 'unused tensor blk.64' /tmp/d225.log)  (0 = MTP loaded)"
nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ' | sed 's/^/    idle free [3080,5070Ti]: /'; echo

ROUNDS_PP=1 ROUNDS_TG=4 PP_TOKENS=6000 GEN_TOKENS=600 SEED_OFF=3 python3 perf-test.py > /tmp/d225-prose.txt 2>&1
ROUNDS_PP=1 ROUNDS_TG=4 PP_TOKENS=6000 GEN_TOKENS=600 SEED_OFF=7 TG_PROMPT="$JSONQ" python3 perf-test.py > /tmp/d225-json.txt 2>&1
sleep 2; tr -d '\0\r' < "$L" > /tmp/d225.log

echo "--- decode (round 0 discarded as post-boot warm-up) ---"
for f in prose json; do
  printf "    %-6s " $f
  grep -E '^  tg round' /tmp/d225-$f.txt | awk '$3+0>=1{for(i=1;i<=NF;i++)if($i~/tok\/s/)r=$(i-1); s+=r;n++; if(mn==""||r<mn)mn=r; if(r>mx)mx=r} END{if(n)printf "mean %.1f tok/s (n=%d, %.1f-%.1f)\n",s/n,n,mn,mx; else print "no rows"}'
done
st=$(grep 'spec common_specu: statistics' /tmp/d225.log | tail -1)
g=$(printf '%s' "$st" | sed -n 's/.*#gen drafts = *\([0-9]*\).*/\1/p')
dg=$(printf '%s' "$st" | sed -n 's/.*dur(b,g,a) = *[0-9.]*, *\([0-9.]*\), *[0-9.]* *ms.*/\1/p')
ml=$(printf '%s' "$st" | sed -n 's/.*#mean acc len = *\([0-9.]*\).*/\1/p')
awk -v g="$g" -v d="$dg" -v m="$ml" 'BEGIN{if(g+0>0)printf "    cumulative: %d drafts, mean acc len %s, %.2f ms/draft\n", g, m, d/g}'
nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ' | sed 's/^/    free after load [3080,5070Ti]: /'; echo

stop_win && echo "stopped." || echo "WARN: stop_win reported unclean"
