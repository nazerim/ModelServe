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

# ---- disk-backed prompt cache -------------------------------------------
# Requires llama.cpp carrying upstream PR 28092 ("server : add --cache-dir for a persistent prompt
# cache", unmerged and unreviewed upstream). The pinned PREBUILT above has no --cache-dir, so
# serve.ps1 probes the binary it is about to exec and records the truth in its summary line rather
# than claiming a configuration that did not boot.
#
# SIZING, measured on this box with the production q4 profile on CUDA: entry = ~448 MiB fixed +
# ~46.1 KiB per cached token, fit from two points (704 and 30,400 tokens). Individual checkpoints
# measured 149.8 MiB and 240-243 MiB; what makes a real full-context entry 6-16 GiB is the
# checkpoint COUNT, which is exactly what -ctxcp/-cms bound below. Projecting the law onto a 137k or
# 196k session is arithmetic, not a measurement. The save is SYNCHRONOUS at ~0.93-0.96 s per GiB and
# is charged to the NEXT request.
$script:MSCacheDir    = Join-Path $script:MSRoot 'cache'   # serve.ps1 appends a full identity leaf
$script:MSCacheMaxMiB = 65536   # 64 GiB per identity dir; ~13 GiB entries means ~4-5 of them

# ---- checkpoint budget ---------------------------------------------------
# An entry is state + checkpoints, and on this profile a checkpoint is ~150-240 MiB for short spans
# and ~1.1 GiB at 196,608 context, so the checkpoint knobs - not prompt length - dominate both disk
# and the synchronous write. Measured on the live q3 server with real pi sessions:
#   upstream defaults 32 / 8192 : entries 9.5 and 15.9 GiB, worst update stall 49.9 s, 31.6 GiB total
#   9 / 20480                  : entries 6.2 and 7.9  GiB, worst update stall 19.4 s, 14.2 GiB total
#   12 / 16384 (current)       : denser coverage than the above at modest size cost; not yet tabulated
#
# WHAT SPACING CANNOT DO, measured: prompt processing creates no checkpoints inside the prompt. A
# 23,731-token synthetic prefill produced exactly one checkpoint, at n_tokens = 42 (149.8 MiB), and
# the next two appeared only after generation (23,221 and 23,471, ~240 MiB each). The spread of
# checkpoints across a real session (19,894 / 43,960 / 67,506 at -cms 20480) is where DECODE walked,
# not a grid - so no -cms value can place a checkpoint under pi's ~19,517-token shared system-prompt
# boundary unless some session has already generated there. A brand-new session therefore pays full
# prefill once (~94k tokens, ~105 s measured); the tier makes every RETURN cheap (77,009 and 102,311
# tokens reused, f_keep = 1.000) and that is the win it actually delivers.
#
# Spacing is also reuse granularity: a hit lands on the last checkpoint before divergence, so the
# tail past the newest checkpoint is re-prefilled (measured 2,577-4,649 tokens at 20,480 spacing).
$script:MSCtxcp = 12       # --ctx-checkpoints / -ctxcp   (llama.cpp default: 32)
$script:MSCms   = 16384    # --checkpoint-min-step / -cms (llama.cpp default: 8192)

