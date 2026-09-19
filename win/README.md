# ModelServe on native Windows (C:\ModelServe)

The same llama.cpp the WSL side runs, as a Windows process. **Verified working
2026-09-19**: build b11034, commit dc85f89c7 — byte-identical to the Linux tarball in
`../llama/`, which is a different *build* of the *same commit* (Windows Clang 20.1.8,
Linux GNU 13.3.0), so there is no flag or sampler gap to reason about.

Measured natively at `Q=q3 Tier=max` (CTX=196,608, split 17.4,7.7, KV q8_0, MTP on),
driven from WSL with `BASE=... ../test.sh`:

| | native Windows | WSL2 (README) |
|---|---|---|
| decode | **50.3 tok/s** | 46-50 tok/s |
| MTP acceptance | 224/347, mean len 2.29 | ~1.9x over no-MTP |
| vision (mmproj on CPU) | red/blue correct | correct, ~17.5 s/image |
| boot to `health: ok` | ~20 s (warm), much longer cold | ~15-35 s |
| free VRAM at ceiling | 5070 Ti 1,069 MiB / 3080 665 MiB | ~420-441 MiB |

## Layout

    C:\ModelServe\
      llama\     both zips extracted FLAT. 21 exes + 33 dlls.
      models\    the GGUFs, copied from ext4 (the WSL originals stay put)
      win\       these scripts, deployed by the installer
      logs\      server.out.log, server.err.log, robocopy.log
      dl\        the pinned release zips (cached; sizes checked, not trusted blindly)
      server.pid

`llama-b11034-bin-win-cuda-13.4-x64.zip` is a **complete toolset**, not just a backend:
the release workflow injects the windows-cpu binaries (llama-server.exe + CPU backends)
into every backend zip. `cudart-llama-bin-win-cuda-13.4-x64.zip` supplies
cudart64_13 / cublas64_13 / cublasLt64_13. No CUDA toolkit, no Visual Studio, no compiler.
Windows has no `LD_LIBRARY_PATH`, so the CUDA DLLs must sit **beside** the exes — that is
why both archives land in one folder instead of the three-folder split serve.sh uses.

## Profiles — what the server can actually boot

Four names, each a *measured* combination rather than a knob you have to pair correctly:

| profile | gguf | CTX | batch | split | advertises as | free under load | state |
|---|---|---|---|---|---|---|---|
| **q3** | Q3_K_XL 12.24 GiB | 196,608 | 1024/256 | 17.4,7.7 | qwen3.8-27b | 637 MiB | 3/3 SAFE |
| **q3l** | same file | **225,280** | **512/128** | 17.4,7.7 | qwen3.8-27b-l | 517 MiB | 3/3 SAFE |
| **q4s** | Q4_K_S 14.30 GiB | 155,648 | 1024/256 | 17,8 | qwen3.8-27b-4s | 549 MiB | 3/3 SAFE |
| **q4** | Q4_K_XL 16.35 GiB | 122,880 | 1024/256 | 17,8 | qwen3.8-27b-4xl | 603-685 MiB | 3/3 SAFE |

These are **profiles, not tiers**, and the distinction turned out to matter: q3l is not "q3 with a
bigger number" — it is only SAFE because halving the prompt buffer paid for the extra 28,672
tokens (212,992 at the default batch measured 275 MiB, i.e. MARGINAL). A tier cannot own a batch,
a ceiling, a GGUF and an alias without becoming a profile wearing a tier's name, and the failure
mode of getting that wrong is a silently borderline server. So config.ps1 now keeps two ideas
apart: **MSProfiles** = the four bootable configurations, **MSTiers** = small/medium/large/max,
which pick a size *within* a profile.

Usage lines for all four live in [USAGE.md](USAGE.md); the command block that used to sit here is
removed rather than duplicated, so it cannot drift from the scripts.

