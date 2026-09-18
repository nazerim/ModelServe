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
| generation **with** MTP | **46–50 tok/s** (acceptance 0.54–0.85, mean draft len ~2.1) |
| generation **without** MTP | 25.7 tok/s → **MTP ≈ 1.9×**; keep it on |
| prompt processing | ~515 tok/s → a cold 200K prompt ≈ 6.5 min |
| KV cost | **f16 80 · q8_0 37.8 · q4_0 ~23 KiB/token** (measured; only 17/65 blocks hold KV) |
| vision latency | ~2.5–3.3 s/image on GPU · **~17.5 s/image on CPU** |

### Context ceilings, Q4_K_XL weights (`-ngl 99`, split 19,6)

| KV | vision on GPU | vision on CPU |
|---|---|---|
| f16 | 49152 ✓ / 57344 ✗ | — |
| **q8_0** | 65536 ✓, **≥73724 SIGABRTs the first image** | **114688 ✓ 47.2 tok/s** · 122880 ✗ |
| q4_0 | 98304 ✓ ~45 | 196608 ✗ · 245760 ✗ |

### Reaching ~200K: measured, and the winner is Q3_K_XL — not IQ4_XS

| quant | GiB | 147,456 | 163,840 | 180,224 | 196,608 | 212,992 | 229,376 |
|---|---|---|---|---|---|---|---|
| Q4_K_XL *(original)* | 16.35 | — | — | — | ✗ (max 114,688) | — | — |
| **Q3_K_XL** | 12.24 | — | — | **OK 44.6** | **OK 56.2** | ✗ | ✗ |
| **IQ4_XS** | 13.27 | OK 49.2 | OK 46.6 | ✗ | ✗ | — | — |

**Default is `Q=q3 TIER=max` = 196,608 ctx on :8000.** Q3_K_XL is the only candidate that
reaches 192K, and with `SPLIT=18,7` it does so keeping **541 MiB** free on the display GPU
(the old `19,6` split left 98 MiB).

**The lesson: IQ4_XS is 1 GiB *smaller* yet yields ~32K *fewer* tokens**, because IQ
codebook types need far larger CUDA dequant scratch (~4.5 GiB non-KV overhead vs ~2.6 GiB
for K_XL types). "1 GiB saved ≈ 28K tokens" holds only *within* a quant family — the
pre-test predictions were ~15% optimistic for exactly that reason. Measure with
`iq-ladder.sh`; don't extrapolate across families.

Vision is not the lever and neither is KV quantisation: `-mmdev CUDA1` (projector on the
3080) gives GPU-speed images but caps at 98304 with 236 MiB spare, and q4_0 KV measured
**fail** at 192K despite theory. `--tensor-split 16,9` cannot rescue 192K either — it just
moves the OOM onto the 3080.

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

| file | size | split | largest ctx that BOOTS | free on 5070 Ti there | usable? |
|---|---|---|---|---|---|
| `Qwen3.8-27B-UD-Q3_K_XL.gguf` | 12.24 GiB | **18,7** | **196,608** (6/6 boots, 46–48 tok/s) | **420–441 MiB** | **yes — the default** |
| `Qwen3.8-27B-UD-IQ4_XS.gguf` | 13.27 GiB | 18,7 | 188,416 (44.5 tok/s) | **13 MiB** | no — will abort |
| `Qwen3.8-27B-UD-IQ4_XS.gguf` | 13.27 GiB | 18,7 | 180,224 (47.7 tok/s) | 132 MiB | marginal |
| `Qwen3.8-27B-UD-Q4_K_XL.gguf` | 16.35 GiB | 18,7 | 122,880 (42–48, 3/3 boots) | **109 MiB** | no — will abort |
| `Qwen3.8-27B-UD-Q4_K_XL.gguf` | 16.35 GiB | 19,6 | 114,688 (47.2 tok/s) | ~500 MiB | yes, but lower |
| `mmproj-F16.gguf` | 0.86 GiB | — | shared by all quants | — | keep on CPU (`MM=cpu`) or the 3080 |

**A boot that succeeds is not a test that passes** — the column that matters is *free*.
This box aborts below ~240 MiB on the display GPU, so the 188,416 and 122,880 "wins" are
unusable: retuning the split does squeeze a few more thousand tokens out of the heavier
quants (correcting an earlier claim here that rebalancing buys safety only), but every one of
those tokens is bought with slack the Windows desktop will spend first. `Q3_K_XL @ 196,608`
is simultaneously the largest **and** the safest config, because weights and KV compete for
the same VRAM — the smallest quant wins on both axes. Past it, 204,800 doesn't even OOM
cleanly: it puts the driver into `CUDA error: device not ready`.

**Default profile is Q3_K_XL at 196,608** — the largest of the three and the only one that
clears 192K. Note the ordering is *not* by file size: IQ4_XS is ~1 GiB smaller than
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

Verify any new quant or size with `./rerun.sh "<QUANT> <SPLIT> <CTX>"` — one isolated boot
per cell, idle VRAM verified first, self-checks the server's reported `n_ctx_slot`, and
records `memory.free`. `ctx-test.sh` and `iq-ladder.sh` are coarser (~40 s per boot).

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
