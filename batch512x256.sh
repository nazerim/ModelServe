#!/usr/bin/env bash
# batch512x256.sh — does -Batch 512 -Ubatch 256 work at 225,280, and what does it cost / buy?
#
# Prior measurement (163,840, split 15,10): 512/128 and 1024/128 left the SAME margin (151/173),
# while 1024/256 dropped to 45/59. So n_ubatch, not n_batch, is the expensive dimension. That makes
# 512/256 the informative probe: it isolates the ubatch cost at the smallest batch that still
# allows it (n_batch must be a multiple of n_ubatch, and >= it).
#
# Prediction, stated before measuring: 512/256 pays ~110 MiB relative to the 512/128 control, so
# the binding card lands near ~370 MiB -> MARGINAL. If instead it matches the control, the earlier
# slope was driven by n_batch after all and the model is wrong. Either way the compute-buffer line
# from the -lv 4 log is the mechanism to read: the 3080 OOMed at 225,280 earlier on a 1,141 MiB
# compute allocation, and that buffer scales with these two numbers.
#
# Payoff measured alongside: prompt processing at ~31K tokens (stability's WORDS default), taken
# from the server's OWN "prompt eval time" lines, plus the per-card min-free pair — margin verdicts
# at this size are ambient-dependent (the 5070 Ti's load flipped a verdict last run), so a verdict
# without the per-card numbers is not evidence.
#
# Rails: both GPUs + caps before each boot; abort on any NEW nvlddmkm event; no ctx above the
# certified 225,280; stop if an arm fails to boot twice.
set -uo pipefail
cd /home/naz/Projects/ModelServe || exit 1
CTX=225280
BASE_FLAGS="-lv 4 -ot blk.64.*=CUDA0 -ctkd q8_0 -ctvd q8_0"
TSV=/tmp/batch512.tsv
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
nvcnt() { powershell.exe -NoProfile -Command "(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='nvlddmkm'} -MaxEvents 200 -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\0' | tr -d '[:space:]'; }
base=$(nvcnt); echo "nvlddmkm baseline: $base  ($(date +%H:%M:%S))"
printf 'arm\trep\tambient3080\terr3080\tfree3080\tfree5070Ti\tverdict\tpp_best\tpp_med\tCUDA0comp\tCUDA1comp\n' > "$TSV"

for rep in 1 2 3; do
 for arm in "512 128" "512 256"; do
  set -- $arm; bb=$1; ub=$2; tag="${bb}x${ub}-r${rep}"
  lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' ' ')
  gpus=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  if [ "$gpus" != "2" ]; then echo "ABORT: gpus=$gpus"; exit 2; fi
  # exact per-card watts, by name (a substring match on the combined list can be satisfied by
  # the wrong card). 220/275 = the safety-tested pair.
  caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
  w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
  w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
  { [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; } || { echo "ABORT: caps ${w3080:-?}/${w5070:-?} W, want 220/275 ($lim)"; exit 2; }
  read -r amb3080 _ < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr '\n' ' ')
  read -r idlef3080 idlef50pre < <(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr -d '\r' | tr ',' ' ' | tr '\n' ' ')
  echo "=== $tag  (ambient 3080 = ${amb3080} MiB)  $(date +%H:%M:%S)"
  OUT=/tmp/b-$tag.tsv EXTRA="$BASE_FLAGS -Ctx $CTX -Batch $bb -Ubatch $ub" \
    ./win/stability-from-wsl.sh 1 q3l > /tmp/b-$tag.out 2>&1
  mf=$(grep -o 'min-free=\[[0-9, ]*\]' /tmp/b-$tag.out | tail -1)
  v=$(awk -F'\t' 'NR==2{print $10}' /tmp/b-$tag.tsv)
  f3080=$(printf '%s' "$mf" | sed -n 's/.*\[\([0-9]*\),.*/\1/p'); f50=$(printf '%s' "$mf" | sed -n 's/.*,\([0-9]*\).*/\1/p')
  L=/tmp/errlog-b-$tag.log
  if [ -f "$L" ]; then
    p=$(grep -oE 'prompt eval time = *[0-9.]+ ms */ *[0-9,]+ tokens\( *[0-9.]+' "$L" | grep -oE '[0-9.]+$' | sort -n)
    pb=$(printf '%s' "$p" | tail -1); pm=$(printf '%s' "$p" | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    c0=$(grep 'CUDA0 compute buffer' "$L" | sed -n 's/.*= *\([0-9.]*\) MiB.*/\1/p' | tail -1)
    c1=$(grep 'CUDA1 compute buffer' "$L" | sed -n 's/.*= *\([0-9.]*\) MiB.*/\1/p' | tail -1)
    grep -E 'out of memory|CUDA error|failed to allocate' "$L" | head -2 | cut -c1-120 | sed 's/^/    /'
  else p=""; pb="?"; pm="?"; c0="?"; c1="?"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$bb/$ub" "$rep" "$amb3080" "${idlef3080:-?}" "$f3080" "$f50" "$v" "${pb:-?}" "${pm:-?}" "$c0" "$c1" >> "$TSV"
  echo "    verdict=$v  per-card free=[3080=$f3080, 5070Ti=$f50]  pp best=${pb:-?} med=${pm:-?}  compute=[${c0:-?} / ${c1:-?} MiB]"
  now=$(nvcnt); if [ "${now:-$base}" -gt "$base" ]; then echo "ABORT: NEW nvlddmkm event(s) ($base -> $now). Stopping."; break 2; fi
 done
done

echo; column -t -s$'\t' "$TSV"; echo "nvlddmkm now: $(nvcnt) (baseline $base)"
timeout 90 "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\ModelServe\win\stop.ps1' >/dev/null 2>&1
echo "stopped; free: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ')"
