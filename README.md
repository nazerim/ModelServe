# Qwen3.8-27B GGUF on WSL2 (RTX 5070 Ti + RTX 3080) — working setup

Status: **running and verified**. `./start.sh` → http://127.0.0.1:8000
Repo: `~/Projects/ModelServe`. Models live in `~/.models` and are never in-tree.
Machine facts and the GPU-role split live in `~/nodes/002-hardware.md`; the serving
measurements in `~/nodes/004-*.md` and `~/nodes/005-*.md`.

## What the file actually is (read out of the GGUF, not guessed)

| key | value |
|---|---|
| `general.architecture` | **`qwen35`** — hybrid Gated DeltaNet (linear attn) + full attention every 4th layer |
| `qwen35.block_count` | 65 = 64 trunk + **1 MTP layer** (`blk.0`–`blk.64`) |
| KV-bearing blocks | **17** (3,7,…,63 + blk.64) — the other **48 are DeltaNet and hold no per-token KV** |
| `qwen35.nextn_predict_layers` | 1 → MTP head is **in the main file** (`blk.64.nextn.*`); no sidecar, no redownload |
| `qwen35.context_length` | 262144 native |
| `general.file_type` | 15 = Q4_K_XL, imatrix-quantised by Unsloth |
| mmproj | `clip` arch, `projector_type = qwen3vl_merger`, 27-block ViT, deepstack, 0.86 GiB |

Weights: 16.34 GiB main + 0.86 GiB mmproj = **17.2 GiB** → both GPUs required.
System RAM is **15 GB**, so never offload weights to CPU.

## Install (no sudo, no compiler, no CUDA toolkit)

llama.cpp ships official **Ubuntu CUDA** prebuilts, and the `cudart-` companion carries
the CUDA 13 runtime, so nothing is installed system-wide:

```
llama/         llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz         (143 MB, binaries)
cudart-libs/   cudart-llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz  (392 MB, libcudart/libcublas.so.13)
libs/          apt-get download libgomp1 + dpkg-deb -x              (the one missing .so)
~/.models/     the GGUFs + mmproj (moved out of ~/.models on 2026-09-18)
```

Verified: `libggml-cuda.so` contains `sm_86 sm_89 sm_120a sm_121a` cubins → covers both
cards. `--list-devices` reports **CUDA0 = 5070 Ti (15009 MiB free), CUDA1 = 3080 (9069)** —
the order is *inverted* vs nvidia-smi, hence `--tensor-split 19,6` favouring the 5070 Ti.

Models live in **`~/.models`** on ext4, because `/mnt/m` is 9P at **127 MB/s** (~2.5 min
cold load per start) while from ext4 the load takes **~15 s**.

## Run

```bash
start.sh            # detached; polls until loaded (96K takes ~35 s, so no fixed sleep)
serve.sh            # foreground
test.sh             # live flags -> capabilities -> tok/s -> MTP acceptance -> vision
stop.sh
start.sh --api-key <your-key>          # extra args pass straight through

# knobs (env): Q TIER MODEL CTX NPRED SPLIT NP PORT HOST NGL KV MM BIN
Q=q3 TIER=large start.sh          # 180,224 ctx on the Q3_K_XL file
Q=q4            start.sh          # higher quality, clamped to 114,688 max
DRY=1 Q=q4 TIER=large serve.sh    # print the resolved command, don't launch
MODEL=/some/other.gguf serve.sh   # bypass Q= entirely (no ceiling clamp)
ctx-test.sh 65536 98304 114688         # VRAM + tok/s at a list of context sizes
iq-ladder.sh Qwen3.8-27B-UD-Q3_K_XL.gguf   # per-quant ceiling, stops at first FAIL
sweep.sh "CTX=81920 KV=q8_0 SPLIT=17,8"    # over split/KV/ngl specs
kv-sweep.sh q8_0 q4_0                   # KV-quant quality: retrieval + drift + KL/JSD
get-quant.sh Qwen3.8-27B-UD-Q3_K_XL.gguf   # resume-capable HF fetch
gguf-peek.py unsloth/Qwen3.8-27B-GGUF <f>  # header peek, no download
sizing.py                               # calibrated feasibility model
```

### Profiles

| | | |
|---|---|---|
| `Q=q3` *(default)* | `Qwen3.8-27B-UD-Q3_K_XL.gguf` 12.24 GiB | safe ceiling **196,608** (at `SPLIT=18,7`) |
| `Q=q4` | `Qwen3.8-27B-UD-Q4_K_XL.gguf` 16.35 GiB | safe ceiling **114,688** |
| `TIER=small` | 32,768 ctx | low latency, lots of headroom |
| `TIER=medium` | 98,304 ctx | comfortable on both quants |
| `TIER=large` | 180,224 ctx | Q3 only — **auto-clamped to 114,688 for q4** |
| `TIER=max` *(default)* | the quant's **safe** ceiling: q3 196,608 / q4 114,688 | |