# The patched build is the DEFAULT binary (serve.ps1 falls back to the prebuilt only when the
# patched one is absent) because it is the only one with --cache-dir. $script:MSExe stays the pinned
# prebuilt path so install-windows.ps1 keeps describing the release track it downloads.
# Consequence, stated rather than hidden: a default boot is NOT the b11034 build that the ceilings
# and splits below were measured on, so serve.ps1 records which binary ran as BIN=<parent-dir> and
# the harness carries it in its rows.
# Source: https://github.com/nazerim/llama.cpp-disk-cache branch disk-cache-patch (PR 28092 applied
# on 911f6cd, unmodified). Recipe and measurements in win/README.md and that repo's FORK.md.
$script:MSExePatched = Join-Path $script:MSRoot 'llama-cuda28092\llama-server.exe'

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
# that is Tier, below. The server's real surface is exactly three names: q3, q4s, q4 (q3l was
# retired 2026-09-26 — see the profile table: at 229,376 the smaller batch bought no extra room).
#   OvTensor  -ot <pattern>=<device>. Device buffer types on this build are CPU/CUDA0/CUDA1, so a
#             single layer CAN be pinned this way. (--spec-draft-device/-devd cannot: it is only
#             applied to a separate draft model, never to an in-file MTP head.)
#   KvDraft   -ctkd/-ctvd <type> for the MTP draft context's KV. Left unset, llama.cpp gives the
#             draft f16 while the target gets $Kv - the draft then costs ~4 KiB/token on the 3080.
#   Split     -ts. READ THIS BEFORE TUNING IT: with -sm layer, --tensor-split is a LAYER-COUNT
#             fraction, not a GB or byte fraction (src/llama-model.cpp: device(il) =
#             upper_bound(normalize(ts), il/(n_layer+1))). This model has 65 blocks (0..64, the last
#             being the in-file MTP head) so the denominator is 66 and "47,19" puts exactly 47 units
#             on CUDA0: blocks 0..46, the MTP block by OvTensor, and the output tensor counted as
#             unit 65. Decimal forms are just the same count dressed up - '17.4,7.7' normalises to
#             0.6932 which is 45.75 of 66, i.e. it was booting 46/20 all along.
# Pin and draft-KV are profile fields too, for the same reason the batch is: they were decided by
# a measurement at a specific ceiling, and a profile that owns a ceiling must own what bought it.
#   OvTensor  -ot <pattern>=<device>. Device buffer types on this build are CPU/CUDA0/CUDA1, so a
#             single layer CAN be pinned this way. (--spec-draft-device/-devd cannot: it is only
#             applied to a separate draft model, never to an in-file MTP head.)
#   KvDraft   -ctkd/-ctvd <type> for the MTP draft context's KV. Left unset, llama.cpp gives the
#             draft f16 while the target gets $Kv - the draft then costs ~4 KiB/token on the 3080.
# CEIL/SPLIT are CARRIED OVER FROM WSL MEASUREMENTS unless marked native. Free VRAM read natively
# (15,037 + 9,095 MiB idle) is within ~200 MiB of the WSL reading, so they land close.
$script:MSProfiles = [ordered]@{
    # Ceil = largest context still leaving >=~400 MiB on the constrained card, AT THE BATCH AND
    # PIN IN THE SAME ROW. Those are part of the measurement, not preferences.
    #
    # q3 IS THE PRODUCTION CONFIG AND THE DEFAULT BOOT (serve.ps1 $Q = 'q3') since 2026-09-26.
    # Ceiling raised 196,608 -> 229,376 at split 47,19, certified by an eight-size ladder in 4,096
    # steps (every size booted, nothing failed) plus a worst-case load sample at the top size.
    # Free MiB after boot, 3080 / 5070 Ti:
    #   196,608 915/1,375   208,896 659/1,021   212,992 575/911   217,088 487/801
    #   221,184 403/689     225,280 319/579     229,376 235/469
    # Slope is linear at -84 MiB (3080) and -111 MiB (5070 Ti) per 4,096 tokens, so the wall is
    # ~237,568 on the 3080 - and past 229,376 that wall is the DESKTOP, not the config: a boot of
    # 241,664 succeeded earlier only because the display card happened to be ~300 MiB lighter.
    # Certified top size under a novel 24,860-token cold prefill: worst 203 / 469, pp 1,178.90 tok/s,
    # decode 51.39 tok/s. 203 clears the 240 abort line, not the 400 line; -Tier large (163,840) and
    # -Ctx are the escape hatch on a heavy-desktop day.
    # History: split moved 17.4,7.7 -> 47,19 on 2026-09-26 (one GDN block, -170 MiB on the 3080) and
    # this row measured worst-case 1,057-1,077 MiB at 196,608 / 1024/128 on 2026-09-24, cold pp
    # 1,105 tok/s; that night's 1,024/256 run at the same context measured 187-199 MiB (UNSAFE).
    q3  = @{ File = 'Qwen3.8-27B-UD-Q3_K_XL.gguf'; Ceil = 229376; Split = '47,19'; Alias = 'qwen3.8-27b';    Batch = 1024; Ubatch = 128; OvTensor = 'blk.64.*=CUDA0'; KvDraft = 'q8_0' }
    # q3l WAS RETIRED on 2026-09-26. It existed because 225,280 was believed to need the smaller
    # prompt batch. Measured at the SAME 229,376 on the 47,19 split, q3 at 1024/128 and q3l at
    # 512/128 leave the same margin - worst-case 203 MiB on the 3080, 465-469 on the display card -
    # so the batch was not what bought the room; ubatch was. Dropping ubatch 256 -> 128 is worth
    # about 130 MiB; dropping b 1024 -> 512 is worth about nothing. q3 is therefore the single q3
    # row: same GGUF, same ceiling, faster prompt processing, and one fewer identity to certify.
    # NOT proven on pp: those two readings used different prompt lengths (24,860 vs 18,867 tokens),
    # so q3's ~4% edge is a reading, not a rule, until an A/B at one ctx with one prompt is run
    # (two boots). q3l's own certifications are kept below as dated evidence of what was measured.
    # `start.cmd -P q3l` now fails loudly with the valid profile list instead of booting nothing.
    #   NATIVE-MEASURED 2026-09-19 at 517 MiB worst-case, pp 1,020-1,032, decode 49.0-49.4, MTP len
    #   2.19; 212,992 at the default batch measured 275 MiB = MARGINAL, which is why 512/128 rode
    #   along on that row. RE-MEASURED 2026-09-24 with pin + q8_0: 463/462 MiB both cards, 13 boots,
    #   no driver events; decode 50.1 prose / 52.7 json, MTP len 2.33, 7.46 ms/draft. Without the
    #   pin that row was UNSAFE (67-85 MiB) and with the pin but f16 draft KV it OOMed in
    #   sched_reserve - the pair is what made 225,280 bootable, not either half. Then 2026-09-26 at
    #   47,19: 225,280 worst 305/331, 229,376 worst 203/476, 233,472 worst 115/366.
    # RE-CERTIFIED 2026-09-26. Both rows used to say 17,8 with no pin and no draft-KV type; measured
    # today, that combination boots but sits in the band where this box has reset the driver: q4s at
    # its old 155,648 came up with **33 MiB** worst-case on the 3080. Adding the pair (pin the MTP
    # block to CUDA0 + quantise the draft KV) is worth ~846 MiB there, which is the whole story of
    # this section - see ../HANDOFF-2026-09-26.md section 4.
    #   q4s as-shipped 17,8 @155,648  -> worst 33 / 1,500   (pp 1,274, decode 44.2)
    #   q4s 47,19 + pair  @155,648    -> worst 879 / 1,005  (pp 1,139, decode 46.9)
    # The split is per-file, not per-box: q4s (14.30 GiB) wants MORE on CUDA0 (47,19) while Q4_K_XL
    # (16.35 GiB) runs the display card dry first and wants one unit back (45,21).
    # Batch deliberately left at 1024/256 so these rows stay comparable with the 2026-09-19 figures;
    # ubatch 256 -> 128 is worth ~130 MiB per card and is an open A/B.
    # Batch moved to 1024/128 on 2026-09-26 (clean A/B, same ctx, same prompt, both cold): halving
    # ubatch is worth ~110-120 MiB per card. Spent on context, not banked:
    #   q4s 172,032 @128 worst 640 -> 176,128 worst 525 -> 180,224 worst 421  (all >=400, SAFE)
    #   184,320 predicts ~343/424 = MARGINAL, so 180,224 is the largest size satisfying the 400 rule.
    q4s = @{ File = 'Qwen3.8-27B-UD-Q4_K_S.gguf';  Ceil = 180224; Split = '47,19';    Alias = 'qwen3.8-27b-4s'; Batch = 1024; Ubatch = 128; OvTensor = 'blk.64.*=CUDA0'; KvDraft = 'q8_0' }
    #   ladder @47,19+pair (post-boot free, display/3080): 163,840 783/731 - 172,032 559/555
    #   (worst under load **531**, SAFE) - 180,224 337/383 (worst **333**, MARGINAL) - 184,320
    #   289/293 - 188,416 289/207. So 172,032 is the largest size that satisfies the >=400 rule
    #   above with a load sample to prove it; 180,224 is available if the 240 line is the one you
    #   want to live on.
    #   q4 ladder @45,21+pair (post-boot): 126,976 849/537 - 131,072 739/451 - 135,168 627/361
    #   (MARGINAL on the 3080) - decode 38.4-39.1 throughout. 131,072 written here; 139,264 is
    #   predicted ~250 on the 3080 and was deliberately NOT tested.
    #   q4 at 1024/128: 135,168 worst **429 SAFE** (written); 139,264 worst **345 MARGINAL** — above
    #   the 240 abort line, below the 400 rule, so it is available as `-Ctx 139264` but not a ceiling.
    #   46,20 instead of 45,21 is a wash at these sizes (min margin 486 vs 461), so this row keeps
    #   45,21; the thing that matters for q4 is NOT copying q3's 47,19 (that reads ~266 on CUDA0).
    q4  = @{ File = 'Qwen3.8-27B-UD-Q4_K_XL.gguf'; Ceil = 135168; Split = '45,21';    Alias = 'qwen3.8-27b-4xl'; Batch = 1024; Ubatch = 128; OvTensor = 'blk.64.*=CUDA0'; KvDraft = 'q8_0' }
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
# If this ever flips after a driver update, a "47,19" split silently puts 47 of the 66 layer units -
# most of a 12 GiB model - into a 10 GiB card, so serve.ps1 asserts it before launching.
$script:MSCuda0MustContain = '5070 Ti'

# Which adapter -Bind lan MUST use, as an InterfaceAlias prefix ('Ethernet', 'Wi-Fi', 'Realtek'...).
# Empty = auto-detect, and refuse when more than one adapter is a candidate. This box runs a PVC
# VPN adapter, and a VPN that raises its own default route is indistinguishable from the LAN in the
# routing table — so on a VPN day an unpinned auto-detect refuses to boot rather than guess.
# Set this once and the guess becomes a fact: same idea as MSCuda0MustContain above, which pins the
# CUDA device ORDER for exactly the same reason (a wrong silent pick looks healthy and serves nobody).
$script:MSLanAdapterPin = ''

# ---- helpers --------------------------------------------------------------

# Rotate the two server logs before a new boot, keeping $script:MSLogKeep generations.
# start.ps1 hands the child's streams to Start-Process -RedirectStandard*, which TRUNCATES on every
# launch, so before this there was exactly ONE boot of evidence alive at any time - and the pp and
# decode figures the READMEs quote come from "prompt eval time" lines in server.err.log, which is
# precisely the data that vanished the moment you wanted to compare two configurations.
# Renaming fails if the previous instance still holds the handle, and a logging nicety must never
# veto a boot, so each rename is individually guarded and a failure is reported rather than swallowed.
$script:MSLogKeep = if ($env:MS_LOG_KEEP) { [int]$env:MS_LOG_KEEP } else { 10 }
function Invoke-MSLogRotate {
    param([string]$Path, [int]$Keep = $script:MSLogKeep)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    if ($Keep -lt 1) { return '' }
    try {
        $oldest = "$Path.$Keep"
        if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force -ErrorAction Stop }
        for ($i = $Keep - 1; $i -ge 1; $i--) {
            $src = "$Path.$i"; $dst = "$Path." + ($i + 1)
            if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop
        return "$Path.1"
    } catch {
        return ('FAILED: ' + $_.Exception.Message)
    }
}

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

function Get-MSLanAddress {
    <#
      The IPv4 a client on the physical LAN reaches this box on — what -Bind lan binds and what a
      LAN firewall rule must open. Where Get-MSWslAddress can match an adapter by NAME (the Hyper-V
      switch is always 'vEthernet (WSL...'), the LAN adapter has no stable name on this box, so it
      is found by ROUTE: an adapter that carries a default route, holds a non-APIPA IPv4, and is
      up. A stale route on a disconnected adapter would otherwise be enough to win the election.

      Returns $null when there is no candidate at all, otherwise:
        .Ambiguous   $true when more than one adapter survived the filter and no pin chose one
        .Candidates  every survivor (alias / IP / subnet / metric) — printed verbatim on refusal
        .IP .Prefix .Alias .Subnet   present ONLY when .Ambiguous is $false
      Ambiguity is reported, never resolved by ranking: the lowest metric is a routing-table
      preference, not evidence about which network the operator means, and both answers advertise
      a different baseUrl.
    #>
    # Internal Hyper-V / loopback faces. A VPN adapter is deliberately NOT listed: see above.
    $skip = '^(Loopback|Default Switch|vEthernet \((Hyper-V|nat|Default|WSL)|' +
            'Loopback Pseudo-Interface)'
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object -Property @{Expression='RouteMetric'; Ascending=$true},
                  @{Expression='InterfaceMetric'; Ascending=$true})
    $cands = @(); $seen = @{}
    foreach ($r in $routes) {
        $ad = Get-NetAdapter -InterfaceIndex $r.InterfaceIndex -ErrorAction SilentlyContinue
        if ($ad -and ("" + $ad.Status) -ne 'Up') { continue }
        $ips = @(Get-NetIPAddress -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notmatch $skip })
        foreach ($n in $ips) {
            if ($seen.ContainsKey($n.IPAddress)) { continue }
            $seen[$n.IPAddress] = 1
            $cands += [pscustomobject]@{
                IP     = $n.IPAddress
                Prefix = [int]$n.PrefixLength
                Alias  = $n.InterfaceAlias
                Subnet = (Get-MSNetworkPrefix -IP $n.IPAddress -Prefix ([int]$n.PrefixLength))
                Metric = [int]$r.InterfaceMetric
            }
        }
    }
    if ($cands.Count -eq 0) { return $null }

    if ($script:MSLanAdapterPin) {
        $all = $cands
        $cands = @($cands | Where-Object { $_.Alias -like ($script:MSLanAdapterPin + '*') })
        if ($cands.Count -eq 0) {
            # A pin that matches nothing is a stale config, not an ambiguity: say it named the pin.
            return [pscustomobject]@{ Ambiguous = $true; Pin = $script:MSLanAdapterPin; Candidates = $all }
        }
    }
    if ($cands.Count -gt 1) {
        return [pscustomobject]@{ Ambiguous = $true; Candidates = $cands }
    }
    $c = $cands[0]
    return [pscustomobject]@{ Ambiguous = $false; Candidates = @($c);
                              IP = $c.IP; Prefix = $c.Prefix; Alias = $c.Alias; Subnet = $c.Subnet }
}