`-Q` remains a synonym for `-P` so the WSL habit of "Q=q4s TIER=medium" works on both sides.
The q3l batch is applied only when nobody overrode it (an explicit -Batch or $env:BATCH wins),
and a smaller tier on q3l still uses 512/128 — harmless and a hair slower, rather than inventing
a second set of numbers nobody measured. q3l is **native-only**: the same trick should work on
ext4 (serve.sh takes BATCH/UBATCH too) but has not been re-measured there, so llama.local does
not advertise it.

## How to run it

Typing, switching, exit codes, output meanings and symptom-based troubleshooting are owned by
**[USAGE.md](USAGE.md)** — read that, not this file, for day-to-day use.

One decision recorded here, because it will be re-proposed: entry points are **.cmd wrappers**,
not signed scripts. LocalMachine policy on this box is AllSigned, so a bare `.\start.ps1` is
refused with "is not digitally signed" (verified). cmd.exe is not subject to ExecutionPolicy and
the wrappers pass `-ExecutionPolicy Bypass`, which sets the Process scope — and Process outranks
LocalMachine (precedence: MachinePolicy > UserPolicy > Process > CurrentUser > LocalMachine).
So nothing is loosened system-wide. Code-signing was rejected: it needs a self-signed certificate
imported into TrustedPublisher (a trust-store change to work around a policy the wrapper already
sidesteps), and every edit invalidates a signature, so the installer would have to re-sign on each
deploy and any hand-edit on the machine would silently break the next run. The WSL-side harness
reaches the .ps1 files by passing that same Bypass flag itself, which is why ladder and stability
runs work from WSL at all.

## Things that are different here, and were measured, not assumed

**1. Antivirus will eat you first.** The very first real boot froze with the health endpoint
going silent, all threads "Suspended", CPU frozen at ~10 s, 13 GiB already on the GPUs, no
crash and no WER event. That is NOT a driver or CUDA-graph problem — that is Norton SONAR
suspending the process while waiting for a decision. The WSL build was never visible to it
(an ELF inside ext4); a Windows PE exe plus a freshly copied 12 GiB GGUF is exactly its
trigger. Keep an exception on `C:\ModelServe` (exe *and* models). **A llama.cpp version bump
changes the binary and can re-trigger it** — when a native boot hangs with ~0 CPU, look at the
AV before you look at anything else, because every GPU-side symptom is also an AV symptom.

**2. Device order matches WSL, so the splits mean the same thing.** `--list-devices` natively
reports CUDA0 = 5070 Ti, CUDA1 = 3080 — the same inversion vs nvidia-smi that serve.sh
documents. serve.ps1 asserts this before every launch (`MSCuda0MustContain` in config.ps1)
rather than trusting it: if an update ever flips it, "17.4,7.7" would silently aim 17 GiB at
the 10 GiB card. `nvidia-smi -L` on Windows lists the 3080 first; do not derive the split
from that.

**3. No inbound firewall rule is needed for WSL.** check.ps1 used to warn that the unclassified
(=> Public) vEthernet adapter would block inbound. Empirically it does not: WSL-origin traffic
on `vEthernet (WSL (Hyper-V firewall))` reaches the host's port with no rule at all. So the
rule is inventory, not a prerequisite — create it only if `probe-from-wsl.sh` reports TCP
closed. `-Firewall` on the installer is therefore opt-in, and it scopes `RemoteAddress` to the
WSL /20 so the LAN stays closed either way.

**4. The bind address is dynamic.** `-Bind wsl` (the default) resolves the adapter's IPv4 at
launch — currently 172.25.240.1 — and passes a literal address to the child so the poller, the
advertised URL and the actual bind cannot disagree. That IP can change after a reboot, which
makes it a lousy thing to paste into pi's `baseUrl` permanently. `networkingMode=mirrored` in
`C:\Users\<you>\.wslconfig` removes the problem entirely (localhost works both directions, no
rule, no IP in configs) — not enabled here because the box runs a PVC VPN adapter and mirrored
mode + VPN is a known source of DNS surprises. Revisit if the IP ever does move.

