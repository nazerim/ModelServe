<#
  stop.ps1  -  stop the native server and show that VRAM actually came back.

  .\stop.ps1            # stop the PID in server.pid (falls back to matching our own install)
  .\stop.ps1 -VerifyOnly  # change nothing, just report what holds GPU memory
#>
[CmdletBinding()]
param([switch]$VerifyOnly)

. (Join-Path $PSScriptRoot 'config.ps1')

function Show-GpuApps {
    $q = & nvidia-smi.exe --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>$null
    if ($q) { $q | ForEach-Object { Write-Host ("  " + $_) } } else { Write-Host "  (no compute processes on either GPU)" }
}

if ($VerifyOnly) { Write-Host "GPU compute processes:"; Show-GpuApps; exit 0 }

$stopped = @()

if (Test-Path $script:MSPidFile) {
    $pid_ = (Get-Content $script:MSPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($pid_ -and (Get-Process -Id $pid_ -ErrorAction SilentlyContinue)) {
        # Kill the whole tree: start.ps1 spawns powershell.exe -> serve.ps1 -> llama-server.exe,
        # and stopping only the launcher would leave the server holding 17 GiB of VRAM.
        $kids = Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $pid_) -ErrorAction SilentlyContinue
        foreach ($k in $kids) {
            Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped += ('child ' + $k.ProcessId + ' (' + $k.Name + ')')
        }
        Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
        $stopped += ('pid ' + $pid_)
    }
    Remove-Item $script:MSPidFile -ErrorAction SilentlyContinue
}

# Anything still running OUR binary (e.g. a foreground serve.ps1 from another window).
$mine = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like ($script:MSBin + '\*') }
foreach ($m in $mine) {
    Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue
    $stopped += ('path-match ' + $m.ProcessId + ' (' + $m.Name + ')')
}

if ($stopped.Count) {
    Write-Host ("stopped: " + ($stopped -join ', '))
    Start-Sleep -Seconds 3
} else {
    Write-Host "was not running"
}

# Confirm the claim instead of trusting it - VRAM that never came back means a hung context,
# which on this box has previously ended in a driver reset.
Write-Host "GPU compute processes after stop:"
Show-GpuApps
& nvidia-smi.exe --query-gpu=name,memory.used,memory.free,power.limit --format=csv,noheader 2>$null |
    ForEach-Object { Write-Host ("  " + $_) }
