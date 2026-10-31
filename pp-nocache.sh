#!/usr/bin/env bash
# pp-nocache.sh — cold prompt-processing cost of 512/128 vs 512/256, with the disk cache OFF.
#
# Why this exists: the profiles boot with --cache-dir + -ctxcp 12, so a repeated large prompt is
# loaded from disk instead of computed. Every "pp=?" in this session's logs is a cache hit, not a
# failure to measure, and margin-check's second round reuses the first round's prefix (34.5s vs
# 10.6s on an identical prompt). Comparing batch sizes on those numbers would compare caches.
#
# -NoCacheDir removes the disk tier; ROUNDS=1 removes the in-process prefix reuse, so each boot
# yields exactly one cold pp measurement of a ~31K-token prompt. Two boots per arm, interleaved.
set -uo pipefail
cd /home/naz/Projects/ModelServe || exit 1
BASE_FLAGS="-lv 4 -ot blk.64.*=CUDA0 -ctkd q8_0 -ctvd q8_0 -NoCacheDir"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
nvcnt() { powershell.exe -NoProfile -Command "(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='nvlddmkm'} -MaxEvents 200 -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\0' | tr -d '[:space:]'; }
base=$(nvcnt); echo "nvlddmkm baseline: $base"
printf 'arm\trep\tpp_cold_ms\tpp_tok\tpp_toks_s\tfree3080\tverdict\n' > /tmp/pp-nocache.tsv

for rep in $(seq 1 ${PP_REPS:-2}); do
  for arm in ${PP_ARMS:-"512:128 512:256"}; do
    bb=${arm%%:*}; ub=${arm##*:}; tag="nc-${bb}x${ub}-${rep}"
    lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' ' ')
    [ "$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)" = "2" ] || { echo "ABORT: gpu count"; exit 2; }
    # exact per-card watts, by name (a substring match on the combined list can be satisfied by
    # the wrong card). 220/275 = the safety-tested pair.
    caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
    w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
    w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
    { [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; } || { echo "ABORT: caps ${w3080:-?}/${w5070:-?} W, want 220/275 ($lim)"; exit 2; }
    echo "=== $tag $(date +%H:%M:%S)"
    ROUNDS=1 OUT=/tmp/$tag.tsv EXTRA="$BASE_FLAGS -Ctx 225280 -Batch $bb -Ubatch $ub" \
      ./win/stability-from-wsl.sh 1 q3l > /tmp/$tag.out 2>&1
    v=$(awk -F'\t' 'NR==2{print $10}' /tmp/$tag.tsv); f=$(awk -F'\t' 'NR==2{print $8}' /tmp/$tag.tsv)
    line=$(grep -a 'prompt eval time' /tmp/errlog-$tag.log 2>/dev/null | grep -E '/ *[0-9]{4,} tokens' | tail -1)
    ms=$(printf '%s' "$line"  | sed -n 's/.*= *\([0-9.]*\) ms.*/\1/p')
    tk=$(printf '%s' "$line"  | sed -n 's|.*ms */ *\([0-9,]*\) tokens.*|\1|p' | tr -d ',')
    rate=$(printf '%s' "$line" | sed -n 's/.*(\(.*\)tokens per second.*/\1/p' | grep -oE '[0-9.]+' | tail -1)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$bb/$ub" "$rep" "${ms:-?}" "${tk:-?}" "${rate:-?}" "$f" "$v" >> /tmp/pp-nocache.tsv
    echo "    cold pp: ${rate:-?} tok/s  (${tk:-?} tokens in ${ms:-?} ms)  free3080=$f  $v"
    now=$(nvcnt); if [ "${now:-$base}" -gt "$base" ]; then echo "ABORT: new nvlddmkm event"; break 2; fi
  done
done
echo; column -t -s$'\t' /tmp/pp-nocache.tsv
echo; echo "=== per-arm summary (cold pp; 512/128 is the current q3l setting) ==="
awk -F'\t' 'NR>1 && $5!="?" { n[$1]++; s[$1]+=$5; ss[$1]+=$5*$5; if($6!="") { m[$1]++; ms[$1]+=$6 } }
  END {
    for (a in n) { mean=s[a]/n[a]; var=(ss[a]-n[a]*mean*mean)/(n[a]>1?n[a]-1:1); if(var<0)var=0;
      sd=sqrt(var); sem=sd/sqrt(n[a]);
      printf "%-9s n=%d  mean %7.1f tok/s  sd %5.1f  sem %4.1f  | 3080 free mean %6.1f MiB\n", a, n[a], mean, sd, sem, (m[a]?ms[a]/m[a]:0) }
  }' /tmp/pp-nocache.tsv
awk -F'\t' 'NR>1 && $5!="?" { a=($1=="1024/128")?"A":"B"; n[a]++; s[a]+=$5; ss[a]+=$5*$5 }
  END { if(n["A"]&&n["B"]) {
    ma=s["A"]/n["A"]; mb=s["B"]/n["B"]; va=(ss["A"]-n["A"]*ma*ma)/(n["A"]-1>0?n["A"]-1:1); vb=(ss["B"]-n["B"]*mb*mb)/(n["B"]-1>0?n["B"]-1:1);
    if(va<0)va=0; if(vb<0)vb=0; se=sqrt(va/n["A"]+vb/n["B"]);
    printf "\ndelta 1024/128 - 512/128 = %+.1f tok/s (%.1f%%), SE %.1f -> t = %.2f (n=%d/%d). t>2.2 ~ 95%% for df>=4.\n", ma-mb, 100*(ma-mb)/mb, se, (ma-mb)/se, n["A"], n["B"] } }' /tmp/pp-nocache.tsv
echo "nvlddmkm now: $(nvcnt) (baseline $base)"
timeout 90 "$PS" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\ModelServe\win\stop.ps1' >/dev/null 2>&1
echo "stopped; free: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ')"