**5. Key persistence has a scope, and WSL env vars do not cross by themselves.** serve.ps1
reads LLAMA_API_KEY from Process, then User, then Machine — and refuses any non-loopback bind
with no key, same policy as serve.sh. Two traps found the hard way:
  * `export FOO=... ` in WSL does **not** reach a Windows process; only names listed in
    `WSLENV` cross the bridge (`WSLENV=LLAMA_API_KEY/p`).
  * A key set in one terminal's session is invisible to a scheduled launch and dies with the
    shell. It is stored in the **User** scope on Windows now, matching `OMLX_API_KEY`.
The key never goes in argv (`--api-key` is readable through the Windows process command line
the same way `/proc/<pid>/cmdline` exposes it on Linux); llama.cpp accepts it as an env var.

**6. The WSL ceilings are starting points, not Windows results.** CTX ceilings in config.ps1
are copied from the ext4 measurements. Idle free VRAM is close natively (15,037 / 9,095 MiB vs
14,841 / 10,024) and 196,608 booted and served at 1,069 / 665 MiB free, which clears the >=400
MiB bar — but that is **one** boot. Before trusting any tier for a long session, re-run the
ladder the way the WSL side did: `iq-ladder.sh` and `stability.sh` from WSL with
`BASE=http://<host-ip>:8000`, and remember the ~240 MiB abort threshold was derived from the
same box's driver, so it should carry — while the crash history in ../README.md ("host resets")
now has a second candidate cause: AV interference.

**7. Host memory, not VRAM, is what stalls a cold boot here.** ../README.md says "system RAM
is 15 GB" — that is the **WSL VM allocation**, not the box: the host has 31.9 GB. Native
serving has to fit a 12.2 GiB mapped model + MTP draft context + compute buffers into whatever
Windows has left, and `vmmemWSL` was holding 14.3 GB at the time of the first failed boot while
commit sat at ~1 GB free. It ballooned down to 1.4 GB later and the same allocation landed
comfortably, so the pressure was transient — but if a boot crawls rather than failing, check
`check.ps1`'s RAM/commit lines and the WSL balloon before suspecting the GPU. Cap WSL with
`.wslconfig [wsl2] memory=` once Windows is the primary server; that is the permanent version
of this fix.

**8. TDR is live and WSL hides it.** Both cards run in WDDM, `TdrLevel=3` (reset on timeout)
with `TdrDelay=8` (already raised from the 2 s default). Under WSL you cannot see or set any of
this. A submission that blocks the display GPU past the delay produces a driver reset, which
looks like the "Windows driver lost both cards" entries in ../README.md — so this is a knob
worth knowing about, not a knob to yank: `TdrLevel=0` on a display-attached card trades a
reset for a frozen desktop.

**9. Sleep.** The plan is Ultimate Performance and S3 is *supported* (not Modern Standby), so
an unattended box can sleep mid-context and take both GPUs with it. Whatever keeps it awake for
a 200K benchmark day needs to be a deliberate setting, not luck.

## Provenance of the two WSL assumptions that turned out to be about the VM, not the machine

* "System RAM is 15 GB" — that is the WSL allocation on a 31.9 GB host (see 7).
* "never offload weights to CPU" — still true for WSL. Natively there is real host RAM for
  it, but the model is 12.2 GiB and the commit charge of a native boot was already 27 GB, so
  treat CPU offload as a last resort here too.

## Driving it from WSL (the harness)

The WSL harness stays the measurement tool; only the boot moves. Three new files, and the
existing two scripts now accept a remote target:

