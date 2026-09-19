<#
  install-windows.ps1  -  one-shot setup for native-Windows serving.

  Preferred entry point is install-windows.cmd (this box is AllSigned at LocalMachine scope,
  so ".\install-windows.ps1" is refused as "not digitally signed"; cmd.exe is not subject to
  ExecutionPolicy and -ExecutionPolicy Bypass sets Process scope, which outranks LocalMachine).

      C:\ModelServe\..\win\install-windows.cmd                     # binaries + q3 + mmproj
      ...\install-windows.cmd -Models all                          # all three quants (44 GB)
      ...\install-windows.cmd -Models none                         # binaries only
      ...\install-windows.cmd -Firewall -Port 8000                 # needs elevation
      ...\install-windows.cmd -RegisterTask                        # start at logon (elevated)

  WHAT IT DOES
    1. downloads the two pinned release assets (skip if already cached at the right size)
    2. extracts them FLAT into C:\ModelServe\llama - the CUDA runtime DLLs must sit next to
       the exes, because Windows has no LD_LIBRARY_PATH equivalent
    3. copies the requested GGUFs from WSL (\\wsl.localhost\...) onto NTFS and verifies size
    4. creates the inbound firewall rule scoped to the WSL subnet only
    5. verifies: version, --list-devices device order, then prints the baseUrl for pi

  WHAT IT DELIBERATELY DOES NOT DO
    - install CUDA, Visual Studio, or any system package: the prebuilts are self-contained
    - copy models back, or delete the ext4 originals: the WSL setup stays the fallback, so
      this is copy-only. Disk cost is ~14 GiB (q3+mmproj) or ~44 GiB (all).
    - set power limits: that is install-power-limits.cmd's job (already done on this box)
    - trust WSL's measured ceilings: it prints them as unverified starting points
#>
[CmdletBinding()]
param(
    [string]$Models    = 'q3,mmproj',   # comma list: q3,q4s,q4,mmproj | all | none
    [string]$SrcDir  = $(if ($env:WSL_MODELS) { $env:WSL_MODELS } else { '\\wsl.localhost\Ubuntu-26.04\home\naz\.models' }),
    [string]$Port    = '8000',
    [switch]$Firewall,
    [switch]$RegisterTask,
    [switch]$Force,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'config.ps1')

function Step($n, $m) { Write-Host ("`n[{0}] {1}" -f $n, $m) -ForegroundColor Cyan }
function Info($m)     { Write-Host ("      " + $m) }
function Bad($m)      { Write-Host ("  !! " + $m) -ForegroundColor Red }

# ---- 0. preflight ---------------------------------------------------------
Step 0 'preflight'
if ($env:OS -ne 'Windows_NT') { Bad 'this script is for Windows; run it from powershell.exe'; exit 1 }
if ([Environment]::Is64BitOperatingSystem -eq $false) { Bad 'x64 required'; exit 1 }
Info "PS version    $($PSVersionTable.PSVersion)"
Info "PSModulePath  scope: no modules needed"
Info "root          $script:MSRoot"
Info "build pin     $script:MSBuild  (CUDA $script:MSCuda)"

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info ("elevated      " + $(if ($elevated) { 'yes' } else { 'no - firewall/task steps will only print their commands' }))

foreach ($d in @($script:MSRoot, $script:MSBin, $script:MSModels, $script:MSLogs, (Join-Path $script:MSRoot 'dl'))) {
    if (-not (Test-Path $d)) { if ($DryRun) { Info "(would create $d)" } else { New-Item -ItemType Directory -Force -Path $d | Out-Null; Info "created $d" } }
}

# Deploy these scripts onto NTFS. The repo checkout lives inside the distro, so anything that
# runs later - start.ps1 from a scheduled task, check.ps1 from a terminal - would otherwise
# depend on a WSL distro being mounted and up. The power-limit task already learned that the
# hard way (see Register-NvidiaPowerTask.ps1's UNC guard).
$winLocal = Join-Path $script:MSRoot 'win'
$here = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
if ($here -ne $winLocal) {
    if ($DryRun) { Info "(would copy $here\*.ps1,*.cmd -> $winLocal)" }
    else {
        if (-not (Test-Path $winLocal)) { New-Item -ItemType Directory -Force -Path $winLocal | Out-Null }
        Copy-Item (Join-Path $here '*.ps1')  $winLocal -Force
        Copy-Item (Join-Path $here '*.cmd')  $winLocal -Force
        Info "deployed scripts -> $winLocal (use those copies from now on; the repo stays the source)"
    }
} else {
    Info "running from the deployed copy ($winLocal)"
}