The safe ceiling depends on the **split**: at `19,6` the q3 max (196,608) leaves the display
GPU only **98 MiB**, well under this box's abort threshold; at **`18,7`** the same size keeps
**420–441 MiB** and booted 6/6. Rebalancing *does* also buy raw capacity for the heavier
quants (Q4_K_XL 114,688 → 122,880; IQ4_XS 163,840 → 188,416) — but only at **109–13 MiB** of
slack, i.e. unusable. Past 196,608 it stops failing cleanly: 204,800 puts the driver into
`CUDA error: device not ready`. KV is reserved for the whole `-c` regardless of how much you
use, so a bigger `-c` costs VRAM even when an agent compacts long before reaching it.

Default resolved config: **Q=q3 · TIER=max (CTX=196,608) · NPRED=32768 · PORT=8000 ·
SPLIT=18,7 · NGL=99 · KV=q8_0 · MM=cpu**; `PORT`/`HOST`/`MODEL_DIR` come from
`config.sh` and an env override still wins. Verified green: 52–56 tok/s, MTP
acceptance ~0.64, **2/2 real photos identified**.

`NPRED=32768` is the default output budget (`-1` = until the context fills). Unknown `Q`
values and missing model files are rejected rather than silently falling back, and
`serve.sh` clamps `CTX` above the measured ceiling with a note. Effective default command:

```
-m $MODEL --mmproj ~/.models/mmproj-F16.gguf
--jinja --image-min-tokens 1024 --no-mmproj-offload
-ngl 99 -sm layer --tensor-split 18,7
-c 98304 -np 1 -n 32768 -ctk q8_0 -ctv q8_0
--spec-type draft-mtp --spec-draft-n-max 2
--host 127.0.0.1 --port 8000 --alias qwen3.8-27b
```

## Measured (this machine)

| | |
|---|---|
| load → listening | 15.6 s (32K) · ~35 s (96K) |
| generation **with** MTP | **46–56 tok/s** (acceptance 0.54–0.85, mean draft len ~2.1) |
| generation **without** MTP | 25.7 tok/s → **MTP ≈ 1.9×**; keep it on |
| prompt processing | **1301 tok/s** at default batch, 1201 at `-b 1024` → 200K cold ≈ 2.8 min |
| KV cost | **f16 80 · q8_0 37.8 · q4_0 ~23 KiB/token** (measured; only 17/65 blocks hold KV) |
| vision latency | ~2.5–3.3 s/image on GPU · **~17.5 s/image on CPU** |

### Context ceilings, Q4_K_XL weights (`-ngl 99`, split 19,6)

| KV | vision on GPU | vision on CPU |
|---|---|---|
| f16 | 49152 ✓ / 57344 ✗ | — |
| **q8_0** | 65536 ✓, **≥73724 SIGABRTs the first image** | **114688 ✓ 47.2 tok/s** · 122880 ✗ |
| q4_0 | 98304 ✓ ~45 | 196608 ✗ · 245760 ✗ |

### Lessons from the ~200K hunt

(The per-quant ladder itself now lives in one place: **“Models on hand, and the context
each reaches”** above. An earlier copy of that table stayed here with contended, pre-`18,7`
numbers and was removed rather than left to contradict it.)

**IQ4_XS is 1 GiB *smaller* yet yielded *less* usable context than Q4_K_XL**, because IQ
codebook types need far larger CUDA dequant scratch (~4.5 GiB non-KV overhead vs ~2.6 GiB for
K-types). "1 GiB saved ≈ 28K tokens" holds only *within* a quant family — the pre-test
predictions were ~15% optimistic for exactly that reason, which is why every ceiling in this
repo is measured by booting, not extrapolated.

Vision is not the lever and neither is KV quantisation: `-mmdev CUDA1` (projector on the
3080) gives GPU-speed images but caps at 98,304, and q4_0 KV measured **fail** at 192K despite
theory. `--tensor-split 16,9` cannot rescue 196,608 either — it just moves the OOM onto the
3080. So the practical choice is **context → Q3_K_XL** or **quality → Q4_K_XL**.

### KV quantisation quality (q8_0 vs q4_0), 60,136-token prompt

Both retrieved **3/3 needles with byte-identical answers**; greedy argmax identical at
249/250 generation positions; median JSD 0.0000 (1/250 positions above 0.01). So q4_0 was
not measurably worse *on this test* — but it is one synthetic-filler probe, and q4_0 still
failed the memory ladder above, so stay on q8_0.

