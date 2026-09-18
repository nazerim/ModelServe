<#
  Register-NvidiaPowerTask.ps1  -  make the power limits re-apply on every boot.

  NVIDIA has no persistence flag for -pl: the limit is volatile and resets to default when the
  driver loads. Power limits also cannot be set from inside WSL (verified: nvidia-smi answers
  "Insufficient Permissions", and sudo is interactive-only here), so this uses Task Scheduler,
  running as SYSTEM at startup - which needs no UAC prompt and no user login.

  Usage, ONE TIME. Prefer the .cmd wrapper - this box is AllSigned at LocalMachine scope,
  so a bare .\script.ps1 is refused, while cmd.exe is not subject to ExecutionPolicy:
      C:\ProgramData\ModelServe\win\install-power-limits.cmd
      ...\install-power-limits.cmd -Status | -Remove | -Watts3080 170 -Watts5070Ti 260

  Equivalent without the wrapper (Process-scope Bypass outranks LocalMachine):
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Register-NvidiaPowerTask.ps1

  Then confirm after your next reboot:
      nvidia-smi --query-gpu=name,power.limit --format=csv
#>
[CmdletBinding()]
param(
    [int]$Watts3080   = 150,
    [int]$Watts5070Ti = 250,
    [string]$TaskName = 'ModelServe NVIDIA Power Limits',
    [switch]$Remove,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$setter = Join-Path $here 'Set-NvidiaPowerLimits.ps1'

if (-not (Test-Path $setter)) { Write-Error "missing $setter - keep both scripts together"; exit 1 }

# A SYSTEM task that starts at boot must not depend on WSL being up. If these scripts are run
# straight from \\wsl.localhost\..., the task would have to reach into a distro that may not be
# started yet, and it can also die when the distro path moves. Copy them to a Windows-local
# folder first and register from there.
if ($here -like '\\*') {
    $dest = Join-Path $env:ProgramData 'ModelServe\win'
    Write-Warning "running from a network/WSL path; copying scripts to $dest and re-run the registration THERE."
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $here 'Set-NvidiaPowerLimits.ps1'), (Join-Path $here 'Register-NvidiaPowerTask.ps1') $dest -Force
    "copied to: $dest"
    "now run:   cd $dest; .\Register-NvidiaPowerTask.ps1"
    return
}

if ($Remove) {
    $ErrorActionPreference = 'Continue'
    $existing = (& schtasks.exe /query /tn $TaskName 2>&1) | Out-String
    $ErrorActionPreference = 'Stop'
    if ($existing -notmatch 'cannot find the file specified') {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        "unregistered: $TaskName"
    } else { "not registered: $TaskName" }
    return
}

if ($Status) {
    # Get-ScheduledTask with -ErrorAction SilentlyContinue is NOT a registration test: a task
    # created as SYSTEM is invisible to a non-elevated caller, and that access error was being
    # reported as "not registered" (a confident false negative). schtasks' error text does
    # distinguish the two cases, so use it: absent -> "cannot find the file specified".
    # Native stderr + $ErrorActionPreference='Stop' makes PowerShell THROW on any schtasks
    # error output (so both "absent" and "access denied" aborted the script instead of
    # being classified). Relax the preference around the call and take the text as data.
    $ErrorActionPreference = 'Continue'
    $q = (& schtasks.exe /query /tn $TaskName /fo LIST 2>&1) | Out-String
    $qcode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($q -match 'cannot find the file specified') {
        "not registered - run without -Status to install it"
        & nvidia-smi --query-gpu=index,name,power.limit,power.default_limit --format=csv
        exit 0
    }
    if ($q -match 'Access is denied') {
        "registered: YES (but this account cannot read a SYSTEM task without elevation)"
        "  run this from an ELEVATED prompt for Last Run Time / Next Run Time / result"
        & nvidia-smi --query-gpu=index,name,power.limit,power.default_limit --format=csv
        exit 0
    }
    if ($qcode -eq 0) {
        "registered: YES"
        ($q -split "`n" | Where-Object { $_ -match 'Task Name|Next Run Time|Status|Logon Mode|Last Run Time|Last Result' }) -join "`n"
        & nvidia-smi --query-gpu=index,name,power.limit,power.default_limit --format=csv
        exit 0
    }
    "could not determine state: $q"; exit 1
}

if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "run this from an ELEVATED PowerShell (it registers a SYSTEM task)"
    exit 1
}

# SYSTEM at startup, with a short delay so the NVIDIA stack is up, plus retry-on-failure so a
# flaky boot cannot leave the box running uncapped without us noticing.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Watts3080 {1} -Watts5070Ti {2}' -f $setter, $Watts3080, $Watts5070Ti
)
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Description `
    "Applies NVIDIA power limits ($Watts3080 W on the RTX 3080, $Watts5070Ti W on the RTX 5070 Ti) at boot; -pl is volatile and cannot be set from WSL." | Out-Null

"registered: $TaskName"
"  3080 -> ${Watts3080}W   5070 Ti -> ${Watts5070Ti}W"
"starting it now to verify (no reboot needed)..."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 12
& nvidia-smi --query-gpu=index,name,power.limit,power.default_limit --format=csv
"`$log: $env:ProgramData\ModelServe\power-limits.log"