- **wsl-harness.sh** — shared primitives, sourced by the other two: `win_run` (synchronous,
  captured through a file), `win_launch` (fire-and-forget), `wait_ready` (local curl poll),
  `stop_win` (fails loudly), `prof_field` (parse serve.ps1's summary line ONLY), `assert_identity`
  (prove the answering server is this boot), `gpu_free`/`gpu_used`, `host_headroom`, `api_get`
- **ladder-from-wsl.sh** — context ladder, twin of `../iq-ladder.sh` → `iq-ladder-win.tsv`.
  Refuses sizes above the profile's own recorded ceiling (`CTX_MAX_KNOWN`, derived from
  `serve.ps1 -DryRun` — 196,608 for q3, 225,280 for q3l) unless `FORCE` is set, because 204,800 is
  the documented `device not ready` cliff and natively that can take the display driver with it
- **stability-from-wsl.sh** — N identical boots + margin-under-load, twin of `../stability.sh`
  → `stability-win-q3.tsv`, same SAFE/MARGINAL/UNSAFE verdict
- `../test.sh` takes `BASE=...` (and its embedded python now sends the bearer key, which it
  silently did not before — step 1 passed while step 2 died on 401)
- `../margin-check.py` takes `BASE=...`. Its nvidia-smi sampling deliberately stays on the WSL
  side: both views read the same host driver, and the 400/240 thresholds were defined there,
  so the MiB numbers remain comparable with the ext4 runs

Invocation for all three is in [USAGE.md](USAGE.md) (including why sweep extras must be passed as
`EXTRA="..."` arguments rather than environment).

**Interop: the finding that cost the most.** WSL does not return a Windows command until the
process *tree* it spawned has finished. `start.ps1` exits in ~15 s after it sees health:ok, but
the detached server is its descendant — so a synchronous launch blocks for as long as the
**server** lives. Two runs were misread as multi-minute hangs before it was measured: the boot
had finished in 11 s and the launcher had already printed its ready block into a capture file.
Fix: launch async, poll readiness locally with curl (millisecond turnaround, no interop in the
loop). Only commands that leave nothing behind (`stop.ps1`, `-DryRun`, a CIM query) are called
synchronously. Two related traps on the same path: piping a PowerShell call into `tr` never
reaches EOF because the detached server's conhost inherits the pipe's write end (capture to a
file instead), and Windows writes **CRLF**, so any anchored regex must strip `\r` first.

**Testing pieces separately found a third bug.** The first `wait_ready` divided nanoseconds by
1e6 (ms) while comparing against a seconds budget, so it declared the very first 3 s poll a
failure and reported "FAIL after 3007s" for a 3-second-old boot. Chained into a long background
run that would have looked like a server problem; run alone, it failed in seconds and named
itself.

## Pointing pi at it

~/.pi/agent/models.json now carries **llama.win** after llama.local, with **four** entries —
q3, **q3l (qwen3.8-27b-l, 225,280)**, q4s, q4 — so pi's list mirrors the four things the server
can actually boot. llama.local keeps its three (q3l is native-only until measured on ext4).
Each declaration was checked against `serve.ps1 -DryRun` rather than against these notes: every
entry's contextWindow equals the CTX its profile resolves to, so nothing over-declares.

- baseUrl **http://172.25.240.1:8000/v1** — the vEthernet address, i.e. what WSL sees as its
  default gateway. probe-from-wsl.sh and check.ps1 both re-print it.
- api openai-completions, apiKey "$OMLX_API_KEY" (pi expands the env reference; the Windows
  User-scope LLAMA_API_KEY holds the same value), and the *same* compat block.
- the same model ids as `llama.local` — they have to be, because the server advertises whatever
  --alias it booted with — with display names suffixed [win], plus a fourth entry for **q3l**
  (`qwen3.8-27b-l`, contextWindow 225,280). Each entry's contextWindow equals the CTX its profile
  resolves to, checked against `serve.ps1 -DryRun` rather than against these notes.

Verified two ways: a structural diff shows the two providers identical apart from baseUrl and
name; and live, a q3 boot reports id qwen3.8-27b with **meta.n_ctx 196,608** — exactly what the
entry declares, which is the check that matters, since llama.cpp ignores the model name pi
sends and would silently accept an over-declared context.