### Vision with real photos — speed and max context are mutually exclusive

Identified **2/2 correctly** either way (`testimg/Cat.jpg`, `testimg/Dog.jpg` from Wikipedia
Commons; `vision-check.py`). Cold latency, first sight of each image:

| config | cat 982x1000 (**1122** img tok) | dog 3840x2550 (**4122** img tok) | ctx ceiling |
|---|---|---|---|
| `MM=cpu` `TIER=max` *(default)* | 22.5 s | **182.7 s** | 196,608 |
| `MM=3080` `TIER=medium` | **3.8 s** | **10.9 s** | 98,304 |

The CPU projector is 5–17x slower and the penalty **grows steeply with resolution**, so one
full-res photo costs ~3 minutes — that, not the ~17 s seen on small images, is the true
price of "images are infrequent". **You cannot have both:** `MM=3080 TIER=max` aborts at
startup with `GGML_ASSERT(buffer) failed` (`ggml-backend.cpp:188`). Warm re-asks are
near-instant (2.7 s / 8.1 s) thanks to the KV prefix cache, so keep requests append-only.

## Models on hand, and the context each reaches

All rows are **measured** on this box with the production config: `-ngl 99`, `-sm layer`,
`-ctk q8_0 -ctv q8_0`, projector on CPU (`--no-mmproj-offload`). Weights live in
`~/.models` and are never committed.

| file | size | split | safe ctx (≥~400 MiB free) | free at safe ctx | max that boots | free there |
|---|---|---|---|---|---|---|
| **`Q3_K_XL`** ← default | 12.24 GiB | 18,7 | **212,992** | 508 MiB | 225,280 | 258 MiB |
| **`Q4_K_S`** | 14.30 GiB | 18,7 | **163,840** | 530 MiB | 184,320 | ~72 MiB |
| **`Q4_K_XL`** | 16.35 GiB | 18,7 | **122,880** | ~400 MiB (interpolated) | 135,168 | 192 MiB |
| ~~`IQ4_XS`~~ deleted | 13.27 GiB | 18,7 | — | — | 188,416 | **13 MiB** |
| `mmproj-F16` | 0.86 GiB | — | on CPU (`MM=cpu`) | — | — | — |

All rows with `-b 1024 -ub 256`, `-ctk/-ctv q8_0`, projector on CPU, `TIER=max` in
`serve.sh`. Speed at the safe ctx: **56 tok/s** (q3), 52.7 (q4s), 48.4 (q4).

**So there are three options, not two**: context (Q3_K_XL @ 196,608 default), a 4-bit middle
(Q4_K_S @ 163,840 — predicted from the within-family rule and it held), or best quality
(Q4_K_XL @ 122,880). `IQ4_XS` was deleted: an IQ type buys *less* context than Q4_K_S
despite being 1 GiB smaller, because codebook dequant needs ~4.5 GiB of scratch vs ~2.6 GiB.

**The lever that unlocked all of this was the prompt batch, not the split or the KV type.**
`-b 1024 -ub 256` shrinks the pp compute buffer, which is what actually fails first here:
at the 2048/512 default, 204,800 died with `CUDA error: device not ready`, and 196,608 left
441 MiB; with `-b 1024` the same 196,608 leaves **1,008 MiB** and 204,800 boots easily.
Measured cost: prompt processing 1301 → 1201 tok/s (−7.7%) on a 36,058-token ingest.

**Split is now bracketed, and 18,7 is the optimum**: 20,5/19,6 leave the 5070 Ti dry
(75–109 MiB); 17,8 and 16,9 fail on **device 1 (the 3080)** instead — the constraint flips.
Measured at 3 points, so don't re-tune it.

**Correction to earlier numbers in this file:** prompt processing was quoted as ~515 tok/s
and "a cold 200K prompt ≈ 6.5 min". That came from a 62-token prompt dominated by fixed
overhead. Measured properly on a 36,058-token prompt it is **1301 tok/s** at the default
batch (~1201 at `-b 1024`), so a 200K cold ingest is **~2.8 min, not 6.5**.

**Two quants on hand: Q3_K_XL (context) and Q4_K_XL (quality).** Default profile is
**Q3_K_XL at 196,608** — the largest context available and the only one clearing 192K with
safe slack. Note the ordering is *not* by file size: IQ4_XS is ~1 GiB smaller than
Q4_K_XL yet yields 50K more tokens, while Q3_K_XL beats both.

With **f16 KV** instead of q8_0, Q4_K_XL tops out at **49,152** (56K fails) — KV is
80 KiB/token at f16 versus 37.8 at q8_0.

Not tested, from `sizing.py` — trustworthy only **within** the K-quant family:

