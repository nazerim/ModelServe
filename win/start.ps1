<#
  start.ps1  -  start llama-server detached, then wait for the model to ACTUALLY load.

  Same reason start.sh exists: a fixed sleep lies to you. A 196K-context boot takes tens of
  seconds on NTFS and minutes if the model is still being read across the WSL bridge, so this
  polls /health and only then reports ready (or breaks early if the log shows an allocation
  failure, which is how a too-big CTX announces itself).

  Usage:
      .\start.ps1                                  # q3, ceiling ctx, bound to the WSL adapter IP
      .\start.ps1 -Q q4 -Tier medium
      .\start.ps1 -Bind loopback                   # Windows-only, no firewall/key needed
      .\start.ps1 -WhatIf                           # show the resolved command, launch nothing
      .\start.ps1 -TimeoutSec 600                   # first boot from a cold file cache

  Any knob you pass is forwarded to serve.ps1; anything you omit keeps serve.ps1's default.
  Logs: C:\ModelServe\logs\server.out.log + server.err.log, PID in C:\ModelServe\server.pid.
#>
[CmdletBinding()]
param(
    [string]$Q, [string]$P, [string]$Tier, [string]$Model, [string]$ModelDir,
    [int]$Ctx, [int]$Npred, [string]$Split, [string]$Ngl, [string]$Kv, [string]$Mm,
    [int]$Batch, [int]$Ubatch, [string]$MinP, [int]$Port, [string]$Bind, [string]$Alias,
    [string]$Spec, [int]$SpecMax, [int]$Ceil,
    [switch]$NoVerify,
    [int]$TimeoutSec = 300,
    [switch]$WhatIf
)

. (Join-Path $PSScriptRoot 'config.ps1')

$servePs1 = Join-Path $PSScriptRoot 'serve.ps1'
$LogDir = $script:MSLogs
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
$outLog = Join-Path $LogDir 'server.out.log'
$errLog = Join-Path $LogDir 'server.err.log'

# Refuse to stack a second server on top of a live one: two processes fighting over the same
# VRAM is the fastest route to the driver reset this box is already prone to.
if (Test-Path $script:MSPidFile) {
    $old = (Get-Content $script:MSPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
        Write-Host "already running as PID $old - use stop.ps1 first (or check.ps1)" -ForegroundColor Red
        exit 1
    }
}

# Forward ONLY what the caller actually set. Re-defaulting here would silently override
# serve.ps1's own defaults and the two files would drift apart.
$forward = @()
foreach ($name in @('Q','P','Tier','Model','ModelDir','Ctx','Npred','Split','Ngl','Kv','Mm',
                    'Batch','Ubatch','MinP','Port','Bind','Alias','Spec','SpecMax','Ceil')) {
    if ($PSBoundParameters.ContainsKey($name)) { $forward += ('-{0}' -f $name); $forward += ("" + $PSBoundParameters[$name]) }
}
if ($NoVerify) { $forward += '-NoVerify' }

$Port    = if ($Port) { $Port } else { 8000 }
# Resolve 'wsl' once, here, and hand serve.ps1 a literal address. Otherwise the child could
# pick a different adapter (a VPN adds one) than the IP we then poll and advertise.
$bindIn  = if ($Bind) { $Bind } elseif ($env:BIND) { $env:BIND } else { 'wsl' }
if ($bindIn -eq 'wsl') {
    $addr = Get-MSWslAddress
    if (-not $addr) { Write-Host "no vEthernet (WSL) adapter found - is WSL running?" -ForegroundColor Red; exit 1 }
    $BindHost = $addr.IP
    if ($forward -contains '-Bind') { } else { $forward += '-Bind'; $forward += $BindHost }
} elseif ($bindIn -match '^loopback|^127') {
    $BindHost = '127.0.0.1'
} else {
    $BindHost = $bindIn
}

