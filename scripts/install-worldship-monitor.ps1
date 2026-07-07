# install-worldship-monitor.ps1
# Installs the WorldShip update monitor on a shipping station: creates (or
# reuses) the Better Stack heartbeat 'worldship-<station>', writes config,
# downloads worldship-monitor.ps1, registers the daily 'AG WorldShip Monitor'
# scheduled task, and runs one cycle immediately. Run elevated (or as SYSTEM
# via SSM). ASCII only.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Station,
    [Parameter(Mandatory = $true)][string]$BetterStackApiToken,
    [int]$PolicyId = 114897,
    [int]$LookbackDays = 3
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseDir = Join-Path $env:ProgramData 'ag-admin'
New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

# 1. Create or reuse the heartbeat. Token is team-scoped: do NOT pass team_id.
$hbName  = "worldship-$Station"
$headers = @{ Authorization = "Bearer $BetterStackApiToken" }
$hbs = @(); $uri = 'https://uptime.betterstack.com/api/v2/heartbeats'
while ($uri) {
    $page = Invoke-RestMethod -Uri $uri -Headers $headers
    $hbs += $page.data
    $uri  = $page.pagination.next
}
$existing = $hbs | Where-Object { $_.attributes.name -eq $hbName } | Select-Object -First 1
if ($existing) {
    $hbUrl = $existing.attributes.url
    try {
        $patch = @{ policy_id = $PolicyId; paused = $false } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://uptime.betterstack.com/api/v2/heartbeats/$($existing.id)" -Headers $headers -Method Patch -Body $patch -ContentType 'application/json' | Out-Null
        Write-Host "Reusing heartbeat '$hbName' (policy $PolicyId ensured, unpaused)." -ForegroundColor Green
    } catch {
        Write-Warning "Reusing heartbeat '$hbName', but failed to patch policy: $($_.Exception.Message)"
    }
} else {
    $body = @{ name = $hbName; period = 86400; grace = 21600; policy_id = $PolicyId } | ConvertTo-Json
    $created = Invoke-RestMethod -Uri 'https://uptime.betterstack.com/api/v2/heartbeats' -Headers $headers -Method Post -Body $body -ContentType 'application/json'
    $hbUrl = $created.data.attributes.url
    Write-Host "Created heartbeat '$hbName' (policy $PolicyId)." -ForegroundColor Green
}

# 2. Write config.
$config = [ordered]@{
    heartbeatUrl = $hbUrl
    lookbackDays = $LookbackDays
}
$config | ConvertTo-Json | Set-Content -Path (Join-Path $BaseDir 'worldship-monitor.config.json')

# 3. Download the monitor script.
$monitorPath = Join-Path $BaseDir 'worldship-monitor.ps1'
Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/ameriglide/it-admin/main/scripts/worldship-monitor.ps1' -OutFile $monitorPath
Write-Host "Installed $monitorPath" -ForegroundColor Green

# 4. Register the scheduled task (daily 07:00 local, SYSTEM).
$taskName = 'AG WorldShip Monitor'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`""
$trigger   = New-ScheduledTaskTrigger -Daily -At '07:00'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
Write-Host "Registered scheduled task '$taskName'." -ForegroundColor Green

# 5. Run one cycle now so the heartbeat gets its first ping (or /fail).
& $monitorPath
Write-Host 'Initial monitor cycle complete. Check the Better Stack heartbeat.' -ForegroundColor Green