`pi-models.example.json` in the repo got the same provider by the same clone, so the template
cannot drift from the live config.

**Two caveats worth keeping in mind.** The 172.25.240.1 address is assigned per boot and *can*
move after a WSL or driver update — if llama.win ever 404s while the server is healthy, that is
the first thing to re-check (`./win/probe-from-wsl.sh`), and mirrored networking is the fix that
removes the question. And the two providers share port 8000 on different addresses: only one
server should hold the GPUs at a time, so don't leave `../start.sh` up while `start.ps1` runs —
they will fight over VRAM and the result looks like an allocation failure on whichever lost.

## Measured on Windows (2026-09-19, q3, WSL capped to 8 GB, AV exception in place)

**Stability — 3 identical boots at the production config (CTX=196,608 / split 17.4,7.7 /
KV q8_0 / MTP on), margin sampled under a 30,000-word prefill x2 plus three 400-token
generations:**

| round | boot | worst-case free | slowest gen | verdict |
|---|---|---|---|---|
| 1 | 15 s | **637 MiB** | 9.1 s | SAFE |
| 2 | 15 s | **637 MiB** | 9.1 s | SAFE |
| 3 | 15 s | **637 MiB** | 8.8 s | SAFE |

Bit-identical margins across rounds, which is the point: the ext4 record has q4s completing a
load suite once and then resetting the host on an identical repeat. Server-side generation
during these runs read **52.7-54.2 tok/s** (`slot print_timing ... tg`), above the 46-50 the
WSL setup reported. (`stability-win-q3.tsv`)

**q4s and q4, once their GGUFs were copied to NTFS** (both **size-matched** against the ext4
originals by the installer — it compares byte *lengths*, not hashes, so it catches the realistic
9P/robocopy truncation but is not a content check):

| profile | CTX | split | rounds | boot | worst-case free | slowest gen | verdict |
|---|---|---|---|---|---|---|---|
| q4s (Q4_K_S) | 155,648 | 17,8 | 3/3 | 30 s cold, then 18 s | **549 / 549 / 549 MiB** | 10.3-11.4 s | **SAFE** |
| q4 (Q4_K_XL) | 122,880 | 17,8 | 3/3 | 18-21 s | **685 / 637 / 603 MiB** | 10.4-10.9 s | **SAFE** |

Both clear the >=400 MiB bar on every round, and q4s is actually roomier than the ext4 run at
the same size (549 vs 523 MiB). Two honest caveats:

* q4's margin **moved 82 MiB across identical rounds** (685 -> 637 -> 603) while its desktop
  baseline barely changed (1,164/1,164/1,159). q4s was bit-identical. The likely source is third
  party GPU clients (browser / Edge webview / shell) allocating mid-run — native Windows has far
  more of that churn than WSL, where the only GPU client inside the VM was llama itself. Expect
  tens of MiB of noise on any native margin reading, and re-measure rather than extrapolate.
* **Host RAM, not VRAM, is the thin margin on the bigger quants.** Free physical memory hit
  **0.6 GB** during q4s rounds and 1.5-2.3 GB during q4, with commit 0.7-1.2 GB free — the 16.35
  GiB model maps into a 31.9 GB host that also carries an 8 GB WSL cap and the desktop. Nothing
  failed, but this is the number to watch if the box starts crawling at q4 rather than OOMing.

**q3l (225,280 @ 512/128) — 3 identical boots:** worst-case free **517 / 517 / 517 MiB**, all
SAFE; boots 15 / 24 / 24 s; pp 992-1,069 tok/s; slowest generation 9.0-9.3 s. That is the
profile baked into config.ps1 now.

**Ladder — same config, climbing context:**

| CTX | free 5070 Ti | free 3080 | binding card |
|---|---|---|---|
| 163,840 | 1,932 MiB | 1,389 MiB | 3080 |
| 180,224 | 1,462 MiB | 1,027 MiB | 3080 |
| 196,608 | 992 MiB | **665 MiB** | 3080 |

