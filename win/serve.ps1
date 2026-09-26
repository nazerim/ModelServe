<#
  serve.ps1  -  foreground llama-server on native Windows. Twin of ../serve.sh.

  Usage - via the policy-proof wrapper (this box is AllSigned at LocalMachine scope, so a bare
  ".\serve.ps1" is refused with "is not digitally signed"; cmd.exe is not subject to
  ExecutionPolicy and -ExecutionPolicy Bypass sets Process scope, which outranks LocalMachine):

      serve.cmd                                   # q3 (default), WSL-safe ceiling, bound for WSL clients
      serve.cmd -P q4 -Tier medium
      serve.cmd -Tier large                       # 163,840 ctx: most VRAM headroom
      serve.cmd -DryRun                           # print the resolved command, launch nothing
      serve.cmd -Bind loopback                    # Windows-local only, no key required

  (The underlying .ps1 can still be called directly as long as Bypass is passed, which is what
  serve.cmd does, and what the WSL-side harness scripts do: from WSL, call
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ModelServe\win\...)

  -Bind defaults to 'wsl': the vEthernet (WSL) adapter address, so a client inside WSL can
  reach it while the LAN cannot. 'lan' = the LAN adapter's single IPv4 (refusing to guess when
  more than one adapter carries a default route); 'all' = 0.0.0.0, every face at once, so LAN
  and WSL clients both work. Every non-loopback bind REQUIRES LLAMA_API_KEY (same policy as
  serve.sh - llama-server's CORS is '*' by default).
  Everything is env-overridable too, so start.ps1 and a Task Scheduler entry can pass knobs
  without editing this file:  $env:Q / $env:CTX / $env:SPLIT / ...

  The ceilings and splits are WSL measurements; see config.ps1 and win/README.md.
#>
[CmdletBinding()]
param(
    # Default profile since 2026-09-26: q3 (Q3_K_XL at 229,376 with 1024/128). q3l was retired the
    # same day - it measured the SAME margin as q3 at 229,376, so its smaller batch was not the
    # thing buying the room. Use -Tier / -Ctx for a smaller window, -P q4s|q4 for the other quants.
    [string]$Q      = $(if ($env:Q)      { $env:Q }      else { 'q3' }),
    # -P is the real name for what is being selected: a PROFILE (gguf + context + batch + ceiling
    # + alias). -Q stays a synonym so "Q=q4s" keeps working from both sides of the bridge.
    [string]$P      = $(if ($env:P)      { $env:P }      else { '' }),
    [string]$Tier   = $(if ($env:TIER)  { $env:TIER }  else { 'max' }),
    [string]$Model    = $(if ($env:MODEL)   { $env:MODEL }   else { '' }),
    [string]$ModelDir = $(if ($env:MODEL_DIR) { $env:MODEL_DIR } else { '' }),
    [int]$Ctx     = $(if ($env:CTX)    { [int]$env:CTX }    else { 0 }),      # 0 = the tier's size
    [int]$Npred   = $(if ($env:NPRED)  { [int]$env:NPRED }  else { 32768 }),
    [string]$Split  = $(if ($env:SPLIT)  { $env:SPLIT }   else { '' }),       # '' = the profile default
    [string]$Ngl    = $(if ($env:NGL -or $env:NGL -eq '0') { $env:NGL } else { '99' }),
    [string]$Kv     = $(if ($env:KV)     { $env:KV }      else { 'q8_0' }),
    # Draft-context KV type (-ctkd/-ctvd). Empty = llama.cpp's own default, which is f16 EVEN WHEN
    # the target is q8_0 - so the MTP head's KV quietly costs ~4 KiB/token on the 3080. Baked into
    # the q3 profile because 229,376 does not fit without it (see config.ps1).
    [string]$KvDraft  = $(if ($env:KVDRAFT) { $env:KVDRAFT } else { '' }),
    # Per-tensor device pin (-ot). The right-hand side is a DEVICE buffer type on this build
    # (CPU / CUDA0 / CUDA1), which is what makes pinning one layer possible at all -
    # --spec-draft-device does nothing for an in-file MTP head.
    [string]$OvTensor = $(if ($env:OVTENSOR) { $env:OVTENSOR } else { '' }),
    [string]$Mm     = $(if ($env:MM)     { $env:MM }      else { 'cpu' }),
    [int]$Batch   = $(if ($env:BATCH)  { [int]$env:BATCH }  else { 1024 }),
    [int]$Ubatch  = $(if ($env:UBATCH) { [int]$env:UBATCH } else { 256 }),
    [string]$MinP = $(if ($env:MINP)   { $env:MINP }        else { '0' }),
    # MTP draft speculation. On this box the draft context is a SECOND allocation on top of the
    # 12 GiB of mapped weights, and native Windows has to fit it inside the host commit limit
    # with WSL's vmmem balloon still holding ~14 GB - so 'none' is a real lever, not just a knob
    # (it costs the ~1.9x decode speedup the WSL side measured). -Spec none drops both flags.
    [string]$Spec  = $(if ($env:SPEC)   { $env:SPEC }        else { 'draft-mtp' }),
    [int]$SpecMax = $(if ($env:SPECMAX) { [int]$env:SPECMAX } else { 2 }),
    [int]$Port    = $(if ($env:PORT)   { [int]$env:PORT }   else { 8000 }),
    # 0 = the profile's measured ceiling (clamped). Set it explicitly to probe ABOVE the ceiling:
    # without this knob a ladder run at 212,992 would be silently clamped to 196,608 and report a
    # PASS for a configuration that was never actually booted - the most dangerous kind of fake.
    [int]$Ceil    = $(if ($env:CEIL)   { [int]$env:CEIL }   else { 0 }),
    [string]$Bind   = $(if ($env:BIND)   { $env:BIND }      else { 'wsl' }),
    [string]$Alias  = $(if ($env:ALIAS)  { $env:ALIAS }     else { '' }),
    # -Bin swaps in a different llama-server.exe (e.g. the patched CUDA build that carries
    # --cache-dir). -CacheDir/-CacheMax steer the disk prompt cache; -NoCacheDir turns it off.
    # Empty defaults are resolved against config.ps1 AFTER it is dot-sourced, below.
    [string]$Bin      = $(if ($env:BIN) { $env:BIN } else { '' }),
    [string]$CacheDir = $(if ($env:CACHE_DIR) { $env:CACHE_DIR } else { '' }),
    [int]$CacheMax    = $(if ($env:CACHE_MAX) { [int]$env:CACHE_MAX } else { -1 }),
    # Checkpoint budget for the disk tier (0 = send nothing and accept llama.cpp's own defaults).
    [int]$Ctxcp       = $(if ($env:CTXCP) { [int]$env:CTXCP } else { -1 }),
    [int]$Cms         = $(if ($env:CMS)   { [int]$env:CMS }   else { -1 }),
    [switch]$NoCacheDir,
    [switch]$NoVerify,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ExtraArgs
)

. (Join-Path $PSScriptRoot 'config.ps1')

# Defaults that come from config.ps1 must be applied AFTER dot-sourcing it: a param default is
# evaluated before the body runs, so $script:MSModels is still $null there (this bit me once).
if (-not $ModelDir) { $ModelDir = $script:MSModels }

# Which binary we are about to exec, and what the cache was asked to do. $Exe rather than
# $script:MSExe everywhere below: the cache probe, the assertions, the printed command and the
# exec must all describe the SAME binary, or the summary lies about the boot.
# The PATCHED build is the default when it is installed, because it is the only one with
# --cache-dir. $script:MSExe stays the pinned prebuilt so install-windows.ps1 keeps describing the
# release track it downloads - but note that a default boot is therefore NOT the b11034 build the
# ceilings/splits in config.ps1 were measured on; the summary records which one ran (BIN=...).
if ($Bin) { $Exe = $Bin }
elseif (Test-Path $script:MSExePatched) { $Exe = $script:MSExePatched }
else { $Exe = $script:MSExe }
$ExeParent = Split-Path -Parent $Exe                                  # bare 'llama-server.exe' has no parent
$ExeTag    = $(if ($ExeParent) { (Split-Path -Leaf $ExeParent) -replace '_', '' } else { 'cwd' })
if (-not $CacheDir -and -not $NoCacheDir) { $CacheDir = $script:MSCacheDir }
$CacheDirWasDefault = [bool]($CacheDir -and (-not $PSBoundParameters.ContainsKey('CacheDir')) -and (-not $env:CACHE_DIR))
# -1 means "caller said nothing", because 0 is a real value: llama.cpp treats --cache-dir-max 0 as
# "disable the cache", and rewriting 0 to the default both ignores the caller and (worse) still
# counts as an explicit request. Same sentinel pattern as -Ctxcp/-Cms below.
if ($CacheMax -lt 0) { $CacheMax = $script:MSCacheMaxMiB }
if ($CacheMax -eq 0) {
    [Console]::Error.WriteLine('note: -CacheMax 0 means "no disk tier"; booting without --cache-dir.')
    $NoCacheDir = $true; $CacheDir = ''
}
# -1 means "caller said nothing": take config's budget. 0 stays an explicit "omit the flag".
if ($Ctxcp -eq -1) { $Ctxcp = $script:MSCtxcp }
if ($Cms   -eq -1) { $Cms   = $script:MSCms }
# An explicitly requested cache must never be dropped quietly; a defaulted one may fall back
# with a warning, so the pinned prebuilt b11034 keeps booting exactly as it always did.
$CacheAsked = [bool]($PSBoundParameters.ContainsKey('CacheDir') -or $PSBoundParameters.ContainsKey('CacheMax') -or $env:CACHE_DIR -or $env:CACHE_MAX)

# Capture the requested override BEFORE the profile lookup overwrites $Ceil - the param is also
# named -Ceil, so reading it after the table lookup would always yield the profile default.
$CeilReq = $Ceil

# ---- resolve profile + tier ---------------------------------------------
# -P names a profile (q3|q4s|q4). -Q is a synonym, so the WSL habit of "Q=q4s TIER=medium"
# keeps working on both sides; when both are given, -P wins.
if ($P) { $Q = $P }
if (-not $script:MSProfiles.Contains($Q) -and -not $Model) {
    Write-Host ("-P/-Q must be one of: " + (($script:MSProfiles.Keys) -join '|') + " (or pass -Model <path>)") -ForegroundColor Red; exit 2
}
if (-not $script:MSTiers.Contains($Tier)) {
    Write-Host ("Tier must be one of: " + (($script:MSTiers.Keys) -join '|')) -ForegroundColor Red; exit 2
}

if ($Model) {
    # Explicit path wins and is trusted: no clamp unless an override was explicitly requested.
    $Ceil = $CeilReq; $prof = $null
    $ModelPath = $Model
    if (-not $Alias) { $Alias = 'qwen3.8-27b' }
    if (-not $Split) { $Split = '47,19' }   # same count form the q3 profile now uses
} else {
    $prof  = $script:MSProfiles[$Q]
    $ModelPath = Join-Path $ModelDir $prof.File
    $Ceil  = [int]$prof.Ceil
    if ($CeilReq) { $Ceil = $CeilReq }                  # unless the caller was explicit
    if (-not $Alias) { $Alias = $prof.Alias }
    if (-not $Split) { $Split = $prof.Split }
    # The profile's batch applies only when nobody asked otherwise. q3's 229,376 was measured WITH
    # 1024/128; the same context at ubatch 256 costs ~130 MiB, and the 196,608 row measured 275 MiB
    # at 212,992/1024/256, so letting the batch silently fall back would turn a SAFE profile into a
    # borderline one.
    if ($prof.Batch -and -not $PSBoundParameters.ContainsKey('Batch') -and -not $env:BATCH) {
        $Batch = [int]$prof.Batch
        # -Ubatch is honoured independently of -Batch: a caller asking only for a smaller ubatch
        # must not have it silently rewritten to the profile's value.
        if (-not $PSBoundParameters.ContainsKey('Ubatch') -and -not $env:UBATCH) { $Ubatch = [int]$prof.Ubatch }
    }
    # Same rule as the batch: the profile's pin and draft-KV apply unless the caller asked for
    # something else, so an A/B can override either one without editing config.ps1.
    if ($prof.OvTensor -and -not $PSBoundParameters.ContainsKey('OvTensor') -and -not $env:OVTENSOR) { $OvTensor = $prof.OvTensor }
    if ($prof.KvDraft  -and -not $PSBoundParameters.ContainsKey('KvDraft')  -and -not $env:KVDRAFT)  { $KvDraft  = $prof.KvDraft }
}
# `none` is the documented way to ask for NO pin / NO draft-KV override on a profile that ships
# with them. An empty string would be the obvious spelling but it does not survive
# `powershell -File` from WSL (the argument can vanish entirely, silently reverting to the
# profile), and "the flag I tested with is not the flag I documented" is the bug class here.
if ($OvTensor -eq 'none') { $OvTensor = '' }
if ($KvDraft  -eq 'none') { $KvDraft  = '' }

# Tier picks a size WITHIN a profile; max = that profile's measured ceiling. A smaller tier on q3
# still uses 1024/128 rather than carrying a second set of numbers nobody has measured.
$CtxWant = $Ctx
if (-not $CtxWant) {
    $tierCtx = [int]$script:MSTiers[$Tier]
    $CtxWant = if ($tierCtx) { $tierCtx } elseif ($Ceil) { $Ceil } else { 131072 }
}
if ($CeilReq -and $prof -and ($Ceil -ne [int]$prof.Ceil)) {
    # stderr, like serve.sh's clamp note: win_run captures both streams into one file, so an
    # informational line must never be something a parser can mistake for the record.
    [Console]::Error.WriteLine(('NOTE: ceiling overridden to {0} (profile default {1}) - this size is UNMEASURED ground.' -f $Ceil, $prof.Ceil))
}
if ($Ceil -and $CtxWant -gt $Ceil) {
    [Console]::Error.WriteLine("note: CTX=$CtxWant exceeds the ceiling in force ($Ceil) for $Q; clamping.")
    # The CLAMPED value is the truth about what will exec, and the summary line below is the single
    # record the harness parses - so the record must carry 196608, not the 221184 that was asked for.
    $CtxWant = $Ceil
}

# ---- guards ---------------------------------------------------------------
if (-not (Test-Path $Exe)) {
    Write-Host "missing $Exe - run install-windows.cmd first (or fix -Bin)" -ForegroundColor Red; exit 1
}
if (-not (Test-Path $ModelPath)) {
    Write-Host "no such model: $ModelPath" -ForegroundColor Red
    Write-Host "  models live on NTFS for the native server; copy them with:" -ForegroundColor Red
    Write-Host "      install-windows.cmd -Models q3,mmproj" -ForegroundColor Red
    exit 1
}
$Mmproj = Join-Path $ModelDir 'mmproj-F16.gguf'
if (-not (Test-Path $Mmproj)) { Write-Host "no such mmproj: $Mmproj" -ForegroundColor Red; exit 1 }

# Bind resolution: the ONE shared resolver in config.ps1 (wsl / lan / all / loopback / literal),
# so the key gate below, start.ps1's poll, the advertised faces and the firewall hint cannot
# drift apart. start.ps1 normally hands us the RESOLVED literal already, but a direct
# `serve.cmd -Bind lan` must resolve identically - which is why this lives in config.ps1.
$bindRes = Resolve-MSBind -Bind $Bind -Port $Port
if (-not $bindRes) { exit 1 }
$BindHost = $bindRes.BindHost

# API key: from the environment only, never argv. Any non-loopback bind REQUIRES it -
# llama-server also defaults CORS to '*', so an open unauthenticated endpoint is exactly
# what serve.sh refuses, and the same rule applies here.
$key = Resolve-MSApiKey
if ($BindHost -ne '127.0.0.1' -and -not $key) {
    Write-Host "refusing to bind $BindHost with no API key." -ForegroundColor Red
    Write-Host "  set it persistently (a terminal-only export dies with the shell and never" -ForegroundColor Red
    Write-Host "  reaches a scheduled launch), then re-run:" -ForegroundColor Red
    Write-Host "      setx LLAMA_API_KEY <the-key>" -ForegroundColor Red
    Write-Host "  or keep it local:  -Bind loopback" -ForegroundColor Red
    exit 2
}
if ($key) { $env:LLAMA_API_KEY = $key.Value }   # the child inherits; argv stays clean

# llama.cpp commit), so entries from another profile - or another size/batch/KV within one profile -
# are not merely unusable: the startup sweep classifies them as foreign and DELETES them. Seen live:
# a q3l boot's five entries, 38 GiB, removed twelve seconds into a q3 boot, and the resumed session
# then re-prefilled 73k tokens. The directory name therefore carries every part of the identity that
# survives a boot: profile, resolved ctx, batch, ubatch and KV type (underscores dropped, because the
# harness field parser only accepts [A-Za-z0-9.,/-]).
$CacheId = ''
if ($CacheDir -and $CacheDirWasDefault) {
    $CacheId  = '{0}-{1}-{2}x{3}-{4}' -f $Q, $CtxWant, $Batch, $Ubatch, ($Kv -replace '_', '')
    $CacheDir = Join-Path $script:MSCacheDir $CacheId
} elseif ($CacheDir) {
    $CacheId = (Split-Path -Leaf $CacheDir) -replace '_', ''
    try   { $CacheDir = [System.IO.Path]::GetFullPath($CacheDir) }   # relative paths differ between
    catch { }                                                        # serve.cmd (cwd C:\) and start.ps1
}
if ($CacheId) { $CacheId = $CacheId -replace '_', '' }

# Probed, never assumed. --cache-dir exists only in a master + PR 28092 build; appending it to a
# binary that does not know it aborts the boot with "invalid argument", and omitting it while
# printing CACHE=... would record a configuration that never ran. So ask the binary itself.
$CacheTag = 'off'
if (-not $NoCacheDir -and $CacheDir) {
    if ((Test-MSFlagSupport -Exe $Exe -Flag '--cache-dir') -ne 'supported') {
        if ($CacheAsked) {
            Write-Host "refusing: this llama-server has no --cache-dir." -ForegroundColor Red
            Write-Host "  binary: $Exe" -ForegroundColor Red
            Write-Host "  --cache-dir needs a build of master + PR 28092 (see win/README.md, Disk KV cache)." -ForegroundColor Red
            Write-Host "  either point -Bin at such a build, or say -NoCacheDir to boot RAM-only." -ForegroundColor Red
            exit 2
        }
        [Console]::Error.WriteLine("note: $Exe has no --cache-dir - prompt cache stays RAM-only.")
        $CacheDir = ''
        $CacheTag = 'unsupported'
    } else {
        if ((-not (Test-Path $CacheDir)) -and (-not $DryRun)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
        # The tag goes on the record line, and prof_field() in win/wsl-harness.sh only accepts
        # [A-Za-z0-9.,/-] - a Windows path with backslashes parses as "C", a plausible WRONG value
        # instead of nothing. So the record carries the identity leaf, not the full path.
        $CacheTag = '{0}/{1}MiB' -f $CacheId, $CacheMax
        if (-not $DryRun) {
            # One instance per cache dir: entries are opened with an exclusive handle, and an
            # instance that cannot read a sibling's metadata deletes it in its startup sweep.
            $others = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
            if ($others.Count) {
                [Console]::Error.WriteLine(("warning: {0} llama-server process(es) already running while the disk cache is on." -f $others.Count))
                [Console]::Error.WriteLine(("         give each instance its own -CacheDir or they will erase each other's entries in {0}" -f $CacheDir))
            }
            # Free space is information, never a reason to kill a boot: DriveInfo throws on a UNC or
            # otherwise odd path and $ErrorActionPreference is Stop, which would abort the launch with
            # a .NET message instead of the server's own output.
            try {
                $drv = New-Object System.IO.DriveInfo (($CacheDir -replace '\\.*', '\') + ':')
                $freeGB = [math]::Round($drv.AvailableFreeSpace / 1GB, 1)
                if ($freeGB -lt (($CacheMax / 1024) + 20)) {
                    [Console]::Error.WriteLine(("note: {0} GB free for a {1} MiB cache cap; an entry costs ~448 MiB + ~46 KiB/token." -f $freeGB, $CacheMax))
                }
            } catch {
                [Console]::Error.WriteLine(("note: could not check free space for {0} ({1})" -f $CacheDir, $_.Exception.Message))
            }
        }
    }
}

# llama.cpp requires n_ubatch <= n_batch and n_batch a multiple of n_ubatch, and it aborts partway
# through loading when they disagree. Refuse up front instead: a boot that dies after 12 GiB of
# weight upload looks like a memory problem, and the whole point here is not to misread those.
if (([int]$Ubatch -lt 1) -or ([int]$Ubatch -gt [int]$Batch) -or (([int]$Batch % [int]$Ubatch) -ne 0)) {
    Write-Host ("-Batch/-Ubatch invalid: {0}/{1} - llama.cpp requires ubatch <= batch and batch % ubatch == 0" -f $Batch, $Ubatch) -ForegroundColor Red
    exit 2
}

# ---- assemble args --------------------------------------------------------
$A = @(
    '-m', $ModelPath
    '--mmproj', $Mmproj
    '--jinja'
    '--image-min-tokens', '1024'
    '-sm', 'layer'
    '-c', "$CtxWant", '-np', '1'
    '-n', "$Npred"
    '-b', "$Batch", '-ub', "$Ubatch"
    '--host', $BindHost, '--port', "$Port"
    '--alias', $Alias
)
# Conditional, like serve.sh: a blank element in the array would hand llama-server an empty
# argument, and a stray trailing space once silently truncated a command.
if ($Split) { $A += @('--tensor-split', $Split) }
if ($Spec -and $Spec -ne 'none') { $A += @('--spec-type', $Spec, '--spec-draft-n-max', "$SpecMax") }
if ($Ngl)   { $A += @('-ngl', $Ngl) }
if ($Kv)    { $A += @('-ctk', $Kv, '-ctv', $Kv) }
if ($KvDraft)  { $A += @('-ctkd', $KvDraft, '-ctvd', $KvDraft) }
if ($OvTensor) { $A += @('-ot', $OvTensor) }
$A += @('--min-p', $MinP)
# Only when the disk tier is actually on. b11034 accepts -ctxcp/-cms happily, so sending them on a
# prebuilt boot would silently change its RAM-cache behaviour away from the numbers recorded for it
# - and the whole point of the probe's fallback path is "boot unchanged".
if ($CacheDir) {
    if ($Ctxcp -gt 0) { $A += @('-ctxcp', "$Ctxcp") }
    if ($Cms   -gt 0) { $A += @('-cms',   "$Cms") }
}
switch ($Mm) {
    'cpu'   { $A += @('--no-mmproj-offload') }
    '3080'  { $A += @('-mmdev', 'CUDA1') }
    'cuda0' { $A += @('-mmdev', 'CUDA0') }
    default { Write-Host "Mm must be cpu|3080|cuda0" -ForegroundColor Red; exit 2 }
}
# Cache flags go in only when the probe kept $CacheDir alive (see above).
if ($CacheDir) { $A += @('--cache-dir', $CacheDir, '--cache-dir-max', "$CacheMax") }

# ASSERT the command that will ACTUALLY EXEC - $A plus the passthrough tail. Asserting on $A alone
# left a hole: `serve.cmd --api-key <secret>` arrives through ValueFromRemainingArguments, lands in
# argv, and every assertion still passes while the summary prints AUTH=yes.
$Final = @($A) + @($ExtraArgs)
$flat = $Final -join ' '
foreach ($tok in $Final) {
    if ($tok -eq '--api-key' -or $tok -like '--api-key=*') {
        Write-Host 'refusing: the API key must not be in argv (any process that can enumerate' -ForegroundColor Red
        Write-Host 'command lines here could read it). Set LLAMA_API_KEY instead - serve.ps1' -ForegroundColor Red
        Write-Host 'resolves it from Process/User/Machine scope on its own.' -ForegroundColor Red
        exit 2
    }
}
# Auth must be active without the secret appearing in the assembled argv. On the WSL side a summary
# that read "AUTH=yes" once hid the fact that --api-key was never appended. Same trap here.
if ($Final -contains '--api-key') { Write-Host "internal error: -api-key must never be in argv" -ForegroundColor Red; exit 3 }
if ($key -and $env:LLAMA_API_KEY -ne $key.Value) { Write-Host "internal error: key resolved but not exported" -ForegroundColor Red; exit 3 }
if ($Final -notcontains $Alias) { Write-Host "internal error: --alias value missing from argv" -ForegroundColor Red; exit 3 }
# Requested != delivered. Tonight's lesson: -devd reached argv, was parsed, was printed back, and
# still did nothing - so assert what we can see, and let the log confirm what it actually did.
if ($OvTensor -and ($Final -notcontains '-ot'))   { Write-Host 'internal error: pin requested but -ot absent from argv' -ForegroundColor Red; exit 3 }
if ($KvDraft  -and ($Final -notcontains '-ctkd')) { Write-Host 'internal error: draft KV type requested but -ctkd absent from argv' -ForegroundColor Red; exit 3 }
$req = @('--tensor-split', '-ctk')
if ($Spec -and $Spec -ne 'none') { $req = @("--spec-type $Spec") + $req }
if ($CacheDir) { $req += @('--cache-dir', '--cache-dir-max') }
if ($CacheDir -and $Ctxcp -gt 0) { $req += '-ctxcp' }
if ($CacheDir -and $Cms   -gt 0) { $req += '-cms' }
foreach ($r in $req) {
    if ($flat -notlike "*$r*") { Write-Host "internal error: '$r' missing from argv" -ForegroundColor Red; exit 3 }
}

# Device-order guard. --tensor-split is positional in CUDA order, and on this box CUDA0 is the
# 5070 Ti - the *opposite* of nvidia-smi's index order. If an update ever inverts it, the split
# numbers silently mean the wrong cards, so check the live enumeration instead of assuming.
if (-not $NoVerify -and -not $DryRun) {
    $devs = (Get-MSNative -Exe $Exe -Arguments @('--list-devices')) -join "`n"
    if ($devs -notmatch "CUDA0:.*$([regex]::Escape($script:MSCuda0MustContain))") {
        Write-Host "REFUSING: CUDA0 is not the $script:MSCuda0MustContain, so -Split $Split favours the wrong card." -ForegroundColor Red
        Write-Host ($devs -replace '(?s)^.*Available devices', 'Available devices')
        Write-Host "  pass -NoVerify to override (and then re-derive the split), or fix -Split." -ForegroundColor Red
        exit 4
    }
    Write-Host ("devices ok: " + (($devs | Select-String 'CUDA\d' | ForEach-Object { $_.ToString().Trim() }) -join ' | ')) -ForegroundColor DarkGray
}

# Profile first, since that is the noun now (Tier is only the size knob within it).
$summary = 'P={0} Tier={1} -> CTX={2} NPRED={3} SPLIT={4} NGL={5} KV={6} MM={7} BATCH={8}/{9} MINP={10} SPEC={13} ALIAS={11} BIND={12} AUTH={14} CKPT={15} CACHE={16} BIN={17} PIN={18} KVD={19}' -f `
    $Q, $Tier, $CtxWant, $Npred, $Split, $Ngl, $Kv, $Mm, $Batch, $Ubatch, $MinP, $Alias, $BindHost, $Spec, $(if ($key) { 'yes' } else { 'no' }), ('{0}/{1}' -f $Ctxcp, $Cms), $CacheTag, $ExeTag, $(if ($OvTensor) { $OvTensor -replace '[^A-Za-z0-9.,/-]','' } else { 'none' }), $(if ($KvDraft) { $KvDraft } else { 'f16' })

if ($DryRun) {
    Write-Host $summary
    Write-Host (' ' + $Exe + ' ' + $flat)
    exit 0
}

Write-Host $summary
foreach ($f in $bindRes.Faces) { Write-Host ("url: {0}" -f $f) }
if ($bindRes.Hint) {
    Write-Host 'firewall: LAN clients still need the inbound rule (elevated, once):' -ForegroundColor DarkGray
    Write-Host ("  " + $bindRes.Hint) -ForegroundColor DarkGray
}
# exec-equivalent: this script's exit code becomes llama-server's. $Final, so the asserted command
# and the exec'd command are the same string and cannot disagree.
& $Exe @Final
exit $LASTEXITCODE
