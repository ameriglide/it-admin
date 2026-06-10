# install-tailscale-watchdog.ps1
# Server-only installer: provision/reuse a Better Stack heartbeat, write config,
# copy the watchdog, register the task, and (sage-iai/sage-server) install
# Vector host_metrics. Run once per server. ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string[]]$Anchors,
    [string]$BetterStackApiToken = $env:BETTERSTACK_UPTIME_TOKEN,
    [int]$PolicyId = 114897,
    [string]$VectorSourceToken,
    [switch]$SkipVector
)
$ErrorActionPreference = 'Stop'
$Script:Revision = "a2d2043"

if (-not $BetterStackApiToken) { throw "BetterStack API token required (-BetterStackApiToken or BETTERSTACK_UPTIME_TOKEN)." }

$BaseDir = Join-Path $env:ProgramData 'ag-admin'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

# When run standalone (irm | run from $env:TEMP), only this script is present in
# $PSScriptRoot; fetch the sibling scripts it needs from the public repo. When
# run from a cloned scripts/ dir, the local copies are used as-is.
$RawBase = 'https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts'
function Get-RepoScript {
    param([Parameter(Mandatory)][string]$Name)
    $local = Join-Path $PSScriptRoot $Name
    if (Test-Path $local) { return $local }
    $dest = Join-Path $env:TEMP $Name
    Invoke-WebRequest -Uri "$RawBase/$Name" -OutFile $dest -UseBasicParsing
    return $dest
}

# 1. Provision or reuse the heartbeat.
$headers = @{ Authorization = "Bearer $BetterStackApiToken" }
$hbName  = "tailnet-$Server"
$list    = Invoke-RestMethod -Uri 'https://uptime.betterstack.com/api/v2/heartbeats' -Headers $headers
$existing = $list.data | Where-Object { $_.attributes.name -eq $hbName } | Select-Object -First 1
if ($existing) {
    $hbUrl = $existing.attributes.url
    # Ensure the reused heartbeat routes through the escalation policy (idempotent).
    # Non-fatal: a policy-patch hiccup must not abort the install.
    try {
        $patch = @{ policy_id = $PolicyId } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://uptime.betterstack.com/api/v2/heartbeats/$($existing.id)" -Headers $headers -Method Patch -Body $patch -ContentType 'application/json' | Out-Null
        Write-Host "Reusing heartbeat '$hbName' (policy $PolicyId ensured)." -ForegroundColor Green
    } catch {
        Write-Warning "Reusing heartbeat '$hbName', but failed to set policy $PolicyId : $($_.Exception.Message)"
    }
} else {
    # Token is team-scoped, so do NOT pass a team id (the API rejects it).
    # policy_id routes the heartbeat through the AmeriGlide escalation policy,
    # matching the zombie detector (AG-25).
    $body = @{ name = $hbName; period = 300; grace = 900; policy_id = $PolicyId } | ConvertTo-Json
    $created = Invoke-RestMethod -Uri 'https://uptime.betterstack.com/api/v2/heartbeats' -Headers $headers -Method Post -Body $body -ContentType 'application/json'
    $hbUrl = $created.data.attributes.url
    Write-Host "Created heartbeat '$hbName' (policy $PolicyId)." -ForegroundColor Green
}

# 2. Write config.
$config = [ordered]@{
    heartbeatUrl                     = $hbUrl
    anchors                          = $Anchors
    intervalMinutes                  = 5
    minRestartGapMinutes             = 10
    maxRestartsPerHour               = 3
    consecutiveFailuresBeforeRestart = 2
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $BaseDir 'tailscale-watchdog.config.json')

# 3. Copy scripts.
Copy-Item -Path (Get-RepoScript 'watchdog-core.ps1')                 -Destination $BaseDir -Force
Copy-Item -Path (Get-RepoScript 'tailscale-watchdog.ps1')            -Destination $BaseDir -Force
Copy-Item -Path (Get-RepoScript 'repair-tailscale-service-deps.ps1') -Destination $BaseDir -Force

# 4. Register the scheduled task.
& (Get-RepoScript 'register-watchdog-task.ps1')

# 5. Disable WPAD proxy auto-detect (AG-48). tailscaled runs as SYSTEM and these
# servers use no proxy; leaving WPAD on lets a brief outbound hiccup wedge
# tailscaled for hours via a hung WinHTTP GetProxyForURL. Idempotent.
& (Get-RepoScript 'disable-wpad-proxy.ps1')

# 6. Sever the spurious WinHttpAutoProxySvc dependency so a reboot -- or a GPO/
# baseline re-push -- can never wedge iphlpsvc + Tailscale (AG-46 follow-up).
# Idempotent; the watchdog also re-applies this before any restart.
& (Get-RepoScript 'repair-tailscale-service-deps.ps1')

# 7. Bundle Vector host_metrics when a source token is supplied (AMG-403).
# install-vector-host-metrics.ps1 is idempotent (skips the binary if already
# present), so passing a token for an already-onboarded box is safe.
if (-not $SkipVector -and $VectorSourceToken) {
    & (Get-RepoScript 'install-vector-host-metrics.ps1') -SourceToken $VectorSourceToken
}

Write-Host "Watchdog installed on $Server." -ForegroundColor Green