Textbook linear: every +16,384 costs ~470 MiB on the 5070 Ti and ~360 MiB on the 3080, boot
stayed 15 s at every size, and nothing failed. **The binding card natively is the 3080, not the
display GPU** — the opposite of the ext4 runs, where the 5070 Ti hit ~420-441 MiB first. That
says the split is leaving capacity on the table: shifting further toward CUDA0 (the 5070 Ti) is
the lever for more context, but 204,800 is the documented `device not ready` cliff, so
`ladder-from-wsl.sh` refuses to cross it without `FORCE=1` and that experiment is a decision,
not a default. (`iq-ladder-win.tsv`; the tok_s column there is wall-clock including prefill,
so read it as ~43 against the server's own 52-55 — the distinction margin-check.py's header
already warns about.)

**Two ways I fooled myself, both worth remembering.** First: a `ready` answer is not proof that
*your* boot answered. A q3l probe reported health:ok in 3 s and then advertised qwen3.8-27b
instead of qwen3.8-27b-l — because the previous run's server was still up (the run had died
before its own cleanup), start.ps1 had refused to double-boot, and the 3 s was the old process
answering. The guard worked; my verification was sloppy. Read start.ps1's own output before
believing a health poll. Second: **do not edit a script that a background run is executing** —
bash reads scripts incrementally, so my mid-run refactor made the loop die at a syntax error
after its last round and re-append one row. The data survived because the rounds had finished,
but that was luck. For long runs, edit a copy or accept editing only after the process is gone.

## Pushing q3 past the ext4 ceiling (measured, same box, KV q8_0 throughout)

The naive question — is 196,608 the limit natively? — answers no, and the reason it isn't is the
**prompt compute buffer, not the weights**. Every row below is a real boot with the margin sampled
under a 31,356-token prefill x2 plus three 400-token generations:

| CTX | batch | split | free 3080 | free 5070 Ti | worst | verdict |
|---|---|---|---|---|---|---|
| 196,608 | 1024/256 | 17.4,7.7 | 637-639 | 944-974 | 637 | SAFE (production) |
| 212,992 | 1024/256 | 17.4,7.7 | **275-277** | 979-981 | 275 | **MARGINAL** |
| 196,608 | **512/128** | 17.4,7.7 | 1,095-1,097 | 1,672-1,674 | 1,095 | SAFE |
| 212,992 | 512/128 | 17.4,7.7 | 765-767 | 1,144-1,167 | 765 | SAFE |
| 221,184 | 512/128 | 17.4,7.7 | 599-601 | 970-972 | **599** | **SAFE** |
| **225,280** | **512/128** | 17.4,7.7 | **517-519** | 852-854 | **517** | **SAFE (last one)** |
| 196,608 | 1024/256 | **19,6** | 1,913 | **310-312** | 310 | MARGINAL (overshoot) |

Readings, in order of usefulness:

* **Halving the prompt batch is worth +458 MiB on the binding card** at identical context
  (637 -> 1,095), which is more than half a context step costs (~832 MiB per +16,384). The
  ext4 note that 2048/512 -> 1024/256 bought ~570 MiB for ~8% of pp was the same effect, smaller
  dose.
* **The cost, now measured rather than derived** (both configs re-run with the server's own
  print_timing preserved per round, since every boot truncates the log):

  | config | prompt processing | decode | worst free | MTP acceptance |
  |---|---|---|---|---|
  | 196,608 @ 1024/256 | **1,290.5 / 1,258.1 tok/s** | 50.6 / 50.9 | 637 | 0.601, len 2.20 |
  | 225,280 @ 512/128 | **1,031.7 / 1,008.7 tok/s** | 49.0 / 49.4 | 517 | 0.595, len 2.19 |

  That is **+14.6% context for -20.1% prompt throughput and -3.1% decode**, with MTP acceptance
  essentially unchanged (0.601 to 0.595, mean draft length 2.20 to 2.19) - so speculation still
  pays for itself at the larger size. Worth noting for
  confidence in the native path: the 196,608 pp figures (1,258-1,290) land right on the ext4
  record's 1,258 tok/s, so WDDM is not quietly costing prompt speed.
