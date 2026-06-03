# register-watchdog-task.ps1
# Registers (idempotently) the AG Tailscale Watchdog scheduled task: SYSTEM,
# every 5 minutes, plus at startup. ASCII only.
$ErrorActionPreference = 'Stop'
$Script:Revision = ""

$taskName   = 'AG Tailscale Watchdog'
$scriptPath = Join-Path $env:ProgramData 'ag-admin\tailscale-watchdog.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$triggerInterval = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$triggerStartup  = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($triggerInterval, $triggerStartup) -Principal $principal -Settings $settings | Out-Null
Write-Host "  Registered scheduled task '$taskName'." -ForegroundColor Green
