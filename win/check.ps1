<#
  check.ps1  -  read-only preflight for native-Windows serving.

  Nothing here changes state (except creating the log dir on first run). Run it before a
  benchmark day and after any reboot/driver update: several of these values are volatile or
  dynamic, and each one has already bitten this box once -
    * device order decides what --tensor-split means
    * the WSL adapter IP changes across boots
    * power limits reset to default when the driver loads
    * TDR resets the GPU if a submission blocks too long (WDDM only; WSL hides this)
    * a sleeping machine takes the server and both contexts with it

      check.cmd                # default port 8000
      check.cmd -Port 9000

  (check.cmd exists because LocalMachine execution policy on this box is AllSigned, which refuses
  a bare ".\check.ps1"; cmd.exe is not subject to ExecutionPolicy.)
#>
[CmdletBinding()]
param([int]$Port = 8000)

. (Join-Path $PSScriptRoot 'config.ps1')

function Line($k, $v, $warn) {
    $c = 'Gray'; if ($warn -eq 'ok') { $c = 'Green' } elseif ($warn) { $c = 'Yellow' }
    Write-Host ('  {0,-26}' -f $k) -NoNewline
    Write-Host $v -ForegroundColor $c
}
function Section($m) { Write-Host ("`n" + $m) -ForegroundColor Cyan }

Section 'MODEL-SERVE NATIVE CHECK'
Line 'root'      $script:MSRoot
Line 'build pin' ($script:MSBuild + ' / CUDA ' + $script:MSCuda)

Section 'binaries'
if (Test-Path $script:MSExe) {
    # No Set-Location here: this script promises to change nothing, and a bare Set-Location
    # persists in the caller's session after it returns. The exe is called by absolute path, and
    # serve.ps1 has always done exactly that from C:\ - Windows resolves an app's own directory
    # for its DLLs regardless of cwd.
    $v = (Get-MSNative -Exe $script:MSExe -Arguments @('--version')) -join "`n"
    $verLine = ($v | Select-String 'build|commit|version' | Select-Object -First 1)
    # Guarded: ToString() on an empty Select-String result is a null-method call, and config.ps1
    # runs this whole file under ErrorActionPreference='Stop' - so a version string that changes
    # format would abort the preflight, on the one path where the preflight matters most.
    if ($verLine) { Line 'llama-server' "$verLine".Trim() } else { Line 'llama-server' 'ran, but no version line matched' 'warn' }
    foreach ($d in @('ggml-cuda.dll', 'cublasLt64_13.dll', 'cudart64_13.dll', 'llama-common.dll')) {
        $f = Join-Path $script:MSBin $d
        if (Test-Path $f) { Line $d 'present' 'ok' }
        else { Line $d 'MISSING - cudart zip not extracted into this folder' 'warn' }
    }
} else {
    Line 'llama-server.exe' "missing - run install-windows.cmd" 'warn'
}

Section 'devices (decides what --tensor-split means)'
if (Test-Path $script:MSExe) {
    $devs = ((Get-MSNative -Exe $script:MSExe -Arguments @('--list-devices')) | Select-String 'CUDA\d') -join "`n"
    if ($devs -match "CUDA0:.*$([regex]::Escape($script:MSCuda0MustContain))") {
        Line 'CUDA0' 'the 5070 Ti, as the splits assume' 'ok'
    } else {
        Line 'CUDA0' "NOT the $script:MSCuda0MustContain - re-derive every split before trusting one" 'warn'
    }
    ($devs -split "`n") | ForEach-Object { Line '' $_.ToString().Trim() }
} else { Line '' 'skipped (no binary)' 'warn' }

Section 'driver / power / TDR'
$smi = & nvidia-smi.exe --query-gpu=name,memory.total,memory.used,power.limit,power.max_limit --format=csv,noheader 2>$null
if ($smi) { $smi | ForEach-Object { Line '' $_ } }
$gd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue
if ($gd) {
    Line 'TdrLevel'  $(if ($null -ne $gd.TdrLevel)  { $gd.TdrLevel }  else { 'default (3 = reset on timeout)' })
    Line 'TdrDelay'  $(if ($null -ne $gd.TdrDelay)  { "$($gd.TdrDelay) s" } else { 'default (2 s)' }) $(if ($null -eq $gd.TdrDelay -or $gd.TdrDelay -lt 8) { 'warn' } else { $null })
    if ($null -eq $gd.TdrDelay -or $gd.TdrDelay -lt 8) {
        Line '' 'long prefills on the display GPU can trip the watchdog; raise TdrDelay (needs a reboot)' 'warn'
    }
} else { Line 'GraphicsDrivers' 'unreadable' 'warn' }

Section 'sleep (a sleeping host kills the server mid-context)'
$scheme = (powercfg /getactivescheme) -join ''
Line 'scheme' ($scheme.Trim())
$s3 = ((powercfg /a) | Select-String 'Standby \(S3\)') -join ''
if ($S3) { Line 'S3 sleep' 'supported - verify the PC will not sleep while serving' 'warn' } else { Line 'S3 sleep' 'not offered on this config' 'ok' }