# ---- 1. binaries ----------------------------------------------------------
Step 1 'release assets'
# Sizes as reported by the GitHub release API for b11034. A mismatch is not proof of tampering
# (llama.cpp publishes no checksums for these assets) but it does catch a truncated download,
# which is the failure that actually happens - and Expand-Archive on a partial zip is confusing.
$want = @{
    'llama-b11034-bin-win-cuda-13.4-x64.zip' = 150102460
    'cudart-llama-bin-win-cuda-13.4-x64.zip' = 423535356
}
$dlDir = Join-Path $script:MSRoot 'dl'
foreach ($asset in $script:MSAssets) {
    $dest = Join-Path $dlDir $asset
    if ($Force -and (Test-Path $dest)) { Remove-Item $dest -Force }
    $have = if (Test-Path $dest) { (Get-Item $dest).Length } else { 0 }
    if ($have -eq $want[$asset]) {
        Info ("cached ok   {0}  {1:N0} bytes" -f $asset, $have)
    } else {
        $url = "https://github.com/ggml-org/llama.cpp/releases/download/$($script:MSBuild)/$asset"
        if ($DryRun) { Info "(would download $url)"; continue }
        Info "downloading $url"
        # Invoke-WebRequest on PS 5.1 is slow with the progress bar; that is normal, not a hang.
        $ProgressPreference = 'SilentlyContinue'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest -TimeoutSec 900
        } catch {
            Bad "download failed: $($_.Exception.Message)"
            Bad "fallback from WSL:  curl -fL -o /mnt/c/ModelServe/dl/$asset '$url'"
            exit 1
        }
        $got = (Get-Item $dest).Length
        if ($got -ne $want[$asset]) { Bad ("size mismatch: got {0:N0} want {1:N0} - delete and retry" -f $got, $want[$asset]); exit 1 }
        Info ("got          {0}  {1:N0} bytes" -f $asset, $got)
    }
}

Step 2 'extract (flat, beside the exes)'
foreach ($asset in $script:MSAssets) {
    $dest = Join-Path $dlDir $asset
    if (-not (Test-Path $dest)) { continue }
    if ($DryRun) { Info "(would expand $asset -> $script:MSBin)"; continue }
    Expand-Archive -Path $dest -DestinationPath $script:MSBin -Force
}
$exeCount = (Get-ChildItem $script:MSBin -Filter '*.exe' -ErrorAction SilentlyContinue | Measure-Object).Count
$dllCount = (Get-ChildItem $script:MSBin -Filter '*.dll' -ErrorAction SilentlyContinue | Measure-Object).Count
Info "$exeCount exes, $dllCount dlls in $script:MSBin"
foreach ($need in @('llama-server.exe', 'ggml-cuda.dll', 'cublasLt64_13.dll', 'cudart64_13.dll')) {
    if (-not (Test-Path (Join-Path $script:MSBin $need))) { Bad "missing $need after extraction"; exit 1 }
}