* **The non-binding card's reading is not comparable across runs.** At the identical production
  config the 5070 Ti showed 944-974 MiB free in the 3-round set and 1,432-1,434 in this one - a
  ~500 MiB swing from whatever else held GPU memory on the desktop at the time. Compare the
  binding card between runs, not the slack card.
* **The 3080 is the constraint at every size except the 19,6 overshoot**, where the 5070 Ti
  dropped to 310. 17.4,7.7 is already essentially the balance point: total free at 196,608 is
  1,581 MiB and rebalancing can only equalize it to ~790 each, which is less than one step costs.
  Equalize the *cards*, don't chase the total.
* **The step arithmetic held to within 17 MiB:** measured deltas are ~362 MiB per +16,384 and
  ~181 MiB per +8,192 on the 3080 at 512/128, so 225,280 was predicted ~500 and measured **517**.
  That makes 225,280 the last SAFE size — 229,376 projects to ~338 and 233,472 to ~157, both
  MARGINAL — so the ladder's guard stays at 196,608 unless you say otherwise; a small-batch climb
  is deliberate, e.g. EXTRA="-Batch 512 -Ubatch 128" CTX_MAX_KNOWN=225280 SIZES="212992 225280".
  204,800 (the WSL `device not ready` size) was never used as a probe at either batch — the climb
  went in 8K steps past 196,608 instead, and nothing has yet been measured between 225,280 and
  the native wall. ladder-from-wsl.sh also now always passes -Ceil equal to the size under test,
  so the TSV can never describe a clamped boot that differs from the requested one.

That is why 225,280 became a **profile** (q3l) rather than a number to remember: the ceiling, the
prompt batch and the advertised alias move together, so nobody can get a deep context with the
production batch — which is the MARGINAL combination measured above. The manual pair is still how
you probe an as-yet-unmeasured size, and -Ceil must be lifted in the same call or the size
silently falls back and the result describes a different boot:

    C:\ModelServe\win\start.cmd -P q3l
    EXTRA="-Ctx 221184 -Ceil 221184 -Batch 512 -Ubatch 128" ./win/stability-from-wsl.sh 3 q3

Two tool defects this experiment found and fixed: serve.ps1 had no way to raise its own ceiling,
so any above-ceiling test would have been *clamped and reported as a pass* (now `-Ceil`, which
also prints "this size is UNMEASURED ground"), and the pp parser in stability-from-wsl.sh was
reporting MTP **draft** timings (30 tok/s for a 3-token speculative prompt) instead of the 31K
prefill. The script now also copies server.err.log per round, because every boot truncates it and
X1's authoritative pp line was lost that way.

## Status / not done

* All three quants are on NTFS and every profile has 3/3 SAFE native boots: q3 196,608,
  q4s 155,648, q4 122,880. The boot task is not registered (`-RegisterTask`).
* Natural next measurements: the q4/q4s ladders (natively the 3080 is the binding card, so their
  ext4 ceilings may be conservative) and a split sweep — the only way to know whether that extra
  slack is real capacity or just a different card holding it.
* Committed: 93d218f (the win/ track) and this follow-up fixing a code review's findings — the
  clamp note being parsed as the record (a SAFE row could be written for a context that never
  booted), no proof that the answering server was the one just launched, a vacuous device-order
  check in the installer, assertions that did not cover the passthrough tail of argv, a pid file
  that could kill a reused PID, and the .cmd wrappers that AllSigned actually requires to run
  start/stop/check/serve.
* The WSL server is untouched and remains the fallback; `stop.sh` on both sides is independent.
