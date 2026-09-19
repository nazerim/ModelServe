# ModelServe on Windows — usage

What to type, in what order, and what the output means. Design reasoning and the measured
evidence live in [README.md](README.md); the WSL side is documented in the repo root README.

Everything is invoked through a **.cmd**, from the NTFS copy:

    C:\ModelServe\win\start.cmd

Not the .ps1. This box's LocalMachine execution policy is AllSigned, so `.\start.ps1` is refused
with "is not digitally signed". cmd.exe is not a script, so it is not subject to ExecutionPolicy,
and the wrappers pass `-ExecutionPolicy Bypass` — that sets the Process scope, which outranks
LocalMachine. Nothing is changed system-wide and nothing is loosened beyond that one process. If
you add a new entry point, add a .cmd for it; do not "fix" this by changing the policy.

The repo copy (`./win/`) is the source; `install-windows.cmd` deploys it to
`C:\ModelServe\win`. Always run the deployed copy — it is the one that works when no WSL distro
is mounted.

---

## First run

    C:\ModelServe\win\install-windows.cmd          :: binaries + q3 + mmproj
    C:\ModelServe\win\check.cmd                    :: preflight: devices, power, TDR, key, models
    C:\ModelServe\win\start.cmd                    :: boots q3 and waits until it is really loaded
    :: from WSL, prove the path end to end:
    ./win/probe-from-wsl.sh

Re-running the installer is safe and idempotent: cached downloads are size-checked and skipped,
copies already present are left alone, an existing firewall rule is not duplicated.

---

## Daily

    start.cmd                       detached boot; waits for the load; prints the baseUrl
    stop.cmd                        stops the tree, then SHOWS the VRAM coming back
    check.cmd                       read-only preflight — run it after every reboot
    serve.cmd                       foreground boot, for watching the load trace live; stop.cmd
                                     also catches a foreground server (it matches the install dir,
                                     not only the pid file)

Previews that launch nothing:

    serve.cmd -DryRun               the exact resolved command line
    start.cmd -WhatIf               delegates to -DryRun (one place assembles argv) + what it would poll

Examples:

    start.cmd -P q3l                            deep context; brings its own prompt batch
    start.cmd -P q4 -Tier medium                that quant at 98,304
    start.cmd -Bind loopback                    Windows-only; no API key required
    start.cmd -TimeoutSec 600                   first boot from a cold file cache
    stop.cmd -VerifyOnly                        report what holds GPU memory, change nothing
    check.cmd -Port 9000

---

## Profiles — the four things the server can boot

`-P` (or `-Q`, same thing) selects a **profile**: a GGUF plus the context, prompt batch, split,
ceiling and advertised alias that were measured together. `-Tier` picks a size *within* a profile.

| `-P` | GGUF | CTX at Tier=max | prompt batch | advertises as | pick it when |
|---|---|---|---|---|---|
| `q3` | Q3_K_XL | 196,608 | 1024/256 | `qwen3.8-27b` | default: fastest prompt processing |
| `q3l` | Q3_K_XL | 225,280 | **512/128** | `qwen3.8-27b-l` | you need the longest window and can pay ~20% pp |
| `q4s` | Q4_K_S | 155,648 | 1024/256 | `qwen3.8-27b-4s` | better quality than q3, window still useful |
| `q4` | Q4_K_XL | 122,880 | 1024/256 | `qwen3.8-27b-4xl` | highest quality on hand |

q3l is not "q3 with a bigger number": the extra room is paid for out of the prompt compute
buffer, so the context and the batch move as one unit. Same GGUF as q3, so no extra disk. q3l is
native-Windows only — it has not been re-measured on ext4, so `llama.local` does not advertise it.

Tiers: `small` 32,768 · `medium` 98,304 · `large` 163,840 · `max` = the profile's ceiling (default).

---

## Switches