# ---- 3. models onto NTFS --------------------------------------------------
Step 3 'models on NTFS'
$pick = [ordered]@{
    q3     = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'
    q4s    = 'Qwen3.8-27B-UD-Q4_K_S.gguf'
    q4     = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'
    mmproj = 'mmproj-F16.gguf'
}
# Split the comma list ourselves and validate each token: a [string[]] param + ValidateSet
# rejects "q3,mmproj" as a single non-member when it arrives through cmd.exe, which is exactly
# how install-windows.cmd passes it through.
$tokens = @($Models -split '[, ;]' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
$bad = @($tokens | Where-Object { -not ($pick.Contains($_) -or @('all', 'none') -contains $_) })
if ($bad.Count) {
    Bad ("unknown -Models value(s): " + ($bad -join ', ') + "  (valid: " + (($pick.Keys) -join ', ') + ", all, none)")
    exit 2
}
if ($tokens -contains 'none') { $files = @() }
elseif ($tokens -contains 'all') { $files = $pick.Values }
else { $files = @($tokens | ForEach-Object { $pick[$_] } | Where-Object { $_ } | Select-Object -Unique) }

if ($files.Count -eq 0) {
    Info "nothing to copy (-Models none) - pass -Model <path> to serve.ps1 if the GGUFs live elsewhere"
} elseif (-not (Test-Path $SrcDir)) {
    Bad "source not found: $SrcDir"
    Bad "distros visible right now:"
    & wsl.exe -l -q 2>$null | ForEach-Object { if ($_) { Info "  $_" } }
    Bad "override with:  -SrcDir \\wsl.localhost\<Distro>\home\<user>\.models   (or WSL_MODELS=...)"
    exit 1
} else {
    foreach ($f in $files) {
        $src = Join-Path $SrcDir $f
        $dst = Join-Path $script:MSModels $f
        if (-not (Test-Path $src)) { Bad "no such source file: $src"; exit 1 }
        $srcLen = (Get-Item $src).Length
        if ((Test-Path $dst) -and ((Get-Item $dst).Length -eq $srcLen) -and -not $Force) {
            Info ("already there  {0}  {1:N2} GiB" -f $f, ($srcLen / 1GB)); continue
        }
        if ($DryRun) { Info "(would robocopy $src -> $script:MSModels)"; continue }
        Info ("copying        {0}  {1:N2} GiB  (across the WSL bridge; ~1-2 min per 10 GiB)" -f $f, ($srcLen / 1GB))
        # robocopy takes SOURCE DIR + file name, not a file path - passing the path makes it
        # look for a directory named after the .gguf and it dies with ERROR 267.
        # /Z = restartable, so an interrupted 12 GiB copy resumes instead of restarting.
        # /NP no progress spam, /NFL+/NDL keeps the log to a summary. Exit codes 0-7 are success.
        $rc = Start-Process robocopy.exe -ArgumentList @("`"$SrcDir`"", "`"$script:MSModels`"", $f, '/Z', '/NP', '/NFL', '/NDL', '/R:3', '/W:2', "/LOG+:$(Join-Path $script:MSLogs 'robocopy.log')") -Wait -NoNewWindow -PassThru
        if ($rc.ExitCode -gt 7) { Bad "robocopy failed with exit code $($rc.ExitCode) - see $script:MSLogs\robocopy.log"; exit 1 }
        $dstLen = if (Test-Path $dst) { (Get-Item $dst).Length } else { -1 }
        if ($dstLen -ne $srcLen) { Bad ("size mismatch after copy: {0} vs source {1}" -f $dstLen, $srcLen); exit 1 }
        Info ("verified       {0}  {1:N2} GiB matches the ext4 original" -f $f, ($dstLen / 1GB))
    }
}

# ---- 4. firewall ----------------------------------------------------------
Step 4 'firewall (WSL -> Windows inbound)'
$addr = Get-MSWslAddress
if (-not $addr) {
    Bad 'no vEthernet (WSL) adapter found - start WSL first, then re-run'
} else {
    Info ('adapter {0}  host IP {1}  subnet {2}' -f $addr.Alias, $addr.IP, $addr.Subnet)
    $name = 'ModelServe llama-server (WSL only)'
    $existing = $null
    try { $existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue } catch { }
    if ($existing) {
        Info "rule already present: $name"
    } elseif (-not $Firewall) {
        Info "not creating a rule (-Firewall not given). Without one, WSL clients get connection-refused:"
        Info ("  New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Action Allow ``")
        Info ("    -Protocol TCP -LocalPort $Port -RemoteAddress {0} -Profile Any" -f $addr.Subnet)
    } elseif (-not $elevated) {
        Bad '-Firewall needs elevation. Re-run from an elevated prompt, or run:'
        Bad ("  New-NetFirewallRule -DisplayName '$name' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -RemoteAddress {0} -Profile Any" -f $addr.Subnet)
    } else {
        if ($DryRun) { Info "(would create inbound allow for TCP $Port from $($addr.Subnet) only)"; }
        else {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP `
                -LocalPort ([int]$Port) -RemoteAddress $addr.Subnet -Profile Any | Out-Null
            Info "created: $name  (TCP $Port from $($addr.Subnet) only - the LAN stays closed)"
        }
    }
}

# ---- 5. optional boot task -----------------------------------------------
Step 5 'start at logon'
if ($RegisterTask) {
    # Same guard the power-limit task learned: a task that points into \\wsl.localhost depends
    # on a distro that may not be up yet, and dies when the distro path moves. Copy the scripts
    # onto NTFS and register from there.
    $winLocal = Join-Path $script:MSRoot 'win'
    if ($PSScriptRoot -like '\\*') {
        if (-not (Test-Path $winLocal)) { New-Item -ItemType Directory -Force -Path $winLocal | Out-Null }
        Copy-Item (Join-Path $PSScriptRoot '*.ps1') $winLocal -Force
        Info "copied the scripts out of the WSL path -> $winLocal"
    } else { $winLocal = $PSScriptRoot }
    $taskName = 'ModelServe llama-server'
    if (-not $elevated) {
        Bad '-RegisterTask needs elevation for the task principal. Re-run elevated, or register manually:'
        Bad ("  schtasks /Create /TN ""$taskName"" /SC ONLOGON /RL LIMITED /TR ""powershell.exe -NoProfile -ExecutionPolicy Bypass -File '{0}\start.ps1'""" -f $winLocal)
    } elseif ($DryRun) { Info "(would register $taskName -> $winLocal\start.ps1)" }
    else {
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\start.ps1"' -f $winLocal) `
            -WorkingDirectory $winLocal
        # ONLOGON, not SYSTEM-at-startup: under WDDM the GPU path is happiest inside an
        # interactive session, and a headless SYSTEM launch is a known source of CUDA-init
        # weirdness. Requires staying logged in (lock is fine, logoff is not).
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)) `
            -Description 'Starts the native llama-server (ModelServe)' | Out-Null
        Info "registered: $taskName (at logon, current user)"
    }
} else { Info "not registering a task (-RegisterTask); start it with start.ps1" }

# ---- 6. verify ------------------------------------------------------------
Step 6 'verify'
if ($DryRun) { Info "DryRun - nothing launched; re-run without -DryRun to install"; exit 0 }
Set-Location $script:MSBin
 Info (((Get-MSNative -Exe $script:MSExe -Arguments @('--version')) | Select-Object -Last 2) -join ' ')
$devs = (Get-MSNative -Exe $script:MSExe -Arguments @('--list-devices')) | Select-String 'CUDA\d'
$devs | ForEach-Object { Info $_.ToString().Trim() }
if ($devs -join ' ' -match "CUDA0:.*$([regex]::Escape($script:MSCuda0MustContain))") {
    Info "device order matches the splits in config.ps1"
} else {
    Bad 'CUDA0 is NOT the 5070 Ti - the splits in config.ps1 are wrong for this machine. Re-derive before serving.'
}

Write-Host ""
Write-Host "next steps:" -ForegroundColor Green
Write-Host "  1. power limits are already applied by install-power-limits.cmd (150W / 250W) - check.ps1 re-reads them"
Write-Host "  2. .\check.ps1                      # preflight: devices, TDR, sleep, key, rule"
Write-Host "  3. .\start.ps1                      # boots q3 at the WSL-derived ceiling; re-measure it here"
Write-Host "  4. from WSL:  win/probe-from-wsl.sh   # proves the network path + auth end to end"
Write-Host ("  5. pi baseUrl for the Windows entries: http://{0}:{1}/v1" -f $(if ($addr) { $addr.IP } else { '<wsl-host-ip>' }), $Port)
Write-Host "     (that IP is the WSL adapter address and CAN change across boots - probe-from-wsl.sh"
Write-Host "      re-prints it, and mirrored networking is the way to make it stop mattering)"
