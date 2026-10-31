#!/usr/bin/env bash
# edge5.sh — is q3l at 225,280 STABLE near the margin line, with pin + q8_0 draft KV?
#
# The question this answers, and why it is now answerable: margin-check.py's verdict is a margin
# HEURISTIC (SAFE >=400, MARGINAL 240-400, UNSAFE <240 "this box has aborted here"). It is not a
# crash predictor. Two facts let us test that distinction directly:
#   - the driver's own error log (nvlddmkm 13/14/153, the fall-off-bus signature) has been silent
#     since 19/09 01:19, across every boot tonight including a hard cudaMalloc OOM. So the edge
#     failure mode here is a process abort, not GPU loss.
#   - pin+q8 booted 2/2 at 291-329 MiB while q8-only OOMed at the same ctx: the 3080 must fit a
#     ~1.14 GiB compute buffer, and the pin is what makes space for it. So this is the candidate.
#
# Each iteration records the 3080's AMBIENT usage before the boot, so "stable" can be separated
# from "lucky": if the passes line up with low Norton residency and the failures with high, the
# ceiling is not a property of the config alone — which is the thing worth knowing before anyone
# advertises 225,280 to clients.
#
# Rails: caps + both GPUs before each boot; ABORT immediately on any NEW nvlddmkm event or two
# consecutive boot failures. No escalation of ctx beyond 225,280 anywhere in this file.
set -uo pipefail
cd /home/naz/Projects/ModelServe || exit 1
EXTRAARGS="-lv 4 -ot blk.64.*=CUDA0 -ctkd q8_0 -ctvd q8_0"
TSV=/tmp/edge5.tsv
nvcnt() { powershell.exe -NoProfile -Command "(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='nvlddmkm'} -MaxEvents 200 -ErrorAction SilentlyContinue | Measure-Object).Count" 2>/dev/null | tr -d '\0' | tr -d '[:space:]'; }
base=$(nvcnt); echo "nvlddmkm event baseline: $base  ($(date +%H:%M:%S))"
printf 'iter\tambient_3080_used\tidle_free_3080\tidle_free_5070Ti\tboot_s\tworst_free\tstatus\tnew_nv\n' > "$TSV"
fails=0
for i in $(seq 1 5); do
  lim=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader,nounits | tr '\n' ' ')
  gpus=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
  if [ "$gpus" != "2" ]; then echo "ABORT iter $i: gpus=$gpus"; break; fi
  # exact per-card watts, by name (a substring match on the combined list can be satisfied by
  # the wrong card). 220/275 = the safety-tested pair.
  caps=$(nvidia-smi --query-gpu=name,power.limit --format=csv,noheader,nounits)
  w3080=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 3080/{print $2+0}')
  w5070=$(printf '%s\n' "$caps" | awk -F', *' '/RTX 5070 Ti/{print $2+0}')
  if ! { [ "${w3080:-}" = 220 ] && [ "${w5070:-}" = 275 ]; }; then echo "ABORT iter $i: caps ${w3080:-?}/${w5070:-?} W, want 220/275 ($lim)"; break; fi
  read -r u3080 _ < <(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | tr '\n' ' ')
  read -r f3080 f5070 < <(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ')
  OUT=/tmp/edge5-r.tsv EXTRA="$EXTRAARGS" ./win/stability-from-wsl.sh 1 q3l > /tmp/edge5-$i.out 2>&1
  st=$(awk -F'\t' 'NR==2{print $10}' /tmp/edge5-r.tsv)
  wf=$(awk -F'\t' 'NR==2{print $8}' /tmp/edge5-r.tsv)
  bt=$(awk -F'\t' 'NR==2{print $7}' /tmp/edge5-r.tsv)
  now=$(nvcnt); new=$(( ${now:-$base} - base )); [ "$new" -lt 0 ] && new=0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$u3080" "$f3080" "$f5070" "$bt" "$wf" "$st" "$new" >> "$TSV"
  echo "  iter $i: ambient3080=${u3080}MiB idlefree=${f3080}/${f5070} boot=${bt}s worst=${wf} ${st} new_nvlddmkm=${new}"
  if [ "$new" -gt 0 ]; then echo "ABORT: $new NEW nvlddmkm event(s) — driver is signalling. Stopping."; break; fi
  if [ "$st" = "BOOTFAIL" ]; then fails=$((fails+1)); if [ "$fails" -ge 2 ]; then echo "ABORT: 2 consecutive boot failures."; break; fi; else fails=0; fi
done
echo; column -t -s$'\t' "$TSV"
echo; echo "nvlddmkm now: $(nvcnt)  (baseline $base)"
timeout 90 /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\ModelServe\win\stop.ps1' >/dev/null 2>&1
echo "stopped; free now: $(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr '\n' ' ')"
