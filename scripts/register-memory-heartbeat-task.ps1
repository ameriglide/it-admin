# register-memory-heartbeat-task.ps1
# Registers (idempotently) the AG Memory Heartbeat scheduled task: SYSTEM, every
# 5 minutes, plus at startup. Runs memory-watchdog.ps1, which beats a Better
# Stack heartbeat only while commit/memory is healthy. ASCII only.
$ErrorActionPreference = 'Stop'

$taskName   = 'AG Memory Heartbeat'
$scriptPath = Join-Path $env:ProgramData 'ag-admin\memory-watchdog.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$triggerInterval = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$triggerStartup  = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# ExecutionTimeLimit shorter than the 5-minute repetition, matching the Tailscale
# watchdog: a hung cycle (e.g. a wedged heartbeat POST) is force-killed before the
# next trigger so it can never silence the beat for the 72h default.
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($triggerInterval, $triggerStartup) -Principal $principal -Settings $settings | Out-Null
Write-Host "  Registered scheduled task '$taskName'." -ForegroundColor Green
