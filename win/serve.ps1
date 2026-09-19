<#
  serve.ps1  -  foreground llama-server on native Windows. Twin of ../serve.sh.

  Usage - via the policy-proof wrapper (this box is AllSigned at LocalMachine scope, so a bare
  ".\serve.ps1" is refused with "is not digitally signed"; cmd.exe is not subject to
  ExecutionPolicy and -ExecutionPolicy Bypass sets Process scope, which outranks LocalMachine):

      serve.cmd                                   # q3, WSL-safe ceiling, bound for WSL clients
      serve.cmd -P q3l                            # 225,280 ctx + 512/128 batch
      serve.cmd -P q4 -Tier medium
      serve.cmd -DryRun                           # print the resolved command, launch nothing
      serve.cmd -Bind loopback                    # Windows-local only, no key required

  (The underlying .ps1 can still be called directly as long as Bypass is passed, which is what
  serve.cmd does, and what the WSL-side harness scripts do: from WSL, call
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ModelServe\win\...)

  -Bind defaults to 'wsl': the vEthernet (WSL) adapter address, so a client inside WSL can
  reach it while the LAN cannot (0.0.0.0 is refused without a key, same policy as serve.sh).
  Everything is env-overridable too, so start.ps1 and a Task Scheduler entry can pass knobs
  without editing this file:  $env:Q / $env:CTX / $env:SPLIT / ...

  The ceilings and splits are WSL measurements; see config.ps1 and win/README.md.
#>
[CmdletBinding()]
param(
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
    [switch]$NoVerify,
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ExtraArgs
)

. (Join-Path $PSScriptRoot 'config.ps1')

# Defaults that come from config.ps1 must be applied AFTER dot-sourcing it: a param default is
# evaluated before the body runs, so $script:MSModels is still $null there (this bit me once).
if (-not $ModelDir) { $ModelDir = $script:MSModels }

# Capture the requested override BEFORE the profile lookup overwrites $Ceil - the param is also
# named -Ceil, so reading it after the table lookup would always yield the profile default.
$CeilReq = $Ceil

# ---- resolve profile + tier ---------------------------------------------
# -P names a profile (q3|q3l|q4s|q4). -Q is a synonym, so the WSL habit of "Q=q4s TIER=medium"
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
    if (-not $Split) { $Split = '17.4,7.7' }
} else {
    $prof  = $script:MSProfiles[$Q]
    $ModelPath = Join-Path $ModelDir $prof.File
    $Ceil  = [int]$prof.Ceil
    if ($CeilReq) { $Ceil = $CeilReq }                  # unless the caller was explicit
    if (-not $Alias) { $Alias = $prof.Alias }
    if (-not $Split) { $Split = $prof.Split }
    # The profile's batch applies only when nobody asked otherwise. q3l's 225,280 was measured
    # WITH 512/128; the same context at the default batch measured 275 MiB at 212,992, so letting
    # the batch silently fall back would turn a SAFE profile into a borderline one.
    if ($prof.Batch -and -not $PSBoundParameters.ContainsKey('Batch') -and -not $env:BATCH) {
        $Batch = [int]$prof.Batch
        # -Ubatch is honoured independently of -Batch: a caller asking only for a smaller ubatch
        # must not have it silently rewritten to the profile's value.
        if (-not $PSBoundParameters.ContainsKey('Ubatch') -and -not $env:UBATCH) { $Ubatch = [int]$prof.Ubatch }
    }
}

# Tier picks a size WITHIN a profile; max = that profile's measured ceiling. A smaller tier on
# q3l still uses 512/128 - harmless, marginally slower pp - rather than carrying a second set of
# numbers nobody has measured.
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
if (-not (Test-Path $script:MSExe)) {
    Write-Host "missing $script:MSExe - run install-windows.cmd first" -ForegroundColor Red; exit 1
}
if (-not (Test-Path $ModelPath)) {
    Write-Host "no such model: $ModelPath" -ForegroundColor Red
    Write-Host "  models live on NTFS for the native server; copy them with:" -ForegroundColor Red
    Write-Host "      install-windows.cmd -Models q3,mmproj" -ForegroundColor Red
    exit 1
}
$Mmproj = Join-Path $ModelDir 'mmproj-F16.gguf'
if (-not (Test-Path $Mmproj)) { Write-Host "no such mmproj: $Mmproj" -ForegroundColor Red; exit 1 }