# -WhatIf: reuse serve.ps1's own -DryRun so there is exactly ONE place that knows how the
# command line is assembled. Reimplementing it here would let the two disagree.
if ($WhatIf) {
    $dry = @($forward) + @('-DryRun')
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $servePs1 @dry
    Write-Host ("(would poll http://{0}:{1}/health, log {2})" -f $BindHost, $Port, $outLog)
    exit $LASTEXITCODE
}

$childArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $servePs1) + $forward
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $childArgs `
        -WorkingDirectory $script:MSBin `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Set-Content -Path $script:MSPidFile -Value $p.Id
Write-Host ("launched PID {0}  log {1}" -f $p.Id, $outLog)

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$startAt = Get-Date
function Trunc($s, $n) { if (-not $s) { return '' }; $s = ($s | Out-String) -replace "\r?\n", ' '; if ($s.Length -le $n) { return $s } else { return $s.Substring(0, $n) + '...' } }
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $elapsed = [int]((Get-Date) - $startAt).TotalSeconds
    if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
        Write-Host "process exited early - last log lines:" -ForegroundColor Red
        Get-Content $errLog, $outLog -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  ' + (Trunc $_ 170)) }
        Remove-Item $script:MSPidFile -ErrorAction SilentlyContinue
        exit 1
    }
    # A too-large context fails as an allocation abort, not as a slow load. Break on it
    # instead of waiting out the whole timeout.
    if ((Get-Content $outLog, $errLog -Tail 30 -ErrorAction SilentlyContinue) -join ' ' -match
        'out of memory|failed to allocate|SIGABRT|Segmentation|std::bad_alloc') {
        Write-Host "allocation failure in the log - last lines:" -ForegroundColor Red
        Get-Content $outLog, $errLog -Tail 10 | ForEach-Object { Write-Host ('  ' + (Trunc $_ 170)) }
        exit 1
    }
    $h = Get-MSHealth -Host_ $BindHost -Port $Port
    # Print where it actually is, every poll, with REAL elapsed seconds. A silent wait looks
    # exactly like a hang (it cost two blind timeouts before this line existed), and counting
    # iterations x 3 lied whenever a poll itself took longer than 3 s.
    Write-Host ('  [{0,4} s / {1} s] health={2}  log: {3}' -f $elapsed, $TimeoutSec, $(if ($h) { Trunc $h 60 } else { 'no-answer' }), (Trunc (Get-Content $errLog -Tail 1 -ErrorAction SilentlyContinue) 110))
    if ($h -and $h -like '*"ok"*') {
        $key = Resolve-MSApiKey
        $hdr = @{}
        if ($key) { $hdr['Authorization'] = 'Bearer ' + $key.Value }
        $served = ''
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Headers $hdr -Uri ('http://{0}:{1}/v1/models' -f $BindHost, $Port)
            $served = ((ConvertFrom-Json $r.Content).data | ForEach-Object { $_.id }) -join ', '
        } catch { $served = '<unreadable>' }
        Write-Host ("ready: {0}" -f $h)
        Write-Host ("  served as : {0}" -f $served)
        Write-Host ("  from WSL   : baseUrl http://{0}:{1}/v1" -f $BindHost, $Port)
        Write-Host '  in pi      : the model entry id must match the booted profile -' -ForegroundColor DarkGray
        Write-Host '               llama.cpp IGNORES the incoming model name, so a mismatch' -ForegroundColor DarkGray
        Write-Host '               lets pi over-declare the context.' -ForegroundColor DarkGray
        if (-not $key) { Write-Host "  WARNING: no LLAMA_API_KEY found; clients will get 401." -ForegroundColor Yellow }
        exit 0
    }
    if ($h -and $h -like '*health_not_supported*') { Write-Host "ready (health_not_supported): $h"; exit 0 }
}

Write-Host "NOT READY after ${TimeoutSec}s - last log lines:" -ForegroundColor Red
Get-Content $outLog, $errLog -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('  ' + (Trunc $_ 170)) }
exit 1
