<#
  stop.ps1  -  stop the native server and show that VRAM actually came back.

  Run it through the wrapper (AllSigned refuses a bare .\stop.ps1):
      stop.cmd                # stop the PID in server.pid (falls back to matching our own install)
      stop.cmd -VerifyOnly    # change nothing, just report what holds GPU memory
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
    $raw = (Get-Content $script:MSPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    $pid_ = 0
    # A pid file can hold anything: a stray text line, or - after a reboot plus PID reuse - the
    # number of an unrelated process. Never let a cast failure or a reused number become a
    # Stop-Process -Force on somebody else's app.
    if (-not [int]::TryParse(("$raw").Trim(), [ref]$pid_)) { $pid_ = 0 }
    $holder = if ($pid_) { Get-CimInstance Win32_Process -Filter ("ProcessId=$pid_") -ErrorAction SilentlyContinue } else { $null }
    if ($holder) {
        # Identity, not just liveness: the recorded PID is the LAUNCHER (a powershell running
        # start.ps1/serve.ps1 from this folder). If it is now something else, the number was
        # reused - clean the file and move on rather than killing the tenant.
        $isOurs = ($holder.CommandLine -like '*serve.ps1*' -or $holder.CommandLine -like '*start.ps1*') -and
                  ($holder.ExecutablePath -like '*powershell.exe' -or $holder.ExecutablePath -like ($script:MSBin + '*'))
        if ($isOurs) {
            # Kill the whole tree: start.ps1 spawns powershell.exe -> serve.ps1 -> llama-server.exe,
            # and stopping only the launcher would leave the server holding 17 GiB of VRAM.
            $kids = Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $pid_) -ErrorAction SilentlyContinue
            foreach ($k in $kids) {
                Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue
                $stopped += ('child ' + $k.ProcessId + ' (' + $k.Name + ')')
            }
            Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
            $stopped += ('pid ' + $pid_)
        } else {
            Write-Host ("pid file points at PID $pid_ which is '$($holder.Name)' - not our launcher (reused number?). Leaving it alone.") -ForegroundColor Yellow
            $stalePid = $true
        }
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
} elseif ($stalePid) {
    Write-Host "nothing killed (stale pid file only)"
} else {
    Write-Host "was not running"
}

# Confirm the claim instead of asserting it. This is the point of the whole script: a caller that
# cannot tell a failed stop from a successful one will happily measure the wrong server, and every
# number in the resulting row belongs to a boot that is still running.
$left = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like ($script:MSBin + '\*') }

# VRAM that never came back means a hung context, which on this box has ended in a driver reset.
Write-Host "GPU compute processes after stop:"
Show-GpuApps
& nvidia-smi.exe --query-gpu=name,memory.used,memory.free,power.limit --format=csv,noheader 2>$null |
    ForEach-Object { Write-Host ("  " + $_) }

if ($left) {
    Write-Host "STOP INCOMPLETE - these are still running from $script:MSBin :" -ForegroundColor Red
    $left | ForEach-Object { Write-Host ("    pid {0} {1}" -f $_.ProcessId, $_.Name) -ForegroundColor Red }
    Write-Host "  likely an elevated server vs a non-elevated stop, or access denied. Do not" -ForegroundColor Red
    Write-Host "  measure on top of it: stop from an elevated prompt, then re-run." -ForegroundColor Red
    exit 1
}
exit 0
