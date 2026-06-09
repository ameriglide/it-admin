# register-watchdog-task.ps1
# Registers (idempotently) the AG Tailscale Watchdog scheduled task: SYSTEM,
# every 5 minutes, plus at startup. ASCII only.
$ErrorActionPreference = 'Stop'
$Script:Revision = "ebab6f6"

$taskName   = 'AG Tailscale Watchdog'
$scriptPath = Join-Path $env:ProgramData 'ag-admin\tailscale-watchdog.ps1'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$triggerInterval = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$triggerStartup  = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# ExecutionTimeLimit must be SHORTER than the 5-minute repetition interval: if a
# cycle hangs (e.g. on a wedged network call) Task Scheduler force-kills it
# before the next trigger fires, so MultipleInstances=IgnoreNew can no longer
# let one stuck instance silence the watchdog for the 72h default. (AG-47)
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action `
    -Trigger @($triggerInterval, $triggerStartup) -Principal $principal -Settings $settings | Out-Null
Write-Host "  Registered scheduled task '$taskName'." -ForegroundColor Green