Model and size
: `-P`/`-Q` profile · `-Tier` size preset · `-Ctx` explicit context · `-Ceil` raise the clamp
: `-Npred` output budget (default 32,768) · `-Model` a path, bypassing the table · `-ModelDir`

Placement
: `-Split` tensor split, positional in **CUDA order** (CUDA0 = 5070 Ti here) · `-Ngl` layer count
: `-Kv` `f16|q8_0|q4_0` · `-Mm` `cpu|3080|cuda0` where the vision projector goes

Runtime
: `-Port` · `-Bind` `wsl` (default) `loopback` `127.0.0.1` or a literal address · `-Alias`
: `-Batch`/`-Ubatch` prompt buffer · `-MinP` · `-Spec` `draft-mtp|none` + `-SpecMax`
: `-NoVerify` skip the device-order check · `-TimeoutSec` (start)

### Precedence — what wins

1. An explicit switch beats a profile default. `-Batch 1024` on `-P q3l` gives you 1024, and
   `-Ubatch` is honoured independently of `-Batch`.
2. Windows-side environment (`$env:Q`, `$env:CTX`, …) beats the profile default but loses to a
   switch. It does **not** cross from WSL: only names listed in `WSLENV` reach a Windows process.
3. `-P` beats `-Q` if both are given.
4. `-Ctx` above the ceiling is **clamped**, and the summary reports the clamped number, because
   that is what execs:

       note: CTX=221184 exceeds the ceiling in force (196608) for q3; clamping.

   To actually test an unmeasured size you must say so twice — `-Ctx 221184 -Ceil 221184` — which
   prints `NOTE: ceiling overridden … this size is UNMEASURED ground.` The ladder passes both for
   you; that is deliberate, so a recorded row can never describe a boot that did not happen.

---

## Exit codes

| command | 0 | non-zero |
|---|---|---|
| `start.cmd` | model loaded and `/health` says ok | 1 = not ready in `-TimeoutSec`, exited early, or an allocation failure appeared in the log |
| `stop.cmd` | nothing of ours is left running | **1 = STOP INCOMPLETE** — something from the install dir survived; do not measure on top of it |
| `check.cmd` | report printed (it is read-only; read the lines) | refusal to resolve the WSL adapter, etc. |
| `serve.cmd` | server exited | llama-server's own code, or 2/3/4 for a refused argument |

`stop.cmd`'s non-zero is load-bearing: the WSL harness skips a round rather than recording it
when the previous server could not be confirmed dead, because a stale server produces a perfectly
plausible measurement row for a configuration that is not running.

---

## From WSL

    ./win/probe-from-wsl.sh                      resolves the host IP itself; names the broken layer
    ./win/ladder-from-wsl.sh 212992 225280       context ladder, stops at the first failure
    ./win/stability-from-wsl.sh 3 q3l            N identical boots + margin sampled under load
    BASE=http://172.25.240.1:8000 ./test.sh      the existing smoke harness, pointed remotely
    BASE=… SERVER_LOG=/mnt/c/ModelServe/logs/server.err.log ./win/stability-from-wsl.sh 3 q3l

Sweep extras through `EXTRA`, as **arguments**:

    EXTRA="-Split 18,7 -Batch 512 -Ubatch 128" ./win/stability-from-wsl.sh 3 q3
    SIZES="212992 221184" ./win/ladder-from-wsl.sh        # sizes positionally, or SIZES=

The ladder refuses above the profile's recorded ceiling unless you set `FORCE`, and
`CTX_MAX_KNOWN` is read from the profile rather than duplicated here. Its default size ladder is
163,840 → 180,224 → 196,608.

What the harness prints, and why: `identity ok: qwen3.8-27b @ n_ctx 196608` proves the answering
server is the boot it just launched; `worst_free` is the lowest free VRAM *sampled during* a
31,356-token prefill ×2 plus three long generations, never an idle reading; `pp=` comes from the
server's own `prompt eval time` lines, not from wall-clock (margin-check's wall includes the
generated tokens, and its header says so); the desktop baseline is captured before each boot
because a margin without one is uninterpretable.