Section 'memory / disk'
$os = Get-CimInstance Win32_OperatingSystem
Line 'host RAM' ('{0} GB total, {1} GB free' -f [math]::Round($os.TotalVisibleMemorySize / 1MB, 1), [math]::Round($os.FreePhysicalMemory / 1MB, 1))
$pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
if ($pf) {
    # Build the strings first: '-f' binds tighter than '-join', so inlining the join made the
    # format operator see one argument and throw.
    $pfName   = ($pf | ForEach-Object { $_.Name }) -join ', '
    $pfAllocGB = [math]::Round((($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum) / 1MB, 1)
    Line 'page file' ('{0} ({1} GB alloc)' -f $pfName, $pfAllocGB)
}
foreach ($d in @($script:MSRoot)) {
    $drive = ([System.IO.DriveInfo](($d -replace '\\.*', '\') + ':'))
    Line ('free on ' + $drive.Name) ('{0} GB' -f [math]::Round($drive.AvailableFreeSpace / 1GB, 1)) $(if ($drive.AvailableFreeSpace / 1GB -lt 50) { 'warn' } else { $null })
}

Section 'models on NTFS'
if (Test-Path $script:MSModels) {
    Get-ChildItem $script:MSModels -Filter '*.gguf' | Sort-Object Name | ForEach-Object {
        Line $_.Name ('{0:N2} GiB' -f ($_.Length / 1GB))
    }
    if (-not (Get-ChildItem $script:MSModels -Filter 'mmproj*' | Measure-Object).Count) {
        Line 'mmproj' 'MISSING - vision will not load' 'warn'
    }
} else { Line $script:MSModels 'no such directory - install-windows.cmd -Models ...' 'warn' }

Section 'network path (WSL -> Windows)'
$addr = Get-MSWslAddress
if ($addr) {
    Line 'wsl adapter' ('{0} = {1}/{2}' -f $addr.Alias, $addr.IP, $addr.Prefix) 'ok'
    Line 'wsl subnet'  $addr.Subnet
    $prof = Get-NetConnectionProfile -InterfaceAlias $addr.Alias -ErrorAction SilentlyContinue
    if ($prof) { Line 'firewall profile' $prof.NetworkCategory } else { Line 'firewall profile' 'unclassified (Public by default)' }
    # Measured on this box (2026-09-19): WSL -> host TCP reached the server with NO inbound rule
    # at all, because this adapter is the "vEthernet (WSL (Hyper-V firewall))" one and WSL-origin
    # traffic is not subject to the Defender firewall the way LAN traffic is. So a missing rule is
    # NOT proof of breakage - probe-from-wsl.sh is the authority, this is only inventory.
    $rule = $null
    try {
        # By display name (the exact string install-windows.ps1 creates) rather than enumerating
        # every TCP port filter in the firewall store and re-opening a rule per hit: this is a
        # after-every-reboot ritual, and the sweep was the slowest line in the file.
        $rule = Get-NetFirewallRule -DisplayName 'ModelServe llama-server (WSL only)' -ErrorAction SilentlyContinue
    } catch { Line 'firewall rules' 'cannot enumerate (run elevated to check)' 'warn' }
    if ($rule) { $rule | ForEach-Object { Line 'rule' ('{0} enabled={1} action={2}' -f $_.DisplayName, $_.Enabled, $_.Action) } }
    elseif ($null -eq $rule) { Line ('rule for TCP ' + $Port) 'none - fine if probe-from-wsl.sh says OPEN; add one only if it does not' }
} else { Line 'wsl adapter' 'not found - is WSL installed/running?' 'warn' }

Section 'auth'
$key = Resolve-MSApiKey
if ($key) { Line 'LLAMA_API_KEY' ('set ({0} scope, {1} chars)' -f $key.Scope, $key.Value.Length) 'ok' }
else { Line 'LLAMA_API_KEY' 'not set in Process/User/Machine -> non-loopback binds refused' 'warn' }

Section 'running now?'
if (Test-Path $script:MSPidFile) {
    $pid_ = (Get-Content $script:MSPidFile | Select-Object -First 1)
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) { Line 'pid file' "$pid_ alive" 'ok' } else { Line 'pid file' "stale ($pid_)" 'warn' }
} else { Line 'pid file' 'none' }
$listening = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($listening) { $listening | ForEach-Object { Line 'listener' ('{0}:{1} pid {2}' -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess) } }
else { Line 'listener' ("nothing on {0}" -f $Port) }
$h = Get-MSHealth -Host_ '127.0.0.1' -Port $Port
if (-not $h -and $addr) { $h = Get-MSHealth -Host_ $addr.IP -Port $Port }
if ($h) { Line 'health' $h 'ok' } else { Line 'health' 'no answer' }

Write-Host "`nlog dir: $script:MSLogs" -ForegroundColor DarkGray