| file | size | predicted max ctx |
|---|---|---|
| `Q4_K_M` | 15.33 GiB | 142,996 |
| `Q4_K_S` | 14.30 GiB | 171,583 |
| `Q5_K_M` / `Q5_K_XL` | 18.41 / 19.44 GiB | 57,515 / 28,928 |
| `Q2_K_XL`, `IQ3_*` | 9.15–10.18 GiB | 262,144 (model's native max) |

### Other quants that exist (not on hand)

The repo publishes 30 GGUFs. The 4-bit options besides `Q4_K_XL` are `Q4_K_M` 15.33 ·
`Q4_0` 14.95 · `Q4_K_S` **14.30** · `Q4_1` 16.34 GiB, and `gguf-peek.py` confirms
**every one already carries the MTP head in-file** (`blk.64.nextn.*`, 17 KV blocks) — as do
the Q3/Q5/Q6/Q8 quants. There is also a separate `MTP/mtp-Qwen3.8-27B-Q4_0.gguf` sidecar
(1.28 GiB) but it is **not needed**, and using it would spend 1.28 GiB of VRAM that buys
~35K more tokens if used for KV instead.

`IQ4_XS` was downloaded, measured, and deleted: at 4-bit it gave *less* usable context than
`Q4_K_XL` (13–132 MiB of slack — see the table above). **`Q4_K_S` (14.30 GiB) is the
untested candidate worth knowing about** — same UD dynamic K-family as `Q4_K_XL` but 2 GiB
lighter, so the within-family rule of thumb (~28K tokens per GiB) puts it near ~170K at 4-bit
quality, i.e. possibly a *third* option rather than a strict context-or-quality choice.
Untested — hypothesis, not a number. To check: `./get-quant.sh Qwen3.8-27B-UD-Q4_K_S.gguf`
then `./rerun.sh "Q4_K_S 18,7 171583"`.

`serve.sh` profiles now: `Q=q3|q4s|q4` × `TIER=small|medium|large|max`, with `BATCH`/`UBATCH`
defaulting to 1024/256. Step a candidate up in 4K increments with an early stop:
`EXTRA='-b 1024 -ub 256' ./push.sh Q3_K_XL 18,7 208896 4096 225280`, and `./pp-check.sh`
measures what a batch change costs. Verify anything new with `./rerun.sh "<QUANT> <SPLIT> <CTX>"` — one isolated boot
per cell, idle VRAM verified first, self-checks the server's reported `n_ctx_slot`, and
records `memory.free`. `ctx-test.sh` and `iq-ladder.sh` are coarser (~40 s per boot).

## Wiring into pi

pi config lives in **`~/.pi/agent/models.json`** (NOT `models-store.json`, which is a
refreshable cache of built-in catalogs). Copy `pi-models.example.json` there. It reloads
each time you open `/model` — no restart needed.

Provider **`llama.local`** → `http://127.0.0.1:8000/v1`, `api: openai-completions`,
`apiKey: "$OMLX_API_KEY"` (pi interpolates `$VAR`; the literal never touches a file), and
`compat.thinkingFormat: "qwen"` so pi parses llama.cpp's `reasoning_content` as a thinking
block instead of leaking it as answer text. `supportsDeveloperRole`/`supportsReasoningEffort`
are false: llama.cpp has no `reasoning_effort`, and the `developer` role is a bad fit here.

**Do not name the provider `llama.cpp`** — that is pi's built-in router-aware provider, and
defining it in models.json overrides it (documented merge/override behaviour). `llama.local`
is a clean custom id.

**If `settings.json` has an `enabledModels` allowlist, a new provider must be added there
too** or the models stay gated out of `/model` even though they are listed. This box had a
stale `omlx/qwen3.8-27b` entry; it now reads:

```
"enabledModels": [
  "qwen-token-plan-individual/qwen3.8-flash",
  "qwen-token-plan-individual/qwen3.8-max",
  "llama.local/qwen3.8-27b",
  "llama.local/qwen3.8-27b-4s",
  "llama.local/qwen3.8-27b-4xl"
]
```

Verify without the TUI: `pi --list-models` — it shows each entry's window and prints a
warning for any allowlist entry that matches nothing (that is how the stale `omlx` row was
caught). Expected output row:
`llama.local  qwen3.8-27b  213.0K  32.8K  yes  yes`.

**Three entries, because the context window differs per quant profile** — `maxTokens`
32,768 on all three:

| pi id | `Q=` profile | contextWindow |
|---|---|---|
| `qwen3.8-27b` | `q3` (Q3_K_XL) | 196,608 |
| `qwen3.8-27b-4s` | `q4s` (Q4_K_S) | 163,840 |
| `qwen3.8-27b-4xl` | `q4` (Q4_K_XL) | 122,880 |

**The mismatch is silent, in one dangerous direction.** Measured: llama.cpp accepts *any*
`model` string — `some-typo` returns 200 — so pi's id is never validated against the server's
`--alias`. Under-declaring (4xl entry, q3 server) merely wastes window. **Over-declaring**
(q3 entry's 212,992 while a 122,880 server runs) means pi won't compact in time and the
request fails or silently truncates. So: pick the entry matching what you booted. `start.sh`
prints the served id to make that checkable, and `serve.sh` names the alias per profile.

Auth is now enforced on both ends: the server takes `--api-key` from `$OMLX_API_KEY`
(verified: no key → 401, wrong key → 401, right key → 200), so **pi must be launched from a
shell that has it** or every `llama.local` model 401s. `serve.sh` refuses an open bind without a key.

To switch profile: `Q=q4s ./start.sh`, then `/model` → the `-4s` entry.

Alternative integration: pi has a first-class llama.cpp **router** provider
(`docs/llama-cpp.md`: `--models-dir` + no `-m`, then `/llama` to load/unload on demand,
`LLAMA_BASE_URL`/`LLAMA_API_KEY`). Not used here because the per-profile tuning
(`--tensor-split 18,7`, `-b 1024`, `-ctk q8_0`, projector placement) is explicit in
`serve.sh`, and router mode would need it re-expressed as llama.cpp presets.

## Crash log

**2026-09-18, live test at CTX=212,992** — the Windows-side NVIDIA driver lost both cards.
`nvidia-smi`: `Unable to determine the device handle for GPU0/GPU1 … Unknown Error`, then
`No devices were found`. The server log had **no OOM, no CUDA error** — the last normal line
was routine prompt processing, and `/health` even kept answering afterwards because the HTTP
thread outlives a dead CUDA context. So: a dead server that still looks alive, and no
on-device proof of why.

Responses: default backed off 212,992 → **208,896** (4K step, pi `contextWindow` changed in
lockstep — never let the two drift, over-declaration is the dangerous direction). If it
recurs, go to **196,608**, which measured 1,008 MiB free vs 508: a 2× safety jump for 6% less
window. Recovery options, lightest first: `Win+Ctrl+Shift+B` (graphics driver reset) → restart
`NVDisplay.ContainerLocalSystem` (admin PowerShell) → `wsl --shutdown` and reopen (reliable,
but kills everything in WSL, including the agent session running inside it).
`nvidia-smi --reset` is unsupported inside WSL, and `/dev/dxg` + the libcuda shim staying
intact is normal in this state — it says the failure is host-side, not a missing WSL device.

Honest limit: 508 MiB free was measured **at idle**, not under the live worst case
(long prompt + MTP draft + prefix-cache growth + whatever the desktop grabbed). Margins should
be read under load, and a single post-boot reading is not a safety argument.

### Crash 4: the same config that measured SAFE killed the host on its repeat

`q4s` (Q4_K_S) @ **147,456 / SPLIT=17,8**:
- run 1 — completed the whole load suite, worst-case free **705 MiB** (3080) / 1,617 (5070 Ti), 43–52 tok/s → verdict SAFE
- run 2 — identical settings, **host reset mid prompt-processing**, no OOM and no CUDA error in the log

That is the decisive control. Nothing about the configuration changed, so the configuration
is not the variable. I also checked the one other candidate I could measure: pp throughput
during the crashing runs was 1,182–1,204 and 1,443–1,471 tok/s, while the *surviving* run was
1,180–1,204 tok/s — so load intensity does not separate them either.

**Conclusion: none of the variables I can see from inside WSL — free VRAM on either card,
context size, split ratio, prompt-batch size, pp rate — predict these resets.** Context
"safe levels" are therefore only statements about VRAM margin, and margin has now been shown
not to be sufficient even at 705 MiB. Stop tuning context to avoid resets; diagnose the host.

Ordered diagnostics for the reset itself (none of them require another context probe):
1. Windows Event Log / `Get-WinEvent` for `nvlddmkm`, `Display`, `Kernel-Power` around the
   crash timestamps (three of them are within this session, so they are easy to match).
2. Clean or roll back the NVIDIA driver (616.92) — Blackwell is new enough that a vendor
   regression is plausible on a Blackwell + Ampere pair.
3. Power/thermals under sustained dual-GPU prefill (`nvidia-smi dmon -s pucvmt`), and try a
   power cap on the 5070 Ti; a transient on simultaneous load fits a PSU/draw problem.
4. Single-GPU control run (disable/ignore the 3080, e.g. `CUDA_VISIBLE_DEVICES`): if the
   resets stop with one card, the mix or the board/PSU is implicated, not llama.cpp.

Until then, the configs below are the ones that completed a full load suite at least once.

### Crashes 2 and 3, and the margin theory is now known to be incomplete

Crash 2 came from my own method error: the scan probed q4s at 167,936 *after* 163,840 had
measured 120 MiB worst-case (UNSAFE). `safe-scan.sh` is now descending-only and asks
`serve.sh` what it would actually run, so it cannot override a clamp.

Crash 3 is the important one. `q4` (Q4_K_XL) at 106,496 with `SPLIT=17,8` measured **1,045
MiB** and completed the whole load suite. Stepping to 114,688 (+8,192 tokens ≈ 241 MiB at the
measured ~29.4 KiB/token slope) should have left **~800 MiB — double the stated 400 MiB
floor** — and the driver lost both cards anyway, silently, mid-prefill.

So the ≥400 MiB rule is **necessary but not sufficient**, and probing context cannot find a
"safe limit" while resets occur at comfortable predicted margins. The recurring host-side GPU
loss should be treated as its own reliability problem (driver 616.92 on a Blackwell+Ampere
mix, dual-GPU power/thermal transients during prompt processing, TDR with the display
attached), not as VRAM tuning. Testing is paused.

What the probing *did* establish: **the correct `--tensor-split` is profile-specific**, now
carried per profile in `serve.sh`:

| profile | ctx | split | worst-case free | outcome |
|---|---|---|---|---|
| q3 (Q3_K_XL) | 196,608 | 18,7 | 183-471 MiB (desktop-dependent) | marginal |
| q3 (Q3_K_XL) | 196,608 | **17.4,7.7** | **611 MiB** | SAFE - now the default |
| q3 (Q3_K_XL) | 196,608 | 17,8 | 445 MiB | SAFE-ish, ~10% faster than 17.4,7.7 |
| q3 (Q3_K_XL) | 196,608 | 16.6,8.4 | 275 MiB | constraint transferred to the 3080 |
| q3 (Q3_K_XL) | 196,608 | 16,9 / 58,42 | - | clean boot failure on the 3080 |
| q4 (Q4_K_XL) | 106,496 | **17,8** | **1,045 MiB** | SAFE, survived load suite |
| q4 (Q4_K_XL) | 106,496 | 18,7 | 81 MiB | booted, unsafe |
| q4 (Q4_K_XL) | 106,496 | 15,10 | — | clean boot failure (KV alloc, CUDA1) |
| q4 (Q4_K_XL) | 114,688 | 17,8 | ~800 predicted | **host reset during load** |
| q4s (Q4_K_S) | 163,840 | 18,7 | 120 MiB | measured UNSAFE (idle said 530) |
| q4s (Q4_K_S) | 167,936 | 18,7 | — | host reset (probe above a known-unsafe value) |
| q4s (Q4_K_S) | 147,456 | **17,8** | 705 MiB | run 1 SAFE; **run 2 identical → host reset** |

## The split is a fine-grained, float knob - and it only moves the constraint

`--tensor-split` parses with `std::stof()` per field (comma or slash separated), so
`17.4,7.7` and even `58,42` are valid; values are treated as a budget and normalized. The
catch, measured at q3/196,608 with the desktop held constant at 1,369 MiB:

| split | 5070 Ti share | free 3080 | free 5070 Ti | min |
|---|---|---|---|---|
| 18,7 | 72.0% | 1,345 | 183 | 183 |
| 17.4,7.7 | 69.3% | 611 | 898 | **611** |
| 17,8 | 68.0% | 445 | 990 | 445 |
| 16.6,8.4 | 66.4% | 275 | 1,142 | 275 |
| 16,9 | 64.0% | boot fails: KV alloc on 3080 | | |
| 58,42 | 58.0% | boot fails: pp compute buffers | | |

Shifting work onto the display-free 3080 raises the 5070 Ti's margin but eats the 3080's, so
the best `min` sits where the two curves cross - found here at ~69.3%, i.e. `17.4,7.7`.
Two caveats: the crossing point moves with **whatever the desktop is holding at boot**
(the 18,7 row read 471 MiB once and 183 MiB later, same config), and a linear
interpolation between two measured splits over-predicted the optimum by ~16%
(730 predicted vs 611 measured). Cost of the rebalance: ~44 vs ~53 tok/s, because the
3080 is now doing more work at its 200 W cap.

**Always record the desktop baseline (`nvidia-smi` with no server running) before comparing
two splits** - otherwise you are comparing Windows' mood, not your configuration.

**Placement is deterministic; the desktop is the only moving part.** Three identical boots of
q3/196,608/17.4,7.7 returned worst-free **611 MiB every time** with the desktop pinned at
1,301 MiB (`stability.sh`). So an earlier claim in this file - that `--tensor-split` "lands
~500 MiB differently between runs" - was wrong: the config is reproducible to the megabyte,
and every apparent drift was the display GPU's desktop usage changing between measurements.
`stability.sh` now records that baseline per round for exactly this reason.

## Root cause signature found: "GPU is lost" (hardware/PCIe level)

After crash 4, from **Windows** (elevated PowerShell, `nvidia-smi`):

```
Unable to determine the device handle for GPU0: 0000:24:00.0: GPU is lost.  Reboot the system to recover this GPU
1, NVIDIA GeForce RTX 5070 Ti, 300.00 W, 300.00 W, 300.00 W, 34.61 W, 616.92
```

So the 3080 (PCI 24:00.0) is **quarantined by the driver**, not merely invisible to WSL.
Two things worth remembering from this:

- **`Get-PnpDevice -Class Display` and `Win32_VideoController` both still reported
  `Status: OK`.** Those are cached/stale. For GPU health trust `nvidia-smi`'s own words,
  not PnP `OK`. (I concluded the opposite from the PnP data earlier in this session.)
- **"GPU is lost" is a hardware/PCIe-level failure**, not an out-of-memory result. That is
  fully consistent with everything we measured: the identical config both survived a full
  load suite and killed the host on repeat, and no WSL-visible variable (free VRAM on
  either card, ctx, split, batch, pp rate) separated the runs. Context tuning was never
  going to fix this.

Recovery for this state is a **reboot** - `wsl --shutdown` is not enough, the driver has
parked the device.

Leading hypotheses, in order: (1) PSU/transient overload - a 320 W 3080 plus a 300 W
5070 Ti both boosting during prompt processing is ~620 W on the two cards alone, and Blackwell
plus Ampere both produce current spikes well above TDP; (2) PCIe link drop on the 3080 (slot,
riser/cable, or power-connector daisy-chain); (3) driver 616.92 regression on a mixed-arch pair.

Mitigation to test after reboot, before any further load testing: cap power well below default
- 3080 -> ~240 W, 5070 Ti -> ~230 W (~470 W combined vs ~620 W). Run from **elevated
PowerShell** (`nvidia-smi -pl 240 -i <idx>`); `-pl` does not survive a reboot or driver
reset, so re-apply or script it at logon. Setting it from inside WSL needs root and the WSL
shim generally refuses `-pl` - untested from this side, so do it on Windows.

## Live testing

Endpoint: `http://127.0.0.1:8000` — OpenAI-compatible (`/v1/chat/completions`,
`/v1/models`, `/health`, `/props`, `/metrics`), built-in chat UI with image upload at `/`.
Model name as advertised: **`qwen3.8-27b`** (`--alias`), capabilities
`completion, multimodal`.

| thing | what to expect |
|---|---|
| decode | ~50 tok/s (46–56, MTP-dependent) |
| cold 200K ingest | ~2.8 min (1301 tok/s pp at default batch, ~1201 at `-b 1024`) |
| KV prefix cache | works — keep requests **append-only**; a changed system prompt or `enable_thinking` flip forces a full re-prefill (measured 9 s warm vs 167 s cold) |
| one full-res photo, `MM=cpu` | **~3 min** (173–183 s). Small images ~20 s. GPU (`MM=3080`) is 2.5–11 s but caps ctx at 98,304 |
| thinking | on by default; a small `max_tokens` returns `content: ""` with the answer inside `reasoning_content` |
| sampling | temp 1.0 / top_k 20 / top_p 0.95 come from the GGUF |

**Don't raise `-np` casually.** Each slot reserves its own KV, so parallelism costs both
window and safety margin at CTX=212,992:

| `-np` | per-slot window | free on 5070 Ti | verdict |
|---|---|---|---|
| **1** (default) | 212,992 | **418 MiB** | recommended |
| 2 | 106,496 | 290 MiB | OK for two clients, halves the window |
| 4 | 53,248 | **31 MiB** | avoid — below this box's abort threshold |

If you need real concurrency, prefer running the 3080 as a second instance
(`SPLIT=1,0 -np 1` won't work; use two processes with `CUDA_VISIBLE_DEVICES`) over
multiplexing slots at 31 MiB.

**Reaching it from Windows** (WSL is in NAT mode, so `127.0.0.1` inside WSL is invisible to
Windows apps): `HOST=0.0.0.0 ./start.sh --api-key <key>`. `serve.sh` now **refuses** an open
bind with no key (llama-server's own CORS-is-`*` warning), because an unauthenticated model
endpoint on the LAN is easy to forget about. `ALLOW_OPEN_NO_AUTH=1` overrides if you really mean it.

Watch it live: `tail -f server.log`, and `grep "draft acceptance" server.log | tail` for MTP
hit rate — if that line ever disappears, MTP stopped loading (see gotcha 2).

## Gotchas already paid for

1. **A blank line after a trailing `\` truncates an `exec` command**, and `bash -n` will
   not catch it. That silently dropped `-ngl`/`--spec-type` once and MTP quietly stopped.
   `test.sh` step 0 checks the live process args for this reason.
2. A python edit of the form `open(f,'w').write(g(...))` **truncates the file before
   evaluating `g`** — if `g` raises, the file is gone. This destroyed `README.md` once
   (rewritten). Build the new text first, then write.
3. llama.cpp loads `blk.64.nextn.*` **only when MTP is requested**; otherwise it logs
   `model has unused tensor blk.64.…`. Confirm with
   `grep -c "unused tensor blk.64" server.log` → **0 = MTP loaded**.
4. **Vision + a nearly-full 5070 Ti crashes hard, not gracefully** — first image request
   at CTX≥73724 killed the server with no error line (65536 survived with 239 MiB free).
   Hence `MM=cpu`. `MM=3080` (`-mmdev CUDA1`) is the middle ground: 2.5–3.3 s/image,
   stress-clean (4 cycles of 2 images + 300-token gen, 0 failures, 48.3 tok/s mean), but
   caps at 98304 and above it the pass/fail went **non-monotonic** (114688 failed while
   122880 booted with 6 MiB free) — allocation luck, not capacity.
5. This model **thinks by default**: `max_tokens: 24` yields `content: ""` because the
   budget went to `reasoning_content`. Use ≥128 or read `reasoning_content`.
6. **Image tokens scale with resolution — there is no ~1024 cap.** Measured on real
   photos: 982x1000 cat = **1122** tokens, 3840x2550 dog = **4122**. `--image-min-tokens
   1024` is a *floor*; the tiny synthetic swatches used in early tests all sat on that
   floor, which is what made it look like a ceiling.
7. `"allocating N MiB … out of memory"` is the size of the **last failed allocation, not
   the shortfall** — you cannot calibrate a per-token rate from it.
8. Setting **either** `-ngl` **or** `--tensor-split` disables llama.cpp's memory
   auto-fitter (`common_fit_params: … abort`). Auto-fit needs both dropped, and it quietly
   left layers on CPU at 128K (14.4 tok/s), so it is not free.
9. A harness variable once shadowed the `KV` env var and passed `-ctk "-mmdev CUDA1"`, so
   a config ran a bogus cache type and printed a usage blob instead of failing loudly.
10. Sampling (temp 1.0 / top_k 20 / top_p 0.95) comes from the GGUF — don't override it.
11. The loader warns Qwen-VL needs ≥1024 image tokens for grounding → `--image-min-tokens`.
12. WSL is in **NAT** mode: `--host 127.0.0.1` is invisible to Windows apps. Use
    `HOST=0.0.0.0` plus `--api-key` (CORS is `*` by default).
13. `-ngld` in llama.cpp's own MTP examples is stale; the current flag is
    `--spec-draft-ngl` (default `auto`, leave it). GGUF metadata value types are
    **uint32**, not the uint8 older spec summaries describe.

## If you want a newer build than b11034

Ubuntu 26.04's `nvidia-cuda-toolkit` is **12.4, which cannot target Blackwell** (sm_120
needs ≥12.8), so a source build must take the toolkit from NVIDIA's `wsl-ubuntu` repo.
CUDA 13.x accepts host GCC 6–16, so 26.04's gcc-15 is fine (no pinning).
`install-llama-cpp.sh` does it — needs your password — with source at `~/llama.cpp`.
Then `BIN=$HOME/llama.cpp/build/bin/llama-server ./start.sh`.

## The one-line version

If you have roughly this hardware (a Blackwell card + an older Ampere card, WSL2, ≤16 GB
RAM) and want a Qwen3.5-arch 27B GGUF with MTP and vision running with no root:

```bash
curl -LO https://github.com/ggml-org/llama.cpp/releases/download/b11034/llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz
curl -LO https://github.com/ggml-org/llama.cpp/releases/download/b11034/cudart-llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz
mkdir -p llama cudart-libs && tar -xzf llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz -C llama --strip-components=1
tar -xzf cudart-llama-b11034-bin-ubuntu-cuda-13.3-x64.tar.gz -C cudart-libs --strip-components=1
apt-get download libgomp1 && dpkg-deb -x libgomp1_*.deb libs/      # the one missing .so
./start.sh                                                        # after editing BIN/M paths
```

Then read the gotchas above — most of them are things that silently disabled MTP or
misreported headroom rather than things that fail loudly.
