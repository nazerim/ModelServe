<#
  config.ps1  -  shared defaults for the native-Windows ModelServe scripts.

  Dot-sourced by serve.ps1, start.ps1, stop.ps1, check.ps1 and install-windows.ps1.
  This is the Windows twin of ../config.sh; the quant/tier table mirrors ../serve.sh so
  "Q=q3 TIER=max" means the same thing on both sides.

  WHY A SEPARATE TREE: the WSL server reads models from ext4 (~/.models) and cannot see
  them any other way; the native server needs them on NTFS. /mnt/* is 9P at ~127 MB/s, so
  a Windows-side path is not interchangeable with a WSL-side one. See win/README.md.
#>

$ErrorActionPreference = 'Stop'

# Root lives on NTFS by design. Overridable for testing without touching C:.
if ($env:MODEL_SERVE_ROOT) { $script:MSRoot = $env:MODEL_SERVE_ROOT } else { $script:MSRoot = 'C:\ModelServe' }
$script:MSBin     = Join-Path $script:MSRoot 'llama'
$script:MSModels  = Join-Path $script:MSRoot 'models'
$script:MSLogs    = Join-Path $script:MSRoot 'logs'
$script:MSPidFile = Join-Path $script:MSRoot 'server.pid'
$script:MSExe     = Join-Path $script:MSBin 'llama-server.exe'

# Build this whole track is pinned to. Same commit as the WSL tarball (verified: both
# report build 11034 / commit dc85f89c7), so every flag and sampler default matches.
$script:MSBuild = 'b11034'
$script:MSCuda  = '13.4'   # Windows ships CUDA 13.4 where Ubuntu ships 13.3; same major

# Pinned release assets. The windows-cuda zip is a COMPLETE toolset: the release workflow
# injects the windows-cpu binaries (llama-server.exe + CPU backends) into every backend zip,
# so there is no separate cpu download. Both zips are flat (no folder prefix inside).
$script:MSAssets = @(
    'llama-b11034-bin-win-cuda-13.4-x64.zip'
    'cudart-llama-bin-win-cuda-13.4-x64.zip'
)

# ---- profiles -------------------------------------------------------------
# A PROFILE is a bootable configuration: which GGUF, what context, what prompt batch, the ceiling
# that combination was actually measured at, and the alias it advertises. It is not a size knob -
# that is Tier, below. The server's real surface is exactly four names: q3, q3l, q4s, q4.
# CEIL/SPLIT are CARRIED OVER FROM WSL MEASUREMENTS unless marked native. Free VRAM read natively
# (15,037 + 9,095 MiB idle) is within ~200 MiB of the WSL reading, so they land close - but q3l is
# native-only: it exists because halving the prompt buffer freed ~1.2 GiB, and that has not been
# re-measured on the ext4 side.
$script:MSProfiles = [ordered]@{
    # Ceil = largest context still leaving >=~400 MiB on the constrained card, AT THE BATCH IN THE
    # SAME ROW. The batch is part of the measurement, not a preference.
    q3  = @{ File = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'; Ceil = 196608; Split = '17.4,7.7'; Alias = 'qwen3.8-27b';    Batch = 1024; Ubatch = 256 }
    # NATIVE-MEASURED 2026-09-19: 517 MiB worst-case free under load, pp 1,020-1,032 tok/s (-20%
    # vs q3), decode 49.0-49.4, MTP acceptance 0.595 / len 2.19, 15 s boots. 212,992 at the default
    # batch measured 275 MiB, i.e. MARGINAL - which is why 512/128 rides along here.
    q3l = @{ File = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'; Ceil = 225280; Split = '17.4,7.7'; Alias = 'qwen3.8-27b-l';  Batch = 512;  Ubatch = 128 }
    q4s = @{ File = 'Qwen3.8-27B-UD-Q4_K_S.gguf';  Ceil = 155648; Split = '17,8';     Alias = 'qwen3.8-27b-4s'; Batch = 1024; Ubatch = 256 }
    q4  = @{ File = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'; Ceil = 122880; Split = '17,8';     Alias = 'qwen3.8-27b-4xl'; Batch = 1024; Ubatch = 256 }
}

# Size presets WITHIN a profile. max = the profile's own measured ceiling.
$script:MSTiers = [ordered]@{
    small  = 32768
    medium = 98304
    large  = 163840
    max    = 0          # 0 = the profile's ceiling
}

# The card whose share is FIRST in --tensor-split, on both WSL and native Windows.
# Measured natively: --list-devices -> CUDA0 = 5070 Ti, CUDA1 = 3080 (same inversion as WSL).
# If this ever flips after a driver update, a "17.4,7.7" split silently puts 17 GiB of
# weights into a 10 GiB card - so serve.ps1 asserts it before launching.
$script:MSCuda0MustContain = '5070 Ti'

# ---- helpers --------------------------------------------------------------

function Get-MSWslAddress {
    <#
      The Windows-side IPv4 of the Hyper-V switch that WSL NAT sits behind - i.e. the address
      WSL sees as its default gateway, and the one a native server must bind to for WSL to
      reach it. It is DYNAMIC: it can move after a reboot or a WSL update, so nobody should
      hardcode 172.25.240.1 into a config file. Returns $null when WSL has no adapter up.
    #>
    $nics = Get-NetIPAddress -InterfaceAlias 'vEthernet (WSL*' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Sort-Object -Property InterfaceMetric
    if (-not $nics) { return $null }
    $n = $nics | Select-Object -First 1
    return [pscustomobject]@{
        IP      = $n.IPAddress
        Prefix  = [int]$n.PrefixLength
        Alias   = $n.InterfaceAlias
        Subnet  = (Get-MSNetworkPrefix -IP $n.IPAddress -Prefix ([int]$n.PrefixLength))
    }
}

function Get-MSNetworkPrefix {
    param([string]$IP, [int]$Prefix)
    # Zero the host bits per octet; no uint32 promotion traps on Windows PowerShell 5.1.
    $b = ([ipaddress]$IP).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $keep = [Math]::Max(0, [Math]::Min(8, $Prefix - ($i * 8)))
        if ($keep -eq 8)        { $mask = 255 }
        elseif ($keep -eq 0)    { $mask = 0 }
        else                    { $mask = 256 - (1 -shl (8 - $keep)) }
        $b[$i] = [byte]([byte]$b[$i] -band [byte]$mask)
    }
    return ('{0}.{1}.{2}.{3}/{4}' -f $b[0], $b[1], $b[2], $b[3], $Prefix)
}

function Resolve-MSApiKey {
    <#
      The key, from wherever it actually persists. Never returned to the console by the
      callers, and never placed in argv: `--api-key <secret>` is readable by any process
      that can enumerate the command line, while llama.cpp also accepts LLAMA_API_KEY
      (common/arg.cpp sets that env var for the option), which only the child inherits.

      Order: this process, then User, then Machine. A key exported in one terminal is NOT
      visible to a Task Scheduler launch, so only the User/Machine scopes survive a reboot.
    #>
    foreach ($scope in @('Process', 'User', 'Machine')) {
        $v = [Environment]::GetEnvironmentVariable('LLAMA_API_KEY', $scope)
        if ($v) { return [pscustomobject]@{ Value = $v; Scope = $scope } }
    }
    return $null
}

function Get-MSNative {
    <#
      Run a native exe and return its output as plain strings, stdout AND stderr.

      Why this exists: llama.cpp writes routine information (--version, ggml backend loading,
      CUDA init) to STDERR. config.ps1 sets ErrorActionPreference='Stop', and in Windows
      PowerShell 5.1 a native command whose stderr is redirected with 2>&1 turns each stderr
      line into an ErrorRecord - which under 'Stop' ABORTS the script. So `--list-devices 2>&1`
      looked fine in an interactive test and would have killed every real launch. This lowers
      the preference for the duration of the call and flattens the records to their messages.
    #>
    param([string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $script:ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        return @($out | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message }
            else { [string]$_ }
        })
    } finally { $script:ErrorActionPreference = $prev }
}

function Get-MSHealth {
    param([string]$Host_ = '127.0.0.1', [int]$Port = 8000, [int]$TimeoutSec = 10)
    # curl.exe (in System32 since Win10 1803) rather than Invoke-WebRequest: IWR on PS 5.1 adds
    # proxy auto-detection and its -TimeoutSec does not bound the TCP connect phase, so a poll
    # iteration against a still-loading server could stall far past the intended budget. curl
    # honours -m exactly, which is what makes start.ps1's deadline trustworthy.
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        $out = & curl.exe -s -m "$TimeoutSec" ('http://{0}:{1}/health' -f $Host_, $Port) 2>$null
        if ($out) { return ($out -join '') }
        return $null
    }
    try {
        return (Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSec `
                -Uri ('http://{0}:{1}/health' -f $Host_, $Port)).Content
    } catch { return $null }
}