# Bind resolution. 'wsl' is the point of this whole track: Windows serves, WSL connects.
switch -Regex ($Bind) {
    '^wsl$' {
        $addr = Get-MSWslAddress
        if (-not $addr) {
            Write-Host "no vEthernet (WSL) adapter found - is WSL installed and running?" -ForegroundColor Red; exit 1
        }
        $BindHost = $addr.IP
        [Console]::Error.WriteLine(("bind = {0}  ({1}, subnet {2})" -f $BindHost, $addr.Alias, $addr.Subnet))
    }
    '^loopback$|^127' { $BindHost = '127.0.0.1' }
    default           { $BindHost = $Bind }
}

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
$A += @('--min-p', $MinP)
switch ($Mm) {
    'cpu'   { $A += @('--no-mmproj-offload') }
    '3080'  { $A += @('-mmdev', 'CUDA1') }
    'cuda0' { $A += @('-mmdev', 'CUDA0') }
    default { Write-Host "Mm must be cpu|3080|cuda0" -ForegroundColor Red; exit 2 }
}

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
$req = @('--tensor-split', '-ctk')
if ($Spec -and $Spec -ne 'none') { $req = @("--spec-type $Spec") + $req }
foreach ($r in $req) {
    if ($flat -notlike "*$r*") { Write-Host "internal error: '$r' missing from argv" -ForegroundColor Red; exit 3 }
}

# Device-order guard. --tensor-split is positional in CUDA order, and on this box CUDA0 is the
# 5070 Ti - the *opposite* of nvidia-smi's index order. If an update ever inverts it, the split
# numbers silently mean the wrong cards, so check the live enumeration instead of assuming.
if (-not $NoVerify -and -not $DryRun) {
    $devs = (Get-MSNative -Exe $script:MSExe -Arguments @('--list-devices')) -join "`n"
    if ($devs -notmatch "CUDA0:.*$([regex]::Escape($script:MSCuda0MustContain))") {
        Write-Host "REFUSING: CUDA0 is not the $script:MSCuda0MustContain, so -Split $Split favours the wrong card." -ForegroundColor Red
        Write-Host ($devs -replace '(?s)^.*Available devices', 'Available devices')
        Write-Host "  pass -NoVerify to override (and then re-derive the split), or fix -Split." -ForegroundColor Red
        exit 4
    }
    Write-Host ("devices ok: " + (($devs | Select-String 'CUDA\d' | ForEach-Object { $_.ToString().Trim() }) -join ' | ')) -ForegroundColor DarkGray
}

# Profile first, since that is the noun now (Tier is only the size knob within it).
$summary = 'P={0} Tier={1} -> CTX={2} NPRED={3} SPLIT={4} NGL={5} KV={6} MM={7} BATCH={8}/{9} MINP={10} SPEC={13} ALIAS={11} BIND={12} AUTH={14}' -f `
    $Q, $Tier, $CtxWant, $Npred, $Split, $Ngl, $Kv, $Mm, $Batch, $Ubatch, $MinP, $Alias, $BindHost, $Spec, $(if ($key) { 'yes' } else { 'no' })

if ($DryRun) {
    Write-Host $summary
    Write-Host (' ' + $script:MSExe + ' ' + $flat)
    exit 0
}

Write-Host $summary
Write-Host ("url: http://{0}:{1}/v1  (from WSL: same IP, and pi's baseUrl must use it)" -f $BindHost, $Port)
# exec-equivalent: this script's exit code becomes llama-server's. $Final, so the asserted command
# and the exec'd command are the same string and cannot disagree.
& $script:MSExe @Final
exit $LASTEXITCODE
