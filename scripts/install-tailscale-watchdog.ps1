# install-tailscale-watchdog.ps1
# Server-only installer: provision/reuse a Better Stack heartbeat, write config,
# copy the watchdog, register the task, and (sage-iai/sage-server) install
# Vector host_metrics. Run once per server. ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('sage-amg','sage-iai','sage-server')][string]$Server,
    [string]$BetterStackApiToken = $env:BETTERSTACK_UPTIME_TOKEN,
    [int]$PolicyId = 114897,
    [string]$VectorSourceToken,
    [switch]$SkipVector
)
$ErrorActionPreference = 'Stop'
$Script:Revision = "2ee6465"

if (-not $BetterStackApiToken) { throw "BetterStack API token required (-BetterStackApiToken or BETTERSTACK_API_TOKEN)." }

$BaseDir = Join-Path $env:ProgramData 'ag-admin'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$anchorMap = @{
    'sage-amg'    = @('100.64.0.4','100.64.0.11','100.64.0.10')
    'sage-iai'    = @('100.64.0.4','100.64.0.11','100.64.0.9')
    'sage-server' = @('100.64.0.4','100.64.0.9','100.64.0.10')
}
$anchors = $anchorMap[$Server]

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
    anchors                          = $anchors
    intervalMinutes                  = 5
    minRestartGapMinutes             = 10
    maxRestartsPerHour               = 3
    consecutiveFailuresBeforeRestart = 2
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $BaseDir 'tailscale-watchdog.config.json')

# 3. Copy scripts.
Copy-Item -Path (Join-Path $PSScriptRoot 'watchdog-core.ps1')      -Destination $BaseDir -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'tailscale-watchdog.ps1') -Destination $BaseDir -Force

# 4. Register the scheduled task.
& (Join-Path $PSScriptRoot 'register-watchdog-task.ps1')

# 5. Bundle Vector host_metrics for the two boxes not yet onboarded (AMG-403).
if (-not $SkipVector -and $Server -in @('sage-iai','sage-server')) {
    if (-not $VectorSourceToken) {
        Write-Warning "VectorSourceToken not supplied; skipping Vector host_metrics (AMG-403). Re-run with -VectorSourceToken to onboard metrics."
    } else {
        & (Join-Path $PSScriptRoot 'install-vector-host-metrics.ps1') -SourceToken $VectorSourceToken
    }
}

Write-Host "Watchdog installed on $Server." -ForegroundColor Green
