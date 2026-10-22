# Installs po-flag-watch.ps1 as two scheduled tasks every 5 minutes and runs
# each once: 'AG PO Flag Watch' as sage-sync (Interactive, for ProvideX ODBC)
# and 'AG PO Flag Watch Sessions' as SYSTEM (to see process owners). Run
# elevated on sage-host from a folder that also holds po-flag-watch.ps1. ASCII only.
$ErrorActionPreference = 'Stop'
$dir = 'C:\ProgramData\ag-admin'
$out = "$dir\po-flag-watch"
Copy-Item -Force (Join-Path $PSScriptRoot 'po-flag-watch.ps1') "$dir\po-flag-watch.ps1"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# sage-sync needs to append to files in the output folder.
$acl = Get-Acl $out
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('sage-sync', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $out $acl
# The first install ran the Sage half as SYSTEM and logged only a logon failure.
if (Test-Path "$out\watch.csv") { Rename-Item "$out\watch.csv" "watch-system-logon-failed.csv" -Force }

$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew -StartWhenAvailable
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
function New-WatchAction([string]$mode) {
    New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\po-flag-watch.ps1`" -Mode $mode"
}

$sage = New-ScheduledTaskPrincipal -UserId 'sage-sync' -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'AG PO Flag Watch' -Action (New-WatchAction 'Sage') -Trigger $trigger -Settings $settings -Principal $sage -Force | Out-Null
$system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'AG PO Flag Watch Sessions' -Action (New-WatchAction 'Sessions') -Trigger $trigger -Settings $settings -Principal $system -Force | Out-Null

Start-ScheduledTask -TaskName 'AG PO Flag Watch'
Start-ScheduledTask -TaskName 'AG PO Flag Watch Sessions'
Start-Sleep -Seconds 45
'--- watch.csv'; Get-Content "$out\watch.csv" -EA SilentlyContinue
'--- sessions.csv'; Get-Content "$out\sessions.csv" -EA SilentlyContinue
'--- task results'; Get-ScheduledTask -TaskName 'AG PO Flag Watch*' | ForEach-Object { "{0}: last result {1}" -f $_.TaskName, (Get-ScheduledTaskInfo $_).LastTaskResult }
