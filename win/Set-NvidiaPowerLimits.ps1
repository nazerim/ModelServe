<#
  Set-NvidiaPowerLimits.ps1  -  apply NVIDIA power limits, resolving GPUs by NAME.

  Why not `-i 0` / `-i 1`: index order is assigned by the driver at enumeration time, so it
  can swap after a driver update or a hardware change - and a silently-wrong index puts the
  cap on the wrong card. This script looks each GPU up by name every run and exits non-zero
  on any mismatch, so Task Scheduler will retry instead of "succeeding" against nothing.

  Also handles the real boot race: nvidia-smi can answer before the power-management layer is
  ready, so it retries until the applied values read back correctly.

  Usage (elevated PowerShell):
      .\Set-NvidiaPowerLimits.ps1                       # defaults 150W RTX 3080 / 250W 5070 Ti
      .\Set-NvidiaPowerLimits.ps1 -VerifyOnly           # read back, change nothing
      .\Set-NvidiaPowerLimits.ps1 -Watts3080 170 -Watts5070Ti 260
#>
[CmdletBinding()]
param(
    [int]$Watts3080   = 150,
    [int]$Watts5070Ti = 250,
    [int]$Retries     = 12,
    [int]$DelaySec    = 10,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$logDir  = Join-Path $env:ProgramData 'ModelServe'
$logFile = Join-Path $logDir 'power-limits.log'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 's'), $msg
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# name substring -> requested watts
$Targets = @(
    @{ Match = 'RTX 3080';    Watts = $Watts3080   }
    @{ Match = 'RTX 5070 Ti'; Watts = $Watts5070Ti }
)

function Get-GpuTable {
    # nvidia-smi csv: index,name,power.limit,power.default_limit
    $raw = & nvidia-smi --query-gpu=index,name,power.limit,power.default_limit --format=csv,noheader,nounits 2>$null
    if (-not $raw) { return @() }
    ,@($raw | ForEach-Object {
        $c = $_ -split '\s*,\s*'
        if ($c.Count -ge 4) {
            [pscustomobject]@{ Index=[int]$c[0]; Name=$c[1]; Limit=[double]$c[2]; Default=[double]$c[3] }
        }
    })
}

for ($try = 1; $try -le $Retries; $try++) {
    $gpus = Get-GpuTable
    if ($gpus.Count -eq 0) { Log "attempt $try : nvidia-smi returned nothing (driver not ready?)"; Start-Sleep $DelaySec; continue }

    $pending = 0
    foreach ($t in $Targets) {
        $g = $gpus | Where-Object { $_.Name -like "*$($t.Match)*" } | Select-Object -First 1
        if (-not $g) { Log "attempt $try : no GPU matching '$($t.Match)' (seen: $($gpus.Name -join ' | '))"; $pending++; continue }

        if ([math]::Abs($g.Limit - $t.Watts) -lt 1) {
            Log ("attempt {0} : {1} [idx {2}] already at {3}W (default {4}W)" -f $try, $g.Name, $g.Index, [int]$g.Limit, [int]$g.Default)
            continue
        }
        $pending++
        if ($VerifyOnly) { Log "VERIFY-ONLY: $($g.Name) at $([int]$g.Limit)W, want $($t.Watts)W"; continue }

        Log ("attempt {0} : setting {1} [idx {2}] {3}W -> {4}W" -f $try, $g.Name, $g.Index, [int]$g.Limit, $t.Watts)
        # set by index resolved THIS run, and by bus id as a fallback
        $out = & nvidia-smi -pl $t.Watts -i $g.Index 2>&1
        if ($LASTEXITCODE -ne 0) {
            $bus = (& nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>$null |
                    Where-Object { $_ -like "$($g.Index),*" } | ForEach-Object { ($_ -split ',')[1] }).Trim()
            if ($bus) { $out = & nvidia-smi -pl $t.Watts -i "PCI:$bus" 2>&1 }
            Log "  set failed: $out"
        }
    }

    if ($pending -eq 0) { Log "DONE: all power limits correct"; exit 0 }
    if ($VerifyOnly)     { Log "VERIFY-ONLY complete (mismatches above)"; exit 1 }
    Start-Sleep $DelaySec
}

Log "GIVEUP: limits not applied after $Retries attempts"
exit 1