function Resolve-MSBind {
    <#
      ONE place that turns a -Bind keyword into an address, so serve.ps1's key gate, start.ps1's
      readiness poll, the advertised baseUrl and the firewall hint cannot drift apart. Before this
      existed, start.ps1 and serve.ps1 each carried their own copy of the mapping, and -Bind
      0.0.0.0 made start.ps1 poll and advertise a WILDCARD (http://0.0.0.0:8000) — which is not an
      address anyone can put in a client config.

        wsl / loopback / 127.x / a literal address   as before
        lan    the single physical-LAN IPv4 (Get-MSLanAddress), refusing if it cannot name one
        all    0.0.0.0: every face at once, so LAN and WSL clients are both served

      Returns $null after printing the reason, or an object:
        .BindHost     goes to --host
        .PollHost     what health/models get requested on (differs from BindHost only for 'all')
        .Faces        pre-formatted 'label : baseUrl http://...' lines for the ready banner
        .Hint         the one-shot elevated firewall command for LAN clients, '' when not needed
    #>
    param([string]$Bind = 'wsl', [int]$Port = 8000)
    $b = if ($Bind) { ("" + $Bind).Trim().ToLowerInvariant() } else { 'wsl' }

    function Face($label, $ip, $p) { ('{0,-10}: baseUrl http://{1}:{2}/v1' -f $label, $ip, $p) }
    function Refuse($why, $cands, $lanOnly) {
        Write-Host $why -ForegroundColor Red
        if ($cands) {
            foreach ($c in $cands) {
                Write-Host ('  candidate  {0,-28} {1}/{2}  metric {3}' -f $c.Alias, $c.IP, $c.Prefix, $c.Metric)
            }
        }
        if ($lanOnly) {
            Write-Host '  or name the adapter once:  $MSLanAdapterPin in win\config.ps1' -ForegroundColor Yellow
            Write-Host '  or bind it explicitly:     -Bind <ip>  ·  or serve every face: -Bind all' -ForegroundColor Yellow
        }
        return $null
    }

    switch -Regex ($b) {
        '^loopback$|^127' {
            return [pscustomobject]@{ BindHost = '127.0.0.1'; PollHost = '127.0.0.1'; Keyword = 'loopback'
                                      Faces = @(Face 'this box' '127.0.0.1' $Port); Hint = '' }
        }
        '^all$|^any$|^0\.0\.0\.0$' {
            # The bind itself needs no adapter knowledge — 0.0.0.0 IS every adapter — so an
            # unresolved LAN address is a note about the hint and the banner, never a refusal.
            $lan = Get-MSLanAddress
            $faces = @()
            $hint  = ''
            if ($lan -and -not $lan.Ambiguous) {
                $faces += Face 'from LAN' $lan.IP $Port
                $hint  = ("New-NetFirewallRule -DisplayName 'ModelServe llama-server (LAN)' " +
                          "-Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port " +
                          "-RemoteAddress {0} -Profile Any" -f $lan.Subnet)
            } elseif ($lan) {
                Write-Host '  note: LAN adapter ambiguous, so the LAN baseUrl and the firewall hint' -ForegroundColor Yellow
                Write-Host '        could not name one — the wildcard bind still covers it:' -ForegroundColor Yellow
                foreach ($c in $lan.Candidates) {
                    Write-Host ('        {0,-28} {1}/{2}' -f $c.Alias, $c.IP, $c.Prefix) -ForegroundColor Yellow
                }
                $hint = "... -LocalPort $Port -RemoteAddress <your LAN subnet> -Profile Any"
            } else {
                Write-Host '  note: no default-route IPv4 adapter found — is the LAN cable up?' -ForegroundColor Yellow
                $hint = "... -LocalPort $Port -RemoteAddress <your LAN subnet> -Profile Any"
            }
            $wsl = Get-MSWslAddress
            if ($wsl) { $faces += Face 'from WSL' $wsl.IP $Port }
            $faces += Face 'this box' '127.0.0.1' $Port
            [Console]::Error.WriteLine('bind = 0.0.0.0  (every interface: LAN + WSL + local)')
            return [pscustomobject]@{ BindHost = '0.0.0.0'; PollHost = '127.0.0.1'; Keyword = 'all'
                                      Faces = $faces; Hint = $hint }
        }
        '^lan$|^ethernet$' {
            $lan = Get-MSLanAddress
            if (-not $lan) {
                return Refuse ('refusing -Bind lan: no default-route IPv4 adapter found - is the ' +
                               'LAN connected? (-Bind all serves every face without choosing)') $null $true
            }
            if ($lan.Ambiguous) {
                if ($lan.Pin) {
                    $msg = "refusing -Bind lan: the pinned adapter '$($lan.Pin)' is not up."
                } else {
                    $msg = 'refusing -Bind lan: more than one adapter carries a default route, so '
                    $msg += 'the LAN address is not uniquely determined. This is the PVC VPN adapter '
                    $msg += 'raising a route — do not guess which one the operator means.'
                }
                return Refuse $msg $lan.Candidates $true
            }
            # A LAN-only bind is UNMEASURED for WSL clients on this box: gotcha 3 in win\README.md
            # only ever proved WSL-origin traffic reaching the WSL adapter address, and whether
            # winnat presents a LAN-destined packet from the WSL /20 decides if the scoped rule
            # matches. Say so instead of implying 'both work'.
            [Console]::Error.WriteLine(("bind = {0}  ({1}, subnet {2})" -f $lan.IP, $lan.Alias, $lan.Subnet))
            return [pscustomobject]@{ BindHost = $lan.IP; PollHost = $lan.IP; Keyword = 'lan'
                Faces = @((Face 'from LAN' $lan.IP $Port),
                          'LAN-only bind: WSL reachability is unmeasured here - use -Bind all ' +
                          'if clients inside WSL must work too')
                Hint  = ("New-NetFirewallRule -DisplayName 'ModelServe llama-server (LAN)' " +
                         "-Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port " +
                         "-RemoteAddress {0} -Profile Any" -f $lan.Subnet) }
        }
        '^wsl$' {
            $addr = Get-MSWslAddress
            if (-not $addr) { return Refuse 'no vEthernet (WSL) adapter found - is WSL running?' $null $false }
            [Console]::Error.WriteLine(("bind = {0}  ({1}, subnet {2})" -f $addr.IP, $addr.Alias, $addr.Subnet))
            return [pscustomobject]@{ BindHost = $addr.IP; PollHost = $addr.IP; Keyword = 'wsl'
                                      Faces = @(Face 'from WSL' $addr.IP $Port); Hint = '' }
        }
        default {
            # A literal address: the caller already knows what they meant. Poll it, advertise it.
            return [pscustomobject]@{ BindHost = $b; PollHost = $b; Keyword = 'literal'
                                      Faces = @(Face 'from bind' $b $Port); Hint = '' }
        }
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

# One shared probe, so serve.ps1's gate and check.ps1's report cannot drift apart.
function Test-MSFlagSupport {
    param([string]$Exe, [string]$Flag)
    if (-not (Test-Path $Exe)) { return 'exe absent' }
    $t = (Get-MSNative -Exe $Exe -Arguments @('--help')) -join "`n"
    if ($t -match ('(?m)^\s*' + [regex]::Escape($Flag))) { return 'supported' }
    return ('NO (no {0} in --help)' -f $Flag)
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