---

## Output you will see, and what it means

    ready: {"status":"ok"}                     loaded and serving
      served as : qwen3.8-27b-l                the alias this boot advertises — pi's model entry
                                               must match the profile you booted, because llama.cpp
                                               IGNORES the model name in requests
      from WSL   : baseUrl http://172.25.240.1:8000/v1
    [  21 s / 300 s] health={"error":…Loading model…}   still loading; poll elapsed / budget
    STOP INCOMPLETE - these are still running  the kill did not land; retry elevated
    already running as PID 25804 - use stop.cmd first     start refused to stack a second server
    pid file points at PID 1234 which is 'foo.exe' - not our launcher (reused number?)
                                               stale pid file after a reboot; it was left alone
    REFUSING: CUDA0 is not the 5070 Ti         device order changed under you; every split in
                                               config.ps1 now means the wrong cards
    refusing to bind 172.25.240.1 with no API key        set it in the User scope, then re-run:
                                               setx LLAMA_API_KEY <key>

---

## Troubleshooting by symptom

| symptom | first thing to check |
|---|---|
| "is not digitally signed" | you ran a .ps1 — use the .cmd |
| boot hangs, CPU ~0, health goes silent, no crash event | **antivirus**. Norton suspends llama-server.exe pending a decision and it looks exactly like a GPU failure. Keep the exception on C:\ModelServe (exe *and* models); a version bump can re-trigger it |
| connection refused / no answer from WSL | `check.cmd` for listener and health; `probe-from-wsl.sh` says whether it is routing, firewall, or auth. No inbound rule is needed on this box — measured |
| 401 from a client that "has the key" | scope, not value: a terminal-only export dies with the shell and never reaches a scheduled launch. `check.cmd` prints the scope it found |
| server unreachable after a reboot | the bind IP is the vEthernet address and **can move**. `probe-from-wsl.sh` re-prints it; mirrored networking is the fix that makes it stop mattering |
| `MARGINAL` / `UNSAFE` verdict | that is the margin guard working: >=400 MiB free is the line, <240 MiB has aborted this box before. Drop `-Tier`, or move to a profile with a smaller batch |
| slow boot that never fails | host RAM/commit, not VRAM: `check.cmd` prints both. `vmmemWSL` + the desktop compete with a 12–16 GiB mapped model on a 31.9 GB box |
| nothing on 8000 but the model was loaded | the detached server may have been started elevated while your stop was not — run `stop.cmd` from an elevated prompt |
| a row says SAFE for a size you know was clamped | it can't any more: the record is parsed from the anchored summary line and every round asserts identity. If you see it, that is a bug — open the row's TSV and the preserved `/tmp/errlog-*.log` |

---

## Files

    C:\ModelServe\llama\      exes + both CUDA runtime DLLs, flat (no LD_LIBRARY_PATH on Windows)
    C:\ModelServe\models\     GGUFs + mmproj-F16.gguf on NTFS
    C:\ModelServe\win\        these scripts (deployed copy — run these)
    C:\ModelServe\logs\       server.out.log, server.err.log, robocopy.log
    C:\ModelServe\server.pid  detached starts only; safe to delete when nothing is running

`server.err.log` is truncated by every boot, which is why the WSL harness copies it per round to
`/tmp/errlog-<run>.log`. `*.tsv` and `*.log` are gitignored in this repo, so measurement numbers
that matter belong in prose, not only in a TSV.

## Also available

    install-power-limits.cmd            150W / 250W, re-applied at boot by a SYSTEM task
    install-power-limits.cmd -Status    read back what is in force
    install-windows.cmd -Firewall       elevated; scoped inbound allow for the WSL /20 only
    install-windows.cmd -RegisterTask   elevated; start the server at logon (off by default)
